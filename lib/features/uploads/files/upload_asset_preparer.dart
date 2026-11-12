import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'upload_asset.dart';
import 'upload_file_io.dart';

class UploadAssetPreparer {
  const UploadAssetPreparer();

  Future<PreparedUploadAsset> inspect({
    required Directory root,
    required String relativePath,
    required String displayName,
    UploadCancellation? isCancelled,
  }) async {
    checkUploadCancellation(isCancelled);
    final file = await resolveUploadFile(root, relativePath);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw UploadFileException('file_missing', displayName: displayName);
    }
    final before = await file.stat();
    final issues = <ValidationIssue>[];
    _ImageHeader? header;
    final input = await file.open();
    try {
      header = await _readHeader(input, before.size, isCancelled);
      if (header == null) {
        issues.add(
            ValidationIssue('unsupported_image', displayName: displayName));
      }
    } on UploadFileException {
      issues.add(ValidationIssue('corrupt_image', displayName: displayName));
    } finally {
      await input.close();
    }
    if (header != null) {
      final limit = UploadFileLimits.imageBytes[header.format]!;
      if (before.size > limit) {
        issues.add(ValidationIssue('image_too_large',
            displayName: displayName, actual: before.size, limit: limit));
      }
      if (header.width < UploadFileLimits.minDimension ||
          header.height < UploadFileLimits.minDimension ||
          header.width > UploadFileLimits.maxDimension ||
          header.height > UploadFileLimits.maxDimension) {
        issues
            .add(ValidationIssue('image_dimensions', displayName: displayName));
      }
      if (header.width + header.height < 251) {
        // The official wording of this additional minimum is ambiguous. It is
        // deliberately informational until the live endpoint is verified.
        issues.add(ValidationIssue('minimum_dimensions_server_check',
            severity: UploadIssueSeverity.warning, displayName: displayName));
      }
      if (header.animated && header.format == UploadImageFormat.png) {
        issues.add(ValidationIssue('apng_display_support',
            severity: UploadIssueSeverity.warning, displayName: displayName));
      }
    }
    final digest = await digestUploadFile(file, isCancelled: isCancelled);
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified != after.modified ||
        digest.bytes != before.size) {
      throw UploadFileException('file_changed', displayName: displayName);
    }
    return PreparedUploadAsset(
      relativePath: relativePath.replaceAll('\\', '/'),
      displayName: displayName,
      size: digest.bytes,
      sha256: digest.sha256,
      crc32: digest.crc32,
      format: header?.format,
      width: header?.width,
      height: header?.height,
      animated: header?.animated ?? false,
      issues: List.unmodifiable(issues),
    );
  }

  List<ValidationIssue> validateGallery(List<PreparedUploadAsset> assets,
      {int existingImages = 0, int existingBytes = 0}) {
    if (existingImages < 0 || existingBytes < 0) {
      throw ArgumentError('Existing gallery counts must be nonnegative');
    }
    final issues = assets.expand((a) => a.issues).toList();
    for (final asset in assets) {
      final limit = UploadFileLimits.imageBytes[asset.format];
      if (limit == null ||
          asset.width == null ||
          asset.height == null ||
          asset.size <= 0 ||
          asset.width! < UploadFileLimits.minDimension ||
          asset.height! < UploadFileLimits.minDimension ||
          asset.width! > UploadFileLimits.maxDimension ||
          asset.height! > UploadFileLimits.maxDimension) {
        issues.add(ValidationIssue('invalid_image_metadata',
            displayName: asset.displayName));
      } else if (asset.size > limit &&
          !asset.issues.any((i) => i.code == 'image_too_large')) {
        issues.add(ValidationIssue('image_too_large',
            displayName: asset.displayName, actual: asset.size, limit: limit));
      }
    }
    final count = assets.length + existingImages;
    final bytes = assets.fold<int>(existingBytes, (sum, a) => sum + a.size);
    if (count > UploadFileLimits.maxImages) {
      issues.add(ValidationIssue('gallery_too_many_images',
          actual: count, limit: UploadFileLimits.maxImages));
    }
    if (bytes > UploadFileLimits.maxGalleryBytes) {
      issues.add(ValidationIssue('gallery_too_large',
          actual: bytes, limit: UploadFileLimits.maxGalleryBytes));
    }
    final hashes = <String>{};
    for (final asset in assets) {
      if (!hashes.add(asset.sha256)) {
        issues.add(ValidationIssue('duplicate_image',
            severity: UploadIssueSeverity.warning,
            displayName: asset.displayName));
      }
    }
    return List.unmodifiable(issues);
  }

  /// Original source names remain untouched. The mapping is shown before
  /// upload and is then stored with the immutable transmission manifest.
  List<PreparedUploadAsset> freezeNames(List<PreparedUploadAsset> assets,
      {int firstSequence = 1}) {
    if (firstSequence < 1 || firstSequence + assets.length - 1 > 9999) {
      throw ArgumentError('Upload sequence must fit four digits');
    }
    final used = <String>{};
    return List.unmodifiable([
      for (var i = 0; i < assets.length; i++)
        _freezeName(assets[i], i + firstSequence, used),
    ]);
  }

  PreparedUploadAsset _freezeName(
      PreparedUploadAsset asset, int sequence, Set<String> used) {
    final existing = asset.uploadName;
    if (existing != null) {
      if (!RegExp(r'^[A-Za-z0-9_-]+\.(jpg|png|gif|webp)$').hasMatch(existing) ||
          existing.length > 255 ||
          asset.format == null ||
          !existing.endsWith('.${asset.format!.extension}') ||
          !used.add(existing.toLowerCase())) {
        throw const UploadFileException('invalid_frozen_name');
      }
      return asset;
    }
    final format = asset.format;
    if (!asset.isValid || format == null) {
      throw UploadFileException('invalid_image',
          displayName: asset.displayName);
    }
    var stem =
        p.basenameWithoutExtension(asset.displayName.replaceAll('\\', '/'));
    stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    stem = stem.replaceAll(RegExp(r'^_+|_+$'), '');
    if (stem.length > 80) stem = stem.substring(0, 80);
    final prefix = sequence.toString().padLeft(4, '0');
    final name = '$prefix${stem.isEmpty ? '' : '_$stem'}.${format.extension}';
    if (!used.add(name.toLowerCase())) {
      throw const UploadFileException('duplicate_frozen_name');
    }
    return asset.withUploadName(name);
  }

  List<PreparedUploadAsset> sorted(List<PreparedUploadAsset> assets,
      {bool natural = true}) {
    // Tie-breaking by original index makes equal names retain user order.
    final entries = assets.asMap().entries.toList();
    entries.sort((a, b) {
      final order = natural
          ? compareNaturalUploadNames(a.value.displayName, b.value.displayName)
          : a.value.displayName.compareTo(b.value.displayName);
      return order != 0 ? order : a.key.compareTo(b.key);
    });
    return List.unmodifiable(entries.map((e) => e.value));
  }
}

