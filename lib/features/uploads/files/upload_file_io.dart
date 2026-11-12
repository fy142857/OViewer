import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'upload_asset.dart';

List<String> uploadPathParts(String relativePath) {
  final normalized = relativePath.replaceAll('\\', '/');
  final parts = normalized.split('/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.contains(':') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized) ||
      parts.any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw const UploadFileException('unsafe_path');
  }
  return parts;
}

/// Local records never authorize reads/writes outside the dedicated upload root.
Future<File> resolveUploadFile(Directory root, String relativePath) async {
  final parts = uploadPathParts(relativePath);
  final canonicalRoot = await root.resolveSymbolicLinks();
  var current = canonicalRoot;
  for (var i = 0; i < parts.length; i++) {
    current = p.join(current, parts[i]);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (i < parts.length - 1 &&
            type != FileSystemEntityType.directory &&
            type != FileSystemEntityType.notFound)) {
      throw const UploadFileException('unsafe_path');
    }
  }
  if (!p.isWithin(canonicalRoot, current)) {
    throw const UploadFileException('unsafe_path');
  }
  return File(current);
}

Future<Directory> createUploadDirectory(
    Directory root, String relativePath) async {
  final parts = uploadPathParts(relativePath);
  var current = await root.resolveSymbolicLinks();
  for (final part in parts) {
    current = p.join(current, part);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(current).create();
    } else if (type != FileSystemEntityType.directory) {
      throw const UploadFileException('unsafe_path');
    }
  }
  return Directory(current);
}

Future<Uint8List> readUploadBytes(
    RandomAccessFile input, int position, int count) async {
  if (position < 0 || count < 0) {
    throw const UploadFileException('corrupt_file');
  }
  await input.setPosition(position);
  final data = await input.read(count);
  if (data.length != count) throw const UploadFileException('corrupt_file');
  return data;
}

class UploadCrc32 {
  static final _table = List<int>.generate(256, (value) {
    for (var i = 0; i < 8; i++) {
      value = (value & 1) != 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    return value;
  }, growable: false);
  int _value = 0xffffffff;
  void add(List<int> bytes) {
    for (final byte in bytes) {
      _value = _table[(_value ^ byte) & 255] ^ (_value >>> 8);
    }
  }

  int get value => (_value ^ 0xffffffff) & 0xffffffff;
}

class UploadDigestSink implements Sink<crypto.Digest> {
  crypto.Digest? digest;
  @override
  void add(crypto.Digest value) => digest = value;
  @override
  void close() {}
}

class UploadFileDigest {
  const UploadFileDigest(this.bytes, this.sha256, this.crc32);
  final int bytes;
  final String sha256;
  final int crc32;
}

Future<UploadFileDigest> digestUploadFile(File file,
    {UploadCancellation? isCancelled}) async {
  final result = UploadDigestSink();
  final sha = crypto.sha256.startChunkedConversion(result);
  final crc = UploadCrc32();
  var size = 0;
  try {
    await for (final bytes in file.openRead()) {
      checkUploadCancellation(isCancelled);
      size += bytes.length;
      sha.add(bytes);
      crc.add(bytes);
    }
  } finally {
    sha.close();
  }
  checkUploadCancellation(isCancelled);
  return UploadFileDigest(size, result.digest.toString(), crc.value);
}

/// Space is checked repeatedly because a cloud provider or ZIP header may lie
/// about its eventual size, and other applications can fill the disk meanwhile.
Future<void> requireUploadSpace(UploadSpaceProbe? probe, int remaining) async {
  if (probe != null && await probe() < remaining) {
    throw const UploadFileException('insufficient_space');
  }
}
