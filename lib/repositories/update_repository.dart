import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/network/network_proxy_io.dart';
import '../core/network/update_http_client.dart';
import '../models/apk_update.dart';
import '../core/services/release_link_opener.dart';
import '../core/storage/local_storage.dart';

enum UpdateStatus { available, current, ahead, noRelease }

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
    Future<String> Function()? readVersion,
    Future<int> Function()? readBuildNumber,
    this.timeout = const Duration(seconds: 15),
  })  : _storage = storage,
        _knownLatest = storage?.getLatestReleaseVersion(),
        _clientFactory = clientFactory ?? (() => UpdateHttpClient()),
        _readBuildNumber = readBuildNumber ??
            (() async =>
                int.parse((await PackageInfo.fromPlatform()).buildNumber)),
        _readVersion = readVersion ?? _installedVersion;

  static final endpoint =
      Uri.https('api.github.com', '/repos/fy142857/OViewer/releases/latest');
  final http.Client Function() _clientFactory;
  final Future<String> Function() _readVersion;
  final Future<int> Function() _readBuildNumber;
  final Duration timeout;
  final LocalStorage? _storage;
  String? _knownLatest;

  bool get updateAvailable => _knownLatest != null;

  /// Reconcile saved detection with the installed package, without networking.
  Future<void> restoreUpdateStatus() async {
    try {
      final installed = _version(await _readVersion());
      final known = _knownLatest;
      if (known != null && _compare(installed, _version(known)) >= 0) {
        await _saveKnownVersion(null);
      }
    } catch (_) {
      // Failure to identify the package is not evidence that it was upgraded.
      // Keep a saved update indication until a version comparison succeeds.
    }
  }

  Future<void> _saveKnownVersion(String? version) async {
    _knownLatest = version;
    try {
      await _storage?.setLatestReleaseVersion(version);
    } catch (_) {
      throw const UpdateCheckException(UpdateFailure.storage);
    }
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      final comparison = a[i].compareTo(b[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static Future<String> _installedVersion() async =>
      (await PackageInfo.fromPlatform()).version;

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
    late final List<int> installed;
    try {
      installed = _version(await _readVersion());
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
      if (!ReleaseLinkOpener.isReleaseUrl(url)) {
        throw const FormatException('Invalid release URL');
      }
      final comparison = _compare(latest, installed);
      if (cancelled()) throw const UpdateCheckException(UpdateFailure.network);
      await _saveKnownVersion(comparison > 0 ? latest.join('.') : null);
      ApkUpdate? apk;
      String? apkFailure;
      final notes =
          updateReleaseNotes(data['body'] as String? ?? '', latest.join('.'));
      if (android && comparison > 0) {
        try {
          apk = await _androidPackage(client, data, tag, url, notes);
          if (apk.buildNumber <= await _readBuildNumber()) {
            apkFailure = 'newer_build';
            apk = null;
          }
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

  Future<ApkUpdate> _androidPackage(http.Client client,
      Map<String, dynamic> data, String tag, Uri release, String notes) async {
    final assets = (data['assets'] as List).cast<Map<String, dynamic>>();
    Map<String, dynamic> asset(String name) {
      final value = assets.where((a) => a['name'] == name).single;
      if (!ApkUpdate.assetUrl(
          Uri.parse(value['browser_download_url'] as String), tag, name)) {
        throw const FormatException('Invalid release attachment');
      }
      return value;
    }

    final apk = asset('OViewer.apk');
    final manifest = asset('release-manifest.json');
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
    final root = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
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
