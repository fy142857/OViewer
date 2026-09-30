import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/network/network_proxy_io.dart';
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
  const UpdateCheckResult(this.status, {this.version, this.releaseUrl});
  final UpdateStatus status;
  final String? version;
  final Uri? releaseUrl;
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
    this.timeout = const Duration(seconds: 15),
  })  : _storage = storage,
        _knownLatest = storage?.getLatestReleaseVersion(),
        _clientFactory =
            clientFactory ?? (() => IOClient(NetworkProxy.createHttpClient())),
        _readVersion = readVersion ?? _installedVersion;

  static final endpoint =
      Uri.https('api.github.com', '/repos/fy142857/OViewer/releases/latest');
  final http.Client Function() _clientFactory;
  final Future<String> Function() _readVersion;
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

  UpdateCheckOperation check() {
    final client = _clientFactory();
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      client.close();
    }

    Future<UpdateCheckResult> run() async {
      try {
        return await _check(client, () => closed).timeout(timeout);
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
      http.Client client, bool Function() cancelled) async {
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
      await _saveKnownVersion(comparison > 0 ? latest.join('.') : null);
      return UpdateCheckResult(
        comparison > 0
            ? UpdateStatus.available
            : comparison < 0
                ? UpdateStatus.ahead
                : UpdateStatus.current,
        version: tag,
        releaseUrl: url,
      );
    } on UpdateCheckException {
      rethrow;
    } catch (_) {
      throw const UpdateCheckException(UpdateFailure.invalidResponse);
    }
  }

  static List<int> _version(String value) {
    final match = RegExp(
            r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+[0-9A-Za-z.-]+)?$')
        .firstMatch(value);
    if (match == null) throw const FormatException('Invalid version');
    return [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }
}
