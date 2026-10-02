import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oviewer/repositories/update_repository.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> release({String tag = 'v1.2.0'}) => {
      'tag_name': tag,
      'html_url': 'https://github.com/fy142857/OViewer/releases/tag/$tag',
      'draft': false,
      'prerelease': false,
    };

class TrackingClient extends MockClient {
  TrackingClient(super.handler);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

class UnwritableStorage extends LocalStorage {
  @override
  String? getLatestReleaseVersion() => null;
  @override
  Future<void> setLatestReleaseVersion(String? version) async {
    throw StateError('Preferences unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
        readVersion: () async => '1.0.0').check();
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
        readVersion: () async => '1.0.0',
        clientFactory: () =>
            MockClient((_) async => http.Response(jsonEncode(release()), 200)));
    expect((await repo.check().result).status, UpdateStatus.available);
    expect(storage.getLatestReleaseVersion(), '1.2.0');
    final restoredStorage = LocalStorage();
    await restoredStorage.init();
    final restored = UpdateRepository(
        storage: restoredStorage,
        readVersion: () async => '1.0.0',
        clientFactory: () => throw StateError('Must not request network'));
    await restored.restoreUpdateStatus();
    expect(restored.updateAvailable, isTrue);
  });

  for (final sample in [
    ('1.1.9', true),
    ('1.2.0', false),
    ('1.2.0+99', false),
    ('1.2.1', false),
    ('2.0.0', false)
  ]) {
    test('saved reminder reconciles offline with installed ${sample.$1}',
        () async {
      SharedPreferences.setMockInitialValues(
          {'latest_release_version': '1.2.0'});
      final storage = LocalStorage();
      await storage.init();
      final repo = UpdateRepository(
          storage: storage,
          readVersion: () async => sample.$1,
          clientFactory: () => throw StateError('Must not request network'));
      await repo.restoreUpdateStatus();
      expect(repo.updateAvailable, sample.$2);
      expect(storage.getLatestReleaseVersion(), sample.$2 ? '1.2.0' : null);
    });
  }

  for (final code in [200, 404, 403, 429, 500]) {
    test('HTTP $code preserves a previously detected update', () async {
      SharedPreferences.setMockInitialValues(
          {'latest_release_version': '1.2.0'});
      final storage = LocalStorage();
      await storage.init();
      final repo = UpdateRepository(
          storage: storage,
          readVersion: () async => '1.0.0',
          clientFactory: () =>
              MockClient((_) async => http.Response('', code)));
      if (code == 404) {
        expect((await repo.check().result).status, UpdateStatus.noRelease);
      } else {
        await expectLater(
            repo.check().result, throwsA(isA<UpdateCheckException>()));
      }
      expect(repo.updateAvailable, isTrue);
      expect(storage.getLatestReleaseVersion(), '1.2.0');
    });
  }

  test('package lookup failure preserves the badge and can recover on retry',
      () async {
    SharedPreferences.setMockInitialValues({'latest_release_version': '1.2.0'});
    final storage = LocalStorage();
    await storage.init();
    var fail = true;
    final repo = UpdateRepository(
        storage: storage,
        readVersion: () async {
          if (fail) throw StateError('temporarily unavailable');
          return '1.2.0';
        },
        clientFactory: () =>
            MockClient((_) async => http.Response(jsonEncode(release()), 200)));
    await repo.restoreUpdateStatus();
    expect(repo.updateAvailable, isTrue);
    fail = false;
    expect((await repo.check().result).status, UpdateStatus.current);
    expect(repo.updateAvailable, isFalse);
    expect(storage.getLatestReleaseVersion(), isNull);
  });

  test(
      'a newer detection replaces the stored threshold instead of clearing it on any upgrade',
      () async {
    SharedPreferences.setMockInitialValues({'latest_release_version': '1.2.0'});
    final storage = LocalStorage();
    await storage.init();
    final repo = UpdateRepository(
        storage: storage,
        readVersion: () async => '1.0.0',
        clientFactory: () => MockClient((_) async =>
            http.Response(jsonEncode(release(tag: 'v1.3.0')), 200)));
    await repo.check().result;
    expect(storage.getLatestReleaseVersion(), '1.3.0');
    final partialUpgrade =
        UpdateRepository(storage: storage, readVersion: () async => '1.2.0');
    await partialUpgrade.restoreUpdateStatus();
    expect(partialUpgrade.updateAvailable, isTrue);
    expect(storage.getLatestReleaseVersion(), '1.3.0');
  });

  test('storage failures are distinguished from network and response errors',
      () async {
    final repo = UpdateRepository(
        storage: UnwritableStorage(),
        readVersion: () async => '1.0.0',
        clientFactory: () =>
            MockClient((_) async => http.Response(jsonEncode(release()), 200)));
    await expectLater(
        repo.check().result,
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.failure, 'failure', UpdateFailure.storage)));
    expect(repo.updateAvailable, isTrue);
  });

  for (final sample in [
    ('1.2.0', 'v1.2.0', UpdateStatus.current),
    ('1.2.0+31', '1.2.0+32', UpdateStatus.current),
    ('1.9.0', 'v1.10.0', UpdateStatus.available),
    ('1.2.0', 'v1.2.1', UpdateStatus.available),
    ('1.99.99', 'v2.0.0', UpdateStatus.available),
    ('2.0.0', 'v1.9.0', UpdateStatus.ahead),
  ]) {
    test('compares ${sample.$1} with ${sample.$2} numerically', () async {
      final client = TrackingClient((request) async {
        expect(request.url, UpdateRepository.endpoint);
        expect(request.headers['cookie'], isNull);
        expect(request.headers['authorization'], isNull);
        expect(request.headers['accept'], 'application/vnd.github+json');
        return http.Response(jsonEncode(release(tag: sample.$2)), 200);
      });
      final repo = UpdateRepository(
          clientFactory: () => client, readVersion: () async => sample.$1);
      final result = await repo.check().result;
      expect(result.status, sample.$3);
      expect(result.version, sample.$2);
      expect(result.releaseUrl!.host, 'github.com');
      expect(client.closes, 1);
    });
  }

  test('404 means no published release', () async {
    final repo = UpdateRepository(
        clientFactory: () => MockClient((_) async => http.Response('', 404)),
        readVersion: () async => '1.0.0');
    expect((await repo.check().result).status, UpdateStatus.noRelease);
  });

  for (final code in [403, 429, 500]) {
    test('handles HTTP $code', () async {
      final repo = UpdateRepository(
          clientFactory: () => MockClient((_) async => http.Response('', code)),
          readVersion: () async => '1.0.0');
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
          readVersion: () async => '1.0.0');
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
        clientFactory: () => client, readVersion: () async => '');
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
        clientFactory: () => client, readVersion: () async => '1.0.0');
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
        readVersion: () async => '1.0.0',
        timeout: const Duration(milliseconds: 10));
    await expectLater(
        repo.check().result,
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.failure, 'failure', UpdateFailure.timeout)));
    expect(client.closes, 1);
    pending.complete(http.Response(jsonEncode(release()), 200));
  });

  test('cancel before package lookup completes prevents request', () async {
    final version = Completer<String>();
    var requests = 0;
    final client = TrackingClient((_) async {
      requests++;
      return http.Response(jsonEncode(release()), 200);
    });
    final operation = UpdateRepository(
        clientFactory: () => client, readVersion: () => version.future).check();
    operation.cancel();
    operation.cancel();
    version.complete('1.0.0');
    await expectLater(operation.result, throwsA(isA<UpdateCheckException>()));
    expect(requests, 0);
    expect(client.closes, 0, reason: 'Cancelled before the client was created');
  });
}
