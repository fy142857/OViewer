import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'upload_asset.dart';
import 'upload_asset_preparer.dart';
import 'upload_file_io.dart';

class ZipImportResult {
  ZipImportResult(
      {required List<PreparedUploadAsset> assets,
      required List<ValidationIssue> excluded})
      : assets = List.unmodifiable(assets),
        excluded = List.unmodifiable(excluded);
  final List<PreparedUploadAsset> assets;
  final List<ValidationIssue> excluded;
}

/// A deliberately limited ZIP reader: regular Store/Deflate files only.
/// Container metadata and names are validated before any output is created.
/// Every extracted file is bounded, CRC verified and inspected independently.
class UploadZipExtractor {
  const UploadZipExtractor();

  Future<ZipImportResult> extract({
    required Directory root,
    required String archiveRelativePath,
    required String destinationId,
    UploadCancellation? isCancelled,
    UploadSpaceProbe? availableBytes,
  }) async {
    _requireId(destinationId);
    checkUploadCancellation(isCancelled);
    final archive = await resolveUploadFile(root, archiveRelativePath);
    final input = await archive.open();
    late final List<_ZipEntry> entries;
    try {
      entries = await _readDirectory(input, await input.length(), isCancelled);
    } finally {
      await input.close();
    }
    final images = <_ZipEntry>[];
    final excluded = <ValidationIssue>[];
    var declaredBytes = 0;
    for (final entry in entries) {
      if (entry.directory) continue;
      declaredBytes += entry.size;
      if (declaredBytes > UploadFileLimits.maxGalleryBytes) {
        throw const UploadFileException('archive_expanded_too_large');
      }
      final lower = entry.name.toLowerCase();
      if (lower.endsWith('.zip')) {
        throw UploadFileException('nested_archive', displayName: entry.name);
      }
      if (!RegExp(r'\.(jpe?g|png|gif|webp)$', caseSensitive: false)
          .hasMatch(entry.name)) {
        excluded.add(ValidationIssue('unsupported_archive_entry',
            severity: UploadIssueSeverity.warning, displayName: entry.name));
        continue;
      }
      if (entry.size > 50000000) {
        throw UploadFileException('image_too_large', displayName: entry.name);
      }
      images.add(entry);
      if (images.length > UploadFileLimits.maxImages) {
        throw const UploadFileException('gallery_too_many_images');
      }
    }
    if (images.isEmpty) {
      excluded.add(const ValidationIssue('archive_has_no_images',
          severity: UploadIssueSeverity.warning));
      return ZipImportResult(assets: const [], excluded: excluded);
    }
    await requireUploadSpace(
        availableBytes, images.fold<int>(0, (n, e) => n + e.size));
    final parent = await createUploadDirectory(root, 'imports');
    final output = Directory('${parent.path}/$destinationId');
    if (await FileSystemEntity.type(output.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const UploadFileException('destination_exists');
    }
    await output.create();
    final assets = <PreparedUploadAsset>[];
    var actualBytes = 0;
    try {
      for (var i = 0; i < images.length; i++) {
        checkUploadCancellation(isCancelled);
        final entry = images[i];
        final fileName = '${i.toString().padLeft(4, '0')}.image';
        final relative = 'imports/$destinationId/$fileName';
        final destination = await resolveUploadFile(root, relative);
        final sink = await destination.open(mode: FileMode.write);
        final crc = UploadCrc32();
        var written = 0;
        try {
          // A deflate bomb can expand one input chunk by roughly three orders
          // of magnitude. Keep compressed chunks small *before* decoding, not
          // merely after an oversized decoded chunk has already been allocated.
          Stream<List<int>> data = _readCompressedChunks(
              archive, entry.dataOffset, entry.compressedSize, isCancelled);
          if (entry.method == 8) {
            data = data.transform(ZLibDecoder(raw: true));
          }
          await for (final chunk in data) {
            checkUploadCancellation(isCancelled);
            written += chunk.length;
            actualBytes += chunk.length;
            if (written > entry.size ||
                written > 50000000 ||
                actualBytes > UploadFileLimits.maxGalleryBytes) {
              throw const UploadFileException('archive_expanded_too_large');
            }
            await requireUploadSpace(availableBytes, chunk.length);
            crc.add(chunk);
            await sink.writeFrom(chunk);
          }
          if (written != entry.size || crc.value != entry.crc) {
            throw UploadFileException('archive_checksum',
                displayName: entry.name);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        assets.add(await const UploadAssetPreparer().inspect(
          root: root,
          relativePath: relative,
          displayName: entry.name,
          isCancelled: isCancelled,
        ));
      }
      checkUploadCancellation(isCancelled);
      return ZipImportResult(assets: assets, excluded: excluded);
    } on FormatException {
      await output.delete(recursive: true);
      throw const UploadFileException('corrupt_archive');
    } catch (_) {
      // This directory was created exclusively by this invocation, beneath a
      // canonical checked root, and contains only generated flat filenames.
      await output.delete(recursive: true);
      rethrow;
    }
  }
}

class UploadBatchWriter {
  const UploadBatchWriter();

  /// Includes ZIP overhead. The source copy, ZIP and eventual multipart body
  /// may coexist; callers add any source ZIP copies not already accounted for.
  int estimatePreparationBytes(List<PreparedUploadAsset> assets) {
    final frozen = const UploadAssetPreparer().freezeNames(assets);
    final images = frozen.fold<int>(0, (n, a) => n + a.size);
    final overhead = frozen.fold<int>(
        22, (n, a) => n + 76 + 2 * ascii.encode(a.uploadName!).length);
    return images + 2 * (images + overhead) + 1048576;
  }

  Future<List<UploadBatch>> prepare({
    required Directory root,
    required List<PreparedUploadAsset> assets,
    required String batchId,
    int maxBatchBytes = UploadFileLimits.maxBatchBytes,
    UploadCancellation? isCancelled,
    UploadSpaceProbe? availableBytes,
  }) async {
    _requireId(batchId);
    if (maxBatchBytes < 22 || maxBatchBytes > UploadFileLimits.maxBatchBytes) {
      throw ArgumentError('Invalid batch byte limit');
    }
    const preparer = UploadAssetPreparer();
    if (preparer
        .validateGallery(assets)
        .any((i) => i.severity == UploadIssueSeverity.error)) {
      throw const UploadFileException('invalid_gallery');
    }
    final frozen = preparer.freezeNames(assets);
    final groups = <List<PreparedUploadAsset>>[];
    var group = <PreparedUploadAsset>[];
    var groupBytes = 22;
    for (final asset in frozen) {
      final needed =
          asset.size + 76 + 2 * ascii.encode(asset.uploadName!).length;
      if (needed + 22 > maxBatchBytes) {
        throw UploadFileException('asset_exceeds_batch',
            displayName: asset.displayName);
      }
      if (groupBytes + needed > maxBatchBytes) {
        groups.add(group);
        group = [];
        groupBytes = 22;
      }
      group.add(asset);
      groupBytes += needed;
    }
    if (group.isNotEmpty) groups.add(group);
    if (groups.isEmpty) return const [];
    checkUploadCancellation(isCancelled);
    await requireUploadSpace(
        availableBytes,
        frozen.fold<int>(
                0, (n, a) => n + a.size + 76 + 2 * a.uploadName!.length) +
            groups.length * 22);
    final parent = await createUploadDirectory(root, 'batches');
    final directory = Directory('${parent.path}/$batchId');
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const UploadFileException('destination_exists');
    }
    await directory.create();
    final batches = <UploadBatch>[];
    try {
      for (var i = 0; i < groups.length; i++) {
        checkUploadCancellation(isCancelled);
        final relative = 'batches/$batchId/${i.toString().padLeft(4, '0')}.zip';
        final file = await resolveUploadFile(root, relative);
        await _writeBatch(root, file, groups[i], isCancelled, availableBytes);
        final digest = await digestUploadFile(file, isCancelled: isCancelled);
        if (digest.bytes > maxBatchBytes) {
          throw const UploadFileException('batch_too_large');
        }
        batches.add(UploadBatch(
            relativePath: relative,
            size: digest.bytes,
            sha256: digest.sha256,
            assets: groups[i]));
      }
      return List.unmodifiable(batches);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}

void _requireId(String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
    throw const UploadFileException('unsafe_path');
  }
}

int _u16(Uint8List b, int i) =>
    ByteData.sublistView(b).getUint16(i, Endian.little);
int _u32(Uint8List b, int i) =>
    ByteData.sublistView(b).getUint32(i, Endian.little);
int _u64(Uint8List b, int i) =>
    ByteData.sublistView(b).getUint64(i, Endian.little);

class _ZipEntry {
  _ZipEntry(
      {required this.name,
      required this.nameBytes,
      required this.flags,
      required this.method,
      required this.crc,
      required this.size,
      required this.compressedSize,
      required this.localOffset,
      required this.directory});
  final String name;
  final Uint8List nameBytes;
  final int flags, method, crc, size, compressedSize, localOffset;
  final bool directory;
  int dataOffset = 0;
}

Future<List<_ZipEntry>> _readDirectory(
    RandomAccessFile input, int length, UploadCancellation? cancelled) async {
  if (length < 22) throw const UploadFileException('corrupt_archive');
  final tailSize = length < 65557 ? length : 65557;
  final tail = await readUploadBytes(input, length - tailSize, tailSize);
  var eocd = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (_u32(tail, i) == 0x06054b50 &&
        i + 22 + _u16(tail, i + 20) == tail.length) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const UploadFileException('corrupt_archive');
  if (_u16(tail, eocd + 4) != 0 ||
      _u16(tail, eocd + 6) != 0 ||
      _u16(tail, eocd + 8) != _u16(tail, eocd + 10)) {
    throw const UploadFileException('split_archive');
  }
  var count = _u16(tail, eocd + 10);
  var directorySize = _u32(tail, eocd + 12);
  var directoryOffset = _u32(tail, eocd + 16);
  var directoryEndLimit = length - tailSize + eocd;
  if (count == 0xffff ||
      directorySize == 0xffffffff ||
      directoryOffset == 0xffffffff) {
    final locator = await readUploadBytes(input, directoryEndLimit - 20, 20);
    if (_u32(locator, 0) != 0x07064b50 ||
        _u32(locator, 4) != 0 ||
        _u32(locator, 16) != 1) {
      throw const UploadFileException('split_archive');
    }
    final zip64Offset = _u64(locator, 8);
    final zip64 = await readUploadBytes(input, zip64Offset, 56);
    if (_u32(zip64, 0) != 0x06064b50 ||
        _u64(zip64, 4) < 44 ||
        _u32(zip64, 16) != 0 ||
        _u32(zip64, 20) != 0 ||
        _u64(zip64, 24) != _u64(zip64, 32)) {
      throw const UploadFileException('corrupt_archive');
    }
    count = _u64(zip64, 32);
    directorySize = _u64(zip64, 40);
    directoryOffset = _u64(zip64, 48);
    directoryEndLimit = zip64Offset;
  }
  if (count > 10000) {
    throw const UploadFileException('archive_too_many_entries');
  }
  if (directorySize > 8 * 1024 * 1024) {
    throw const UploadFileException('archive_metadata_too_large');
  }
  if (directoryOffset < 0 ||
      directorySize < 0 ||
      directoryOffset + directorySize > directoryEndLimit) {
    throw const UploadFileException('corrupt_archive');
  }
  var position = directoryOffset;
  final entries = <_ZipEntry>[];
  for (var i = 0; i < count; i++) {
    checkUploadCancellation(cancelled);
    final header = await readUploadBytes(input, position, 46);
    if (_u32(header, 0) != 0x02014b50) {
      throw const UploadFileException('corrupt_archive');
    }
    final flags = _u16(header, 8);
    final method = _u16(header, 10);
    if ((flags & 0x41) != 0) {
      throw const UploadFileException('encrypted_archive');
    }
    if ((flags & ~0x080e) != 0) {
      throw const UploadFileException('unsupported_zip_flags');
    }
    if (method != 0 && method != 8) {
      throw const UploadFileException('unsupported_zip_method');
    }
    final nameLength = _u16(header, 28);
    final extraLength = _u16(header, 30);
    final commentLength = _u16(header, 32);
    if (position + 46 + nameLength + extraLength + commentLength >
            directoryOffset + directorySize ||
        nameLength == 0) {
      throw const UploadFileException('corrupt_archive');
    }
    final nameBytes = await readUploadBytes(input, position + 46, nameLength);
    final extra =
        await readUploadBytes(input, position + 46 + nameLength, extraLength);
    String name;
    try {
      name = (flags & 0x800) != 0
          ? utf8.decode(nameBytes)
          : latin1.decode(nameBytes);
    } on FormatException {
      throw const UploadFileException('archive_filename_encoding');
    }
    var size = _u32(header, 24);
    var compressed = _u32(header, 20);
    var local = _u32(header, 42);
    var disk = _u16(header, 34);
    var sawZip64 = false;
    for (var extraPos = 0; extraPos < extra.length;) {
      if (extraPos + 4 > extra.length) {
        throw const UploadFileException('corrupt_archive');
      }
      final type = _u16(extra, extraPos);
      final bytes = _u16(extra, extraPos + 2);
      if (extraPos + 4 + bytes > extra.length) {
        throw const UploadFileException('corrupt_archive');
      }
      if (type == 1) {
        sawZip64 = true;
        var cursor = extraPos + 4;
        int next64() {
          if (cursor + 8 > extraPos + 4 + bytes) {
            throw const UploadFileException('corrupt_archive');
          }
          final value = _u64(extra, cursor);
          cursor += 8;
          return value;
        }

        if (size == 0xffffffff) size = next64();
        if (compressed == 0xffffffff) compressed = next64();
        if (local == 0xffffffff) local = next64();
        if (disk == 0xffff) {
          if (cursor + 4 > extraPos + 4 + bytes) {
            throw const UploadFileException('corrupt_archive');
          }
          disk = _u32(extra, cursor);
        }
      }
      // Info-ZIP Unicode Path is honored only if bound to this raw name by CRC.
      if (type == 0x7075 && bytes >= 5 && extra[extraPos + 4] == 1) {
        final crc = UploadCrc32()..add(nameBytes);
        if (crc.value == _u32(extra, extraPos + 5)) {
          try {
            name =
                utf8.decode(extra.sublist(extraPos + 9, extraPos + 4 + bytes));
          } on FormatException {
            throw const UploadFileException('archive_filename_encoding');
          }
        }
      }
      extraPos += 4 + bytes;
    }
    if (!sawZip64 &&
        (size == 0xffffffff ||
            compressed == 0xffffffff ||
            local == 0xffffffff)) {
      throw const UploadFileException('corrupt_archive');
    }
    if (disk != 0) throw const UploadFileException('split_archive');
    final unixType = (_u32(header, 38) >>> 16) & 0xf000;
    if (unixType != 0 && unixType != 0x8000 && unixType != 0x4000) {
      throw const UploadFileException('archive_special_file');
    }
    final normalized = name.replaceAll('\\', '/');
    final directory = normalized.endsWith('/');
    uploadPathParts(directory
        ? normalized.substring(0, normalized.length - 1)
        : normalized);
    if (normalized.split('/').length > 32) {
      throw const UploadFileException('archive_path_depth');
    }
    if (directory && size != 0) {
      throw const UploadFileException('corrupt_archive');
    }
    if (size < 0 ||
        compressed < 0 ||
        local < 0 ||
        (method == 0 && size != compressed) ||
        local + 30 > directoryOffset) {
      throw const UploadFileException('corrupt_archive');
    }
    entries.add(_ZipEntry(
        name: name,
        nameBytes: nameBytes,
        flags: flags,
        method: method,
        crc: _u32(header, 16),
        size: size,
        compressedSize: compressed,
        localOffset: local,
        directory: directory));
    position += 46 + nameLength + extraLength + commentLength;
  }
  if (position != directoryOffset + directorySize) {
    throw const UploadFileException('corrupt_archive');
  }
  final spans = <List<int>>[];
  for (final entry in entries) {
    checkUploadCancellation(cancelled);
    final local = await readUploadBytes(input, entry.localOffset, 30);
    if (_u32(local, 0) != 0x04034b50 ||
        _u16(local, 6) != entry.flags ||
        _u16(local, 8) != entry.method) {
      throw const UploadFileException('archive_header_mismatch');
    }
    final nameLength = _u16(local, 26);
    final localName =
        await readUploadBytes(input, entry.localOffset + 30, nameLength);
    if (base64.encode(localName) != base64.encode(entry.nameBytes)) {
      throw const UploadFileException('archive_header_mismatch');
    }
    entry.dataOffset = entry.localOffset + 30 + nameLength + _u16(local, 28);
    final end = entry.dataOffset + entry.compressedSize;
    if (end > directoryOffset) {
      throw const UploadFileException('corrupt_archive');
    }
    spans.add([entry.localOffset, end]);
  }
  spans.sort((a, b) => a[0].compareTo(b[0]));
  for (var i = 1; i < spans.length; i++) {
    if (spans[i][0] < spans[i - 1][1]) {
      throw const UploadFileException('archive_overlapping_entries');
    }
  }
  return entries;
}

Stream<List<int>> _readCompressedChunks(
    File file, int offset, int length, UploadCancellation? cancelled) async* {
  final input = await file.open();
  try {
    await input.setPosition(offset);
    var remaining = length;
    while (remaining > 0) {
      checkUploadCancellation(cancelled);
      final bytes = await input.read(remaining < 4096 ? remaining : 4096);
      if (bytes.isEmpty) throw const UploadFileException('corrupt_archive');
      remaining -= bytes.length;
      yield bytes;
    }
  } finally {
    await input.close();
  }
}

Uint8List _record(int size, Map<int, int> shorts, Map<int, int> longs) {
  final data = ByteData(size);
  shorts
      .forEach((offset, value) => data.setUint16(offset, value, Endian.little));
  longs
      .forEach((offset, value) => data.setUint32(offset, value, Endian.little));
  return data.buffer.asUint8List();
}

Future<void> _writeBatch(
    Directory root,
    File destination,
    List<PreparedUploadAsset> assets,
    UploadCancellation? cancelled,
    UploadSpaceProbe? availableBytes) async {
  final output = await destination.open(mode: FileMode.write);
  final central = <Uint8List>[];
  var offset = 0;
  try {
    for (final asset in assets) {
      checkUploadCancellation(cancelled);
      final name = ascii.encode(asset.uploadName!);
      final header = _record(
          30,
          {4: 20, 6: 0x800, 8: 0, 12: 33, 26: name.length},
          {0: 0x04034b50, 14: asset.crc32, 18: asset.size, 22: asset.size});
      await output.writeFrom(header);
      await output.writeFrom(name);
      final source = await resolveUploadFile(root, asset.relativePath);
      final shaResult = UploadDigestSink();
      final sha = crypto.sha256.startChunkedConversion(shaResult);
      final crc = UploadCrc32();
      var written = 0;
      try {
        await for (final chunk in source.openRead()) {
          checkUploadCancellation(cancelled);
          written += chunk.length;
          if (written > asset.size) {
            throw const UploadFileException('file_changed');
          }
          await requireUploadSpace(availableBytes, chunk.length);
          sha.add(chunk);
          crc.add(chunk);
          await output.writeFrom(chunk);
        }
      } finally {
        sha.close();
      }
      if (written != asset.size ||
          shaResult.digest.toString() != asset.sha256 ||
          crc.value != asset.crc32) {
        throw const UploadFileException('file_changed');
      }
      central.add(_record(46, {
        4: 20,
        6: 20,
        8: 0x800,
        10: 0,
        14: 33,
        28: name.length
      }, {
        0: 0x02014b50,
        16: asset.crc32,
        20: asset.size,
        24: asset.size,
        42: offset
      }));
      central.add(Uint8List.fromList(name));
      offset += header.length + name.length + written;
    }
    final centralOffset = offset;
    for (final bytes in central) {
      await output.writeFrom(bytes);
      offset += bytes.length;
    }
    await output.writeFrom(_record(22, {8: assets.length, 10: assets.length},
        {0: 0x06054b50, 12: offset - centralOffset, 16: centralOffset}));
    await output.flush();
  } finally {
    await output.close();
  }
}
