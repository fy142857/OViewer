import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:oviewer/repositories/update_repository.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fixtures/update_release.dart';

class UnwritableStorage extends LocalStorage {
  @override
  int? getLatestReleaseBuildNumber() => null;
  @override
  Future<void> setLatestReleaseBuildNumber(int? build) async {
    throw StateError('Preferences unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy version-only reminder is cleared without guessing a build',
      () async {
    SharedPreferences.setMockInitialValues({'latest_release_version': '9.0.0'});
    final storage = LocalStorage();
    await storage.init();
    final repo = UpdateRepository(
        storage: storage,
        readBuildNumber: () async => 32,
        clientFactory: () => throw StateError('No networking'));
    await repo.restoreUpdateStatus();
    expect(repo.updateAvailable, isFalse);
    expect(storage.prefs.containsKey('latest_release_version'), isFalse);
  });

  for (final android in [false, true]) {
    for (final invalid in [
      'missing',
      'schema',
      'tag',
      'platform',
      'candidate',
      'zero',
      'negative',
      'string',
      'fraction',
      'mismatch',
      'http',
      'oversize'
    ]) {
      test(
          'unverified $invalid manifest preserves saved build Android=$android',
          () async {
        SharedPreferences.setMockInitialValues(
            {'latest_release_build_number': 32});
        final storage = LocalStorage();
        await storage.init();
        final data = release();
        final manifest = releaseManifest();
        final platform = android ? 'android' : 'ios';
        final info = manifest[platform] as Map<String, dynamic>;
        final candidate = manifest['candidate'] as Map<String, dynamic>;
        switch (invalid) {
          case 'missing':
            data['assets'] = [];
          case 'schema':
            manifest['schema'] = 2;
          case 'tag':
            manifest['version'] = 'v1.3.0';
          case 'platform':
            info['platform'] = 'other';
          case 'candidate':
            candidate['version'] = '1.3.0';
            info['version'] = '1.3.0';
          case 'zero':
            candidate['build_number'] = info['build_number'] = 0;
          case 'negative':
            candidate['build_number'] = info['build_number'] = -1;
          case 'string':
            candidate['build_number'] = info['build_number'] = '32';
          case 'fraction':
            candidate['build_number'] = info['build_number'] = 32.5;
          case 'mismatch':
            info['build_number'] = 33;
        }
        final repo = UpdateRepository(
            storage: storage,
            readBuildNumber: () async => 1,
            clientFactory: () =>
                MockClient((r) async => r.url == UpdateRepository.endpoint
                    ? jsonResponse(data)
                    : invalid == 'http'
                        ? http.Response('', 404)
                        : invalid == 'oversize'
                            ? http.Response(' ' * (1024 * 1024 + 1), 200)
                            : jsonResponse(manifest)));
        final result = await repo.check(android: android).result;
        expect(result.status, UpdateStatus.unverified);
        expect(result.apk, isNull);
        expect(result.releaseUrl.toString(), release()['html_url']);
        expect(storage.getLatestReleaseBuildNumber(), 32);
      });
    }
  }

  test('cancellation while reading manifest cannot persist a late reminder',
      () async {
    final pending = Completer<http.Response>();
    final requested = Completer<void>();
    final repo = UpdateRepository(
        readBuildNumber: () async => 1,
        clientFactory: () => MockClient((r) {
              if (r.url == UpdateRepository.endpoint)
                return Future.value(jsonResponse(release()));
              requested.complete();
              return pending.future;
            }));
    final operation = repo.check();
    await requested.future;
    operation.cancel();
    pending.complete(jsonResponse(releaseManifest()));
    await expectLater(operation.result, throwsA(isA<UpdateCheckException>()));
    expect(repo.updateAvailable, isFalse);
  });

  test('cancellation during release lookup never starts a manifest request',
      () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    var requests = 0;
    final repo = UpdateRepository(
        readBuildNumber: () async => 1,
        clientFactory: () => MockClient((_) {
              requests++;
              started.complete();
              return response.future;
            }));
    final operation = repo.check();
    await started.future;
    operation.cancel();
    response.complete(jsonResponse(release()));
    await expectLater(operation.result, throwsA(isA<UpdateCheckException>()));
    expect(requests, 1);
    expect(repo.updateAvailable, isFalse);
  });
  testWidgets(
      'network preparation and release request share one timeout budget',
      (tester) async {
    final network = Completer<void>();
    final reply = Completer<http.Response>();
    NetworkProxy.beforeRequest = () => network.future;
    addTearDown(() => NetworkProxy.beforeRequest = null);
    final client = TrackingClient((_) => reply.future);
    final operation = UpdateRepository(
        timeout: const Duration(seconds: 1),
        clientFactory: () => client,
        readBuildNumber: () async => 1).check();
    final error = expectLater(
        operation.result,
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.failure, 'failure', UpdateFailure.timeout)));
    await tester.pump(const Duration(milliseconds: 800));
    network.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await error;
    expect(client.closes, 1);
    reply.complete(http.Response(jsonEncode(release()), 200));
    await tester.pump();
  });

  test('detection is persisted and restored without a network request',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final repo = UpdateRepository(
        storage: storage,
        readBuildNumber: () async => 1,
        clientFactory: () => ReleaseClient(
            (_) async => http.Response(jsonEncode(release()), 200)));
    expect((await repo.check().result).status, UpdateStatus.available);
    expect(storage.getLatestReleaseBuildNumber(), 32);
    final restoredStorage = LocalStorage();
    await restoredStorage.init();
    final restored = UpdateRepository(
        storage: restoredStorage,
        readBuildNumber: () async => 1,
        clientFactory: () => throw StateError('Must not request network'));
    await restored.restoreUpdateStatus();
    expect(restored.updateAvailable, isTrue);
  });

  for (final sample in [
    (31, true),
    (32, false),
    (33, false),
    (100, false),
    (200, false)
  ]) {
    test('saved reminder reconciles offline with installed ${sample.$1}',
        () async {
      SharedPreferences.setMockInitialValues(
          {'latest_release_build_number': 32});
      final storage = LocalStorage();
      await storage.init();
      final repo = UpdateRepository(
          storage: storage,
          readBuildNumber: () async => sample.$1,
          clientFactory: () => throw StateError('Must not request network'));
      await repo.restoreUpdateStatus();
      expect(repo.updateAvailable, sample.$2);
      expect(storage.getLatestReleaseBuildNumber(), sample.$2 ? 32 : null);
    });
  }

  for (final code in [200, 404, 403, 429, 500]) {
    test('HTTP $code preserves a previously detected update', () async {
      SharedPreferences.setMockInitialValues(
          {'latest_release_build_number': 32});
      final storage = LocalStorage();
      await storage.init();
      final repo = UpdateRepository(
          storage: storage,
          readBuildNumber: () async => 1,
          clientFactory: () =>
              MockClient((_) async => http.Response('', code)));
      if (code == 404) {
        expect((await repo.check().result).status, UpdateStatus.noRelease);
      } else {
        await expectLater(
            repo.check().result, throwsA(isA<UpdateCheckException>()));
      }
      expect(repo.updateAvailable, isTrue);
      expect(storage.getLatestReleaseBuildNumber(), 32);
    });
  }

  test('package lookup failure preserves the badge and can recover on retry',
      () async {
    SharedPreferences.setMockInitialValues({'latest_release_build_number': 32});
    final storage = LocalStorage();
    await storage.init();
    var fail = true;
    final repo = UpdateRepository(
        storage: storage,
        readBuildNumber: () async {
          if (fail) throw StateError('temporarily unavailable');
          return 32;
        },
        clientFactory: () => ReleaseClient(
            (_) async => http.Response(jsonEncode(release()), 200)));
    await repo.restoreUpdateStatus();
    expect(repo.updateAvailable, isTrue);
    fail = false;
    expect((await repo.check().result).status, UpdateStatus.current);
    expect(repo.updateAvailable, isFalse);
    expect(storage.getLatestReleaseBuildNumber(), isNull);
  });

  test(
      'a newer detection replaces the stored threshold instead of clearing it on any upgrade',
      () async {
    SharedPreferences.setMockInitialValues({'latest_release_build_number': 32});
    final storage = LocalStorage();
    await storage.init();
    final repo = UpdateRepository(
        storage: storage,
        readBuildNumber: () async => 1,
        clientFactory: () => MockClient((r) async => jsonResponse(
            r.url == UpdateRepository.endpoint
                ? release(tag: 'v1.3.0')
                : releaseManifest(version: '1.3.0', build: 40))));
    await repo.check().result;
    expect(storage.getLatestReleaseBuildNumber(), 40);
    final partialUpgrade =
        UpdateRepository(storage: storage, readBuildNumber: () async => 32);
    await partialUpgrade.restoreUpdateStatus();
    expect(partialUpgrade.updateAvailable, isTrue);
    expect(storage.getLatestReleaseBuildNumber(), 40);
  });

  test('storage failures are distinguished from network and response errors',
      () async {
    final repo = UpdateRepository(
        storage: UnwritableStorage(),
        readBuildNumber: () async => 1,
        clientFactory: () => ReleaseClient(
            (_) async => http.Response(jsonEncode(release()), 200)));
    await expectLater(
        repo.check().result,
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.failure, 'failure', UpdateFailure.storage)));
    expect(repo.updateAvailable, isTrue);
  });

  for (final android in [false, true]) {
    for (final sample in [
      ('1.2.0', 31, UpdateStatus.available),
      ('1.2.0', 32, UpdateStatus.current),
      ('1.2.0', 33, UpdateStatus.ahead),
      ('9.0.0', 31, UpdateStatus.available),
      ('0.1.0', 32, UpdateStatus.current),
      ('0.1.0', 99, UpdateStatus.ahead),
    ]) {
      test('build comparison ignores version name $sample Android=$android',
          () async {
        PackageInfo.setMockInitialValues(
            appName: 'OViewer',
            packageName: 'com.oviewer.oviewer',
            version: sample.$1,
            buildNumber: '${sample.$2}',
            buildSignature: '');
        final calls = <Uri>[];
        final client = TrackingClient((request) async {
          calls.add(request.url);
          expect(request.headers['cookie'], isNull);
          expect(request.headers['authorization'], isNull);
          return jsonResponse(request.url == UpdateRepository.endpoint
              ? release()
              : releaseManifest());
        });
        final repo = UpdateRepository(clientFactory: () => client);
        final result = await repo.check(android: android).result;
        expect(result.status, sample.$3);
        expect(result.version, 'v1.2.0');
        expect(repo.updateAvailable, sample.$3 == UpdateStatus.available);
        expect(
            result.apk != null, android && sample.$3 == UpdateStatus.available);
        expect(calls.length, 2);
        expect(client.closes, 1);
      });
    }
  }

  test('404 means no published release', () async {
    final repo = UpdateRepository(
        clientFactory: () => MockClient((_) async => http.Response('', 404)),
        readBuildNumber: () async => 1);
    expect((await repo.check().result).status, UpdateStatus.noRelease);
  });

  for (final code in [403, 429, 500]) {
    test('handles HTTP $code', () async {
      final repo = UpdateRepository(
          clientFactory: () => MockClient((_) async => http.Response('', code)),
          readBuildNumber: () async => 1);
      await expectLater(
          repo.check().result,
          throwsA(isA<UpdateCheckException>().having(
              (e) => e.failure,
              'failure',
              code == 500
                  ? UpdateFailure.network
                  : UpdateFailure.rateLimited)));
    });
  }

  for (final data in [
    'invalid json',
    jsonEncode({}),
    jsonEncode({...release(), 'tag_name': 'unknown'}),
    jsonEncode({...release(), 'prerelease': true}),
    jsonEncode({...release(), 'draft': true}),
    jsonEncode({...release(), 'html_url': 'https://example.com/release'}),
    jsonEncode({
      ...release(),
      'html_url': 'https://github.com/other/repo/releases/tag/v2'
    }),
  ]) {
    test('rejects invalid release: $data', () async {
      final repo = UpdateRepository(
          clientFactory: () =>
              MockClient((_) async => http.Response(data, 200)),
          readBuildNumber: () async => 1);
      await expectLater(
          repo.check().result,
          throwsA(isA<UpdateCheckException>().having(
              (e) => e.failure, 'failure', UpdateFailure.invalidResponse)));
    });
  }

  test('missing installed version makes no request and closes client',
      () async {
    final client =
        TrackingClient((_) async => throw StateError('Must not request'));
    final repo = UpdateRepository(
        clientFactory: () => client, readBuildNumber: () async => 0);
    await expectLater(
        repo.check().result,
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.failure, 'failure', UpdateFailure.version)));
    expect(client.closes, 1);
  });

  test('network errors close the client', () async {
    final client =
        TrackingClient((_) async => throw http.ClientException('offline'));
    final repo = UpdateRepository(
        clientFactory: () => client, readBuildNumber: () async => 1);
    await expectLater(
        repo.check().result,
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.failure, 'failure', UpdateFailure.network)));
    expect(client.closes, 1);
  });

  test('timeout closes client', () async {
    final pending = Completer<http.Response>();
    final client = TrackingClient((_) => pending.future);
    final repo = UpdateRepository(
        clientFactory: () => client,
        readBuildNumber: () async => 1,
        timeout: const Duration(milliseconds: 10));
    await expectLater(
        repo.check().result,
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.failure, 'failure', UpdateFailure.timeout)));
    expect(client.closes, 1);
    pending.complete(http.Response(jsonEncode(release()), 200));
  });

  test('cancel before package lookup completes prevents request', () async {
    final version = Completer<int>();
    var requests = 0;
    final client = TrackingClient((_) async {
      requests++;
      return http.Response(jsonEncode(release()), 200);
    });
    final operation = UpdateRepository(
        clientFactory: () => client,
        readBuildNumber: () => version.future).check();
    operation.cancel();
    operation.cancel();
    version.complete(1);
    await expectLater(operation.result, throwsA(isA<UpdateCheckException>()));
    expect(requests, 0);
    expect(client.closes, 0, reason: 'Cancelled before the client was created');
  });
}