int compareNaturalUploadNames(String a, String b) {
  final left = RegExp(r'\d+|\D+').allMatches(a).map((m) => m[0]!).toList();
  final right = RegExp(r'\d+|\D+').allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    var x = left[i];
    var y = right[i];
    int order;
    if (RegExp(r'^\d').hasMatch(x) && RegExp(r'^\d').hasMatch(y)) {
      x = x.replaceFirst(RegExp(r'^0+'), '');
      y = y.replaceFirst(RegExp(r'^0+'), '');
      order = x.length.compareTo(y.length);
      if (order == 0) order = x.compareTo(y);
    } else {
      order = x.toLowerCase().compareTo(y.toLowerCase());
    }
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}

class _ImageHeader {
  const _ImageHeader(this.format, this.width, this.height,
      {this.animated = false});
  final UploadImageFormat format;
  final int width;
  final int height;
  final bool animated;
}

int _be16(List<int> b, int i) => (b[i] << 8) | b[i + 1];
int _le16(List<int> b, int i) => b[i] | (b[i + 1] << 8);
int _le24(List<int> b, int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
int _le32(Uint8List b, int i) =>
    ByteData.sublistView(b).getUint32(i, Endian.little);
int _be32(Uint8List b, int i) =>
    ByteData.sublistView(b).getUint32(i, Endian.big);
bool _matches(List<int> bytes, int offset, List<int> expected) {
  if (offset + expected.length > bytes.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (bytes[offset + i] != expected[i]) return false;
  }
  return true;
}

Future<_ImageHeader?> _readHeader(
    RandomAccessFile input, int size, UploadCancellation? cancelled) async {
  if (size < 10) return null;
  final bytes = await readUploadBytes(input, 0, size < 32 ? size : 32);
  if (_matches(bytes, 0, [137, 80, 78, 71, 13, 10, 26, 10])) {
    if (size < 45 ||
        _be32(bytes, 8) != 13 ||
        !_matches(bytes, 12, [73, 72, 68, 82])) {
      throw const UploadFileException('corrupt_image');
    }
    final ihdr = await readUploadBytes(input, 12, 21);
    final headerCrc = UploadCrc32()..add(ihdr.sublist(0, 17));
    if (headerCrc.value != _be32(ihdr, 17)) {
      throw const UploadFileException('corrupt_image');
    }
    final width = _be32(bytes, 16);
    final height = _be32(bytes, 20);
    var offset = 33;
    var animated = false;
    // APNG's animation control must precede the first IDAT. No pixels decoded.
    while (offset + 12 <= size) {
      checkUploadCancellation(cancelled);
      final chunk = await readUploadBytes(input, offset, 8);
      final length = _be32(chunk, 0);
      if (offset + length + 12 > size) {
        throw const UploadFileException('corrupt_image');
      }
      if (_matches(chunk, 4, [97, 99, 84, 76])) animated = true;
      if (_matches(chunk, 4, [73, 68, 65, 84])) break;
      if (_matches(chunk, 4, [73, 69, 78, 68])) {
        throw const UploadFileException('corrupt_image');
      }
      offset += length + 12;
    }
    final tail = await readUploadBytes(input, size - 12, 12);
    if (_be32(tail, 0) != 0 ||
        !_matches(tail, 4, [73, 69, 78, 68]) ||
        _be32(tail, 8) != 0xae426082) {
      throw const UploadFileException('corrupt_image');
    }
    return _ImageHeader(UploadImageFormat.png, width, height,
        animated: animated);
  }
  if (_matches(bytes, 0, [71, 73, 70, 56, 55, 97]) ||
      _matches(bytes, 0, [71, 73, 70, 56, 57, 97])) {
    if (size < 14 || (await readUploadBytes(input, size - 1, 1))[0] != 0x3b) {
      throw const UploadFileException('corrupt_image');
    }
    return _ImageHeader(
        UploadImageFormat.gif, _le16(bytes, 6), _le16(bytes, 8));
  }
  if (_matches(bytes, 0, [0xff, 0xd8])) {
    var offset = 2;
    while (offset + 4 <= size) {
      checkUploadCancellation(cancelled);
      final marker = await readUploadBytes(input, offset, 2);
      if (marker[0] != 0xff) throw const UploadFileException('corrupt_image');
      if (marker[1] == 0xff) {
        offset++;
        continue;
      }
      if (marker[1] == 0xd9 || marker[1] == 0xda) break;
      if (marker[1] == 0x01 || (marker[1] >= 0xd0 && marker[1] <= 0xd7)) {
        offset += 2;
        continue;
      }
      final lengthBytes = await readUploadBytes(input, offset + 2, 2);
      final length = _be16(lengthBytes, 0);
      if (length < 2 || offset + length + 2 > size) {
        throw const UploadFileException('corrupt_image');
      }
      if ([
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf
      ].contains(marker[1])) {
        if (length < 8) throw const UploadFileException('corrupt_image');
        final frame = await readUploadBytes(input, offset + 4, 5);
        final tail = await readUploadBytes(input, size - 2, 2);
        if (!_matches(tail, 0, [0xff, 0xd9])) {
          throw const UploadFileException('corrupt_image');
        }
        return _ImageHeader(
            UploadImageFormat.jpeg, _be16(frame, 3), _be16(frame, 1));
      }
      offset += length + 2;
    }
    throw const UploadFileException('corrupt_image');
  }
  if (_matches(bytes, 0, [82, 73, 70, 70]) &&
      _matches(bytes, 8, [87, 69, 66, 80])) {
    if (size < 30 || _le32(bytes, 4) + 8 != size) {
      throw const UploadFileException('corrupt_image');
    }
    if (_matches(bytes, 12, [86, 80, 56, 88]) && _le32(bytes, 16) == 10) {
      return _ImageHeader(
          UploadImageFormat.webp, _le24(bytes, 24) + 1, _le24(bytes, 27) + 1,
          animated: (bytes[20] & 2) != 0);
    }
    if (_matches(bytes, 12, [86, 80, 56, 32]) &&
        _matches(bytes, 23, [0x9d, 1, 0x2a])) {
      return _ImageHeader(UploadImageFormat.webp, _le16(bytes, 26) & 0x3fff,
          _le16(bytes, 28) & 0x3fff);
    }
    if (_matches(bytes, 12, [86, 80, 56, 76]) && bytes[20] == 0x2f) {
      final packed = _le32(bytes, 21);
      return _ImageHeader(UploadImageFormat.webp, (packed & 0x3fff) + 1,
          ((packed >>> 14) & 0x3fff) + 1);
    }
    throw const UploadFileException('corrupt_image');
  }
  return null;
}
