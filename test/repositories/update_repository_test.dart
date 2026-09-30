import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oviewer/repositories/update_repository.dart';

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

void main() {
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
    expect(client.closes, 1);
  });
}
