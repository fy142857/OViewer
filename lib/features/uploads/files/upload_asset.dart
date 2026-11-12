/// Limits are decimal bytes, matching the units shown by the upload UI.
class UploadFileLimits {
  static const maxImages = 2000;
  static const maxGalleryBytes = 10000000000;
  static const maxBatchBytes = 100000000;
  static const minDimension = 100;
  static const maxDimension = 20000;
  static const imageBytes = <UploadImageFormat, int>{
    UploadImageFormat.gif: 10000000,
    UploadImageFormat.jpeg: 20000000,
    UploadImageFormat.webp: 20000000,
    UploadImageFormat.png: 50000000,
  };
}

enum UploadImageFormat {
  jpeg('jpg', 'image/jpeg'),
  png('png', 'image/png'),
  gif('gif', 'image/gif'),
  webp('webp', 'image/webp');

  const UploadImageFormat(this.extension, this.mimeType);
  final String extension;
  final String mimeType;
}

enum UploadIssueSeverity { warning, error }

class ValidationIssue {
  const ValidationIssue(this.code,
      {this.severity = UploadIssueSeverity.error,
      this.displayName,
      this.limit,
      this.actual});
  final String code;
  final UploadIssueSeverity severity;
  final String? displayName;
  final int? limit;
  final int? actual;
}

/// Immutable inspection result. A name is frozen only when preparing a batch.
class PreparedUploadAsset {
  const PreparedUploadAsset({
    required this.relativePath,
    required this.displayName,
    required this.size,
    required this.sha256,
    required this.crc32,
    required this.format,
    required this.width,
    required this.height,
    this.animated = false,
    this.uploadName,
    this.issues = const [],
  });

  final String relativePath;
  final String displayName;
  final int size;
  final String sha256;
  final int crc32;
  final UploadImageFormat? format;
  final int? width;
  final int? height;
  final bool animated;
  final String? uploadName;
  final List<ValidationIssue> issues;
  bool get isValid =>
      format != null &&
      !issues.any((i) => i.severity == UploadIssueSeverity.error);

  PreparedUploadAsset withUploadName(String name) => PreparedUploadAsset(
        relativePath: relativePath,
        displayName: displayName,
        size: size,
        sha256: sha256,
        crc32: crc32,
        format: format,
        width: width,
        height: height,
        animated: animated,
        uploadName: name,
        issues: issues,
      );
}

class UploadBatch {
  UploadBatch({
    required this.relativePath,
    required this.size,
    required this.sha256,
    required List<PreparedUploadAsset> assets,
  }) : assets = List.unmodifiable(assets);
  final String relativePath;
  final int size;
  final String sha256;
  final List<PreparedUploadAsset> assets;
}

class UploadCancelled implements Exception {
  const UploadCancelled();
  @override
  String toString() => 'Upload preparation cancelled';
}

class UploadFileException implements Exception {
  const UploadFileException(this.code, {this.displayName});
  final String code;
  final String? displayName;
  @override
  String toString() => 'UploadFileException($code)';
}

/// Called between bounded reads/writes, never only after processing a full ZIP.
typedef UploadCancellation = bool Function();
typedef UploadSpaceProbe = Future<int> Function();

void checkUploadCancellation(UploadCancellation? isCancelled) {
  if (isCancelled?.call() == true) throw const UploadCancelled();
}
