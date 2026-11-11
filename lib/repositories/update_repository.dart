import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/network/network_proxy_io.dart';
import '../core/network/update_http_client.dart';
import '../models/apk_update.dart';
import '../core/services/release_link_opener.dart';
import '../core/storage/local_storage.dart';

enum UpdateStatus { available, current, ahead, noRelease, unverified }

enum UpdateFailure {
  network,
  timeout,
  rateLimited,
  invalidResponse,
  version,
  storage
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.failure);
  final UpdateFailure failure;
}

class UpdateCheckResult {
  const UpdateCheckResult(this.status,
      {this.version,
      this.releaseUrl,
      this.apk,
      this.apkFailure,
      this.notes = ''});
  final UpdateStatus status;
  final String? version;
  final Uri? releaseUrl;
  final ApkUpdate? apk;
  final String? apkFailure;
  final String notes;
}

/// Each button press owns its client, so leaving settings cancels its work.
class UpdateCheckOperation {
  UpdateCheckOperation(this.result, this.cancel);
  final Future<UpdateCheckResult> result;
  final void Function() cancel;
}

class UpdateRepository {
  UpdateRepository({
    LocalStorage? storage,
    http.Client Function()? clientFactory,
    Future<int> Function()? readBuildNumber,
    this.timeout = const Duration(seconds: 15),
  })  : _storage = storage,
        _knownLatest = storage?.getLatestReleaseBuildNumber(),
        _clientFactory = clientFactory ?? (() => UpdateHttpClient()),
        _readBuildNumber = readBuildNumber ??
            (() async =>
                int.parse((await PackageInfo.fromPlatform()).buildNumber));

  static final endpoint =
      Uri.https('api.github.com', '/repos/fy142857/OViewer/releases/latest');
  final http.Client Function() _clientFactory;
  final Future<int> Function() _readBuildNumber;
  final Duration timeout;
  final LocalStorage? _storage;
  int? _knownLatest;

  bool get updateAvailable => _knownLatest != null;

  /// Reconcile saved detection with the installed package, without networking.
  Future<void> restoreUpdateStatus() async {
    try {
      final installed = await _readBuildNumber();
      if (installed <= 0) return;
      final known = _knownLatest;
      if (known == null || installed >= known) {
        // Old version-name-only reminders cannot establish a newer build.
        await _saveKnownBuild(null);
      }
    } catch (_) {
      // Failure to identify the package is not evidence that it was upgraded.
      // Keep a saved update indication until a build comparison succeeds.
    }
  }

  Future<void> _saveKnownBuild(int? build) async {
    _knownLatest = build;
    try {
      await _storage?.setLatestReleaseBuildNumber(build);
    } catch (_) {
      throw const UpdateCheckException(UpdateFailure.storage);
    }
  }

  UpdateCheckOperation check({bool android = false}) {
    http.Client? client;
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      client?.close();
    }

    Future<UpdateCheckResult> whenReady() async {
      await NetworkProxy.waitUntilReady();
      if (closed) throw const UpdateCheckException(UpdateFailure.network);
      client = _clientFactory();
      return _check(client!, () => closed, android);
    }

    Future<UpdateCheckResult> run() async {
      try {
        return await whenReady().timeout(timeout);
      } on UpdateCheckException {
        rethrow;
      } on TimeoutException {
        throw const UpdateCheckException(UpdateFailure.timeout);
      } catch (_) {
        throw const UpdateCheckException(UpdateFailure.network);
      } finally {
        close();
      }
    }

