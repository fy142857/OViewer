import '../core/services/release_link_opener.dart';

class ApkUpdate {
  const ApkUpdate(
      {required this.version,
      required this.buildNumber,
      required this.releaseUrl,
      required this.downloadUrl,
      required this.size,
      required this.sha256,
      required this.certificate,
      required this.notes});
  final String version;
  final int buildNumber;
  final Uri releaseUrl;
  final Uri downloadUrl;
  final int size;
  final String sha256;
  final String certificate;
  final String notes;

  static bool assetUrl(Uri url, String tag, String name) =>
      url.scheme == 'https' &&
      url.host == 'github.com' &&
      url.userInfo.isEmpty &&
      (!url.hasPort || url.port == 443) &&
      url.query.isEmpty &&
      url.fragment.isEmpty &&
      url.path == '/fy142857/OViewer/releases/download/$tag/$name';

  factory ApkUpdate.fromJson(Map<String, dynamic> json) {
    final value = ApkUpdate(
        version: json['version'] as String,
        buildNumber: json['buildNumber'] as int,
        releaseUrl: Uri.parse(json['releaseUrl'] as String),
        downloadUrl: Uri.parse(json['downloadUrl'] as String),
        size: json['size'] as int,
        sha256: json['sha256'] as String,
        certificate: json['certificate'] as String,
        notes: json['notes'] as String);
    final digest = RegExp(r'^[a-f0-9]{64}$');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value.version) ||
        value.buildNumber <= 0 ||
        value.size <= 0 ||
        !digest.hasMatch(value.sha256) ||
        !digest.hasMatch(value.certificate) ||
        !ReleaseLinkOpener.isReleaseUrl(value.releaseUrl) ||
        value.releaseUrl.pathSegments.last != 'v${value.version}' ||
        !assetUrl(value.downloadUrl, 'v${value.version}', 'OViewer.apk')) {
      throw const FormatException('Invalid APK metadata');
    }
    return value;
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'buildNumber': buildNumber,
        'releaseUrl': releaseUrl.toString(),
        'downloadUrl': downloadUrl.toString(),
        'size': size,
        'sha256': sha256,
        'certificate': certificate,
        'notes': notes,
      };
}

/// Only the requested version's Added/Changed sections, never build provenance.
String updateReleaseNotes(String body, String version) {
  final output = <String>[];
  var include = false;
  var enteredVersion = false;
  var inVersion = true; // Release bodies may omit a version heading.
  var sectionLevel = 0;
  var fenced = false;
  for (final line in body.split('\n')) {
    if (line.trimLeft().startsWith('```') ||
        line.trimLeft().startsWith('~~~')) {
      fenced = !fenced;
      if (include && inVersion) output.add(line);
      continue;
    }
    final heading =
        fenced ? null : RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(line);
    if (heading != null) {
      final title = heading[2]!.trim();
      final v = RegExp(r'^\[?v?(\d+\.\d+\.\d+)\]?(?:\s|$)').firstMatch(title);
      if (v != null || title.toLowerCase().contains('[unreleased]')) {
        if (enteredVersion) break;
        inVersion = v?[1] == version;
        enteredVersion = inVersion;
        include = false;
        continue;
      }
      final level = heading[1]!.length;
      if (include && level > sectionLevel) {
        if (inVersion) output.add(line);
        continue;
      }
      include =
          const ['新增', '变更', 'added', 'changed'].contains(title.toLowerCase());
      sectionLevel = level;
      if (include && inVersion) output.add('\n$title');
    } else if (include && inVersion) {
      output.add(line);
    }
  }
  return output.join('\n').trim();
}
