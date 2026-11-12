import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'upload_asset.dart';
import 'upload_file_io.dart';

class PreparedUploadBody {
  final String path;
  final String contentType;
  final int length;
  final String sha256;
  const PreparedUploadBody(
      this.path, this.contentType, this.length, this.sha256);
}

const maxPreparedUploadBodyBytes = 128 * 1024 * 1024;

/// Background URLSession requires a complete file, not a Dart stream.
Future<PreparedUploadBody> prepareUploadBody({
  required Directory root,
  required UploadBatch batch,
  required Map<String, List<String>> fields,
  required String id,
  String? groupId,
  UploadCancellation? isCancelled,
  UploadSpaceProbe? availableBytes,
}) async {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
    throw ArgumentError('Invalid body id');
  }
  if (groupId != null && !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(groupId)) {
    throw ArgumentError('Invalid body group id');
  }
  checkUploadCancellation(isCancelled);
  // RFC 2046 limits boundaries to 70 characters; IDs can be up to 100.
  final boundary =
      'oviewer_${crypto.sha256.convert(utf8.encode(id)).toString().substring(0, 40)}';
  final directory = groupId == null ? 'prepared' : 'prepared/$groupId';
  await createUploadDirectory(root, directory);
  final relativePath = '$directory/$id.multipart';
  final output = await resolveUploadFile(root, '$relativePath.part');
  final completed = await resolveUploadFile(root, relativePath);
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound ||
      await FileSystemEntity.type(completed.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw const UploadFileException('duplicate_body');
  }
  final parts = <List<int>>[];
  var fieldBytes = 0;
  for (final entry in fields.entries) {
    if (!RegExp(r'^[A-Za-z0-9_\[\]-]+$').hasMatch(entry.key)) {
      throw const UploadFileException('invalid_form');
    }
    for (final value in entry.value) {
      if (value.length > 2 * 1024 * 1024 || value.contains(boundary)) {
        throw const UploadFileException('invalid_form');
      }
      final part = utf8.encode('--$boundary\r\nContent-Disposition: form-data; '
          'name="${entry.key}"\r\n\r\n$value\r\n');
      fieldBytes += part.length;
      if (fieldBytes > 2 * 1024 * 1024) {
        throw const UploadFileException('invalid_form');
      }
      parts.add(part);
    }
  }
  final fileHeader = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; '
      'name="files[]"; filename="$id.zip"\r\nContent-Type: application/zip\r\n\r\n');
  final ending = utf8.encode('\r\n--$boundary--\r\n');
  final total = parts.fold<int>(0, (a, b) => a + b.length) +
      fileHeader.length +
      batch.size +
      ending.length;
  if (total > maxPreparedUploadBodyBytes || batch.size <= 0) {
    throw const UploadFileException('body_too_large');
  }
  final source = await resolveUploadFile(root, batch.relativePath);
  await requireUploadSpace(availableBytes, total);
  final out = await output.open(mode: FileMode.writeOnly);
  var success = false;
  final sourceDigest = UploadDigestSink();
  final sourceSha = crypto.sha256.startChunkedConversion(sourceDigest);
  var shaClosed = false;
  var copied = 0;
  try {
    for (final part in parts) {
      checkUploadCancellation(isCancelled);
      await out.writeFrom(part);
    }
    await out.writeFrom(fileHeader);
    await for (final data in source.openRead()) {
      checkUploadCancellation(isCancelled);
      copied += data.length;
      if (copied > batch.size) throw const UploadFileException('file_changed');
      await requireUploadSpace(availableBytes, data.length);
      sourceSha.add(data);
      await out.writeFrom(data);
    }
    sourceSha.close();
    shaClosed = true;
    // Hash exactly the bytes that were copied, not a later reread of a source
    // which could change during the copy and be restored before inspection.
    if (copied != batch.size ||
        sourceDigest.digest.toString() != batch.sha256) {
      throw const UploadFileException('file_changed');
    }
    await out.writeFrom(ending);
    await out.flush();
    await out.close();
    final digest = await digestUploadFile(output, isCancelled: isCancelled);
    if (digest.bytes != total) throw const UploadFileException('file_changed');
    checkUploadCancellation(isCancelled);
    await resolveUploadFile(root, relativePath);
    if (await FileSystemEntity.type(completed.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const UploadFileException('duplicate_body');
    }
    await output.rename(completed.path);
    success = true;
    return PreparedUploadBody(relativePath,
        'multipart/form-data; boundary=$boundary', digest.bytes, digest.sha256);
  } finally {
    if (!shaClosed) sourceSha.close();
    try {
      await out.close();
    } catch (_) {}
    if (!success && await output.exists()) await output.delete();
  }
}