    return UpdateCheckOperation(run(), close);
  }

  Future<UpdateCheckResult> _check(
      http.Client client, bool Function() cancelled, bool android) async {
    late final int installed;
    try {
      installed = await _readBuildNumber();
      if (installed <= 0) throw const FormatException('Invalid build number');
    } catch (_) {
      throw const UpdateCheckException(UpdateFailure.version);
    }
    if (cancelled()) {
      throw const UpdateCheckException(UpdateFailure.network);
    }
    final response = await client.get(endpoint, headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'OViewer-update-check',
    });
    if (cancelled()) throw const UpdateCheckException(UpdateFailure.network);
    if (response.statusCode == 404) {
      return const UpdateCheckResult(UpdateStatus.noRelease);
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateCheckException(UpdateFailure.rateLimited);
    }
    if (response.statusCode != 200) {
      throw const UpdateCheckException(UpdateFailure.network);
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['draft'] != false || data['prerelease'] != false) {
        throw const FormatException('Expected a stable release');
      }
      final tag = data['tag_name'] as String;
      final latest = _version(tag);
      final url = Uri.parse(data['html_url'] as String);
      if (!ReleaseLinkOpener.isReleaseUrl(url) ||
          url.pathSegments.last != tag) {
        throw const FormatException('Invalid release URL');
      }
      final notes =
          updateReleaseNotes(data['body'] as String? ?? '', latest.join('.'));
      late final Map<String, dynamic> manifest;
      late final int build;
      try {
        manifest = await _releaseManifest(client, data, tag);
        final platform = android ? 'android' : 'ios';
        final info = manifest[platform] as Map<String, dynamic>;
        final candidate = manifest['candidate'] as Map<String, dynamic>;
        if (manifest['schema'] != 1 ||
            manifest['version'] != tag ||
            candidate['version'] != latest.join('.') ||
            info['schema'] != 1 ||
            info['platform'] != platform ||
            const [
              'version',
              'build_number',
              'candidate_id',
              'build_sha',
              'source_sha'
            ].any((key) => info[key] == null || info[key] != candidate[key])) {
          throw const FormatException('Inconsistent release manifest');
        }
        build = info['build_number'] as int;
        if (build <= 0) throw const FormatException('Invalid release build');
      } catch (_) {
        if (cancelled())
          throw const UpdateCheckException(UpdateFailure.network);
        // Keep a reachable release page, but never infer an update from its name.
        return UpdateCheckResult(UpdateStatus.unverified,
            version: tag,
            releaseUrl: url,
            apkFailure: 'metadata',
            notes: notes);
      }
      final comparison = build.compareTo(installed);
      if (cancelled()) throw const UpdateCheckException(UpdateFailure.network);
      await _saveKnownBuild(comparison > 0 ? build : null);
      ApkUpdate? apk;
      String? apkFailure;
      if (android && comparison > 0) {
        try {
          apk = _androidPackage(data, manifest, tag, url, notes);
        } catch (_) {
          apkFailure = 'metadata';
        }
      }
      if (cancelled()) throw const UpdateCheckException(UpdateFailure.network);
      return UpdateCheckResult(
        comparison > 0
            ? UpdateStatus.available
            : comparison < 0
                ? UpdateStatus.ahead
                : UpdateStatus.current,
        version: tag,
        releaseUrl: url,
        apk: apk,
        apkFailure: apkFailure,
        notes: notes,
      );
    } on UpdateCheckException {
      rethrow;
    } catch (_) {
      throw const UpdateCheckException(UpdateFailure.invalidResponse);
    }
  }

  Map<String, dynamic> _asset(
      Map<String, dynamic> data, String tag, String name) {
    final assets = (data['assets'] as List).cast<Map<String, dynamic>>();
    final value = assets.where((a) => a['name'] == name).single;
    if (!ApkUpdate.assetUrl(
        Uri.parse(value['browser_download_url'] as String), tag, name)) {
      throw const FormatException('Invalid release attachment');
    }
    return value;
  }

  Future<Map<String, dynamic>> _releaseManifest(
      http.Client client, Map<String, dynamic> data, String tag) async {
    final manifest = _asset(data, tag, 'release-manifest.json');
    final response = await client.send(http.Request(
        'GET', Uri.parse(manifest['browser_download_url'] as String)));
    if (response.statusCode != 200)
      throw const FormatException('Missing manifest');
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 1024 * 1024)
        throw const FormatException('Manifest too large');
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  ApkUpdate _androidPackage(Map<String, dynamic> data,
      Map<String, dynamic> root, String tag, Uri release, String notes) {
    final apk = _asset(data, tag, 'OViewer.apk');
    final info = root['android'] as Map<String, dynamic>;
    final candidate = root['candidate'] as Map<String, dynamic>;
    if (root['schema'] != 1 ||
        root['version'] != tag ||
        info['schema'] != 1 ||
        info['platform'] != 'android' ||
        info['filename'] != 'OViewer.apk' ||
        'v${info['version']}' != tag ||
        info['size'] != apk['size'] ||
        const [
          'version',
          'build_number',
          'candidate_id',
          'build_sha',
          'source_sha'
        ].any((key) => info[key] == null || info[key] != candidate[key])) {
      throw const FormatException('Inconsistent release manifest');
    }
    return ApkUpdate.fromJson({
      'version': info['version'],
      'buildNumber': info['build_number'],
      'releaseUrl': release.toString(),
      'downloadUrl': apk['browser_download_url'],
      'size': info['size'],
      'sha256': info['sha256'],
      'certificate': info['signing_cert_sha256'],
      'notes': notes,
    });
  }

  static List<int> _version(String value) {
    final match = RegExp(
            r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+[0-9A-Za-z.-]+)?$')
        .firstMatch(value);
    if (match == null) throw const FormatException('Invalid version');
    return [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }
}
