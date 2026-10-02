import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/network/network_preparation.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'package:oviewer/core/network/system_proxy_detector.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'comment_redirect_test.dart' show client, RedirectAdapter, FakeDio;

class HeaderCookies extends Fake implements CookieManager {
  @override
  Future<void> applyRequestHeaders(
      Uri uri, Map<String, String> headers) async {}
}

void main() {
  setUpAll(() => registerFallbackValue(FakeDio()));
  tearDown(() => NetworkProxy.beforeRequest = null);
  for (final cancel in [false, true]) {
    test('reader image client waits for network readiness (cancel=$cancel)',
        () async {
      final ready = Completer<void>();
      NetworkProxy.beforeRequest = () => ready.future;
      var created = 0;
      var sent = 0;
      final requests = ReaderRequestController(imageClientFactory: () {
        created++;
        return MockClient((_) async {
          sent++;
          return http.Response('image', 200);
        });
      });
      final files =
          EhImageCacheManager.readerFileService(HeaderCookies(), requests);
      final response = files.get('https://example.test/image');
      await Future<void>.delayed(Duration.zero);
      expect(created, 0);
      expect(sent, 0);
      if (cancel) requests.cancel();
      if (cancel) {
        final error = expectLater(response, throwsStateError);
        ready.complete();
        await error;
        expect(created, 0);
        expect(sent, 0);
      } else {
        ready.complete();
        await (await response).content.drain<void>();
        expect(created, 1);
        expect(sent, 1);
        requests.cancel();
      }
    });
  }
  test(
      'preparation is shared and queued Dio requests wait until policy is applied',
      () async {
    final probe = Completer<AutoProxyResult>();
    final applied = <String?>[];
    var probes = 0;
    final network = NetworkPreparation(
        manualProxy: null,
        autoProxy: true,
        apply: applied.add,
        detect: () {
          probes++;
          return probe.future;
        });
    NetworkProxy.beforeRequest = network.waitUntilReady;
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString('ok', 200));
    final request = client(adapter).get('https://e-hentai.org/');
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, isEmpty);
    expect(probes, 0);
    final first = network.start();
    final second = network.start();
    expect(probes, 1);
    expect(adapter.requests, isEmpty);
    probe.complete(const AutoProxyResult(
        proxyUrl: 'http://127.0.0.1:7890', vpnActive: true));
    await Future.wait([first, second]);
    expect(await request, 'ok');
    expect(applied, ['http://127.0.0.1:7890']);
    expect(adapter.requests, hasLength(1));
    network.dispose();
  });
  test(
      'manual choice supersedes startup probe and releases its waiting requests',
      () async {
    final probe = Completer<AutoProxyResult>();
    final applied = <String?>[];
    final network = NetworkPreparation(
        manualProxy: null,
        autoProxy: true,
        apply: applied.add,
        detect: () => probe.future);
    final started = network.start();
    await network.configure(manualProxy: 'http://chosen:8080', autoProxy: true);
    await started;
    probe.complete(
        const AutoProxyResult(proxyUrl: 'http://old:7890', vpnActive: true));
    await Future<void>.delayed(Duration.zero);
    expect(applied, ['http://chosen:8080']);
    network.dispose();
  });
  test('manual proxy and disabled autodetect never start probes', () async {
    for (final manual in ['http://manual:8080', null]) {
      final applied = <String?>[];
      final network = NetworkPreparation(
          manualProxy: manual,
          autoProxy: manual != null,
          apply: applied.add,
          detect: () async => throw TestFailure('Unexpected probe'));
      await network.start();
      expect(applied, [manual]);
      network.dispose();
    }
  });
  test('cancellation while network is pending sends no HTTP request', () async {
    final ready = Completer<void>();
    NetworkProxy.beforeRequest = () => ready.future;
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString('ok', 200));
    final token = CancelToken();
    final result =
        client(adapter).get('https://e-hentai.org/', cancelToken: token);
    token.cancel();
    await expectLater(result, throwsA(isA<DioException>()));
    expect(adapter.requests, isEmpty);
    ready.complete();
  });
  test('environment proxy and absent VPN skip port probing', () async {
    for (final env in ['http://environment:8080', null]) {
      final result = await SystemProxyDetector.detect(
          environmentProxy: () => env,
          vpnCheck: () async => false,
          localProbe: () async => throw TestFailure('Unexpected port scan'));
      expect(result.proxyUrl, env);
      expect(result.vpnActive, isFalse);
    }
  });
  testWidgets(
      'ports probe concurrently, preserve priority and only then fall back to emulator',
      (tester) async {
    final calls = <String>[];
    final pending = <String, Completer<bool>>{};
    final result = SystemProxyDetector.probeLocalProxy(
        hosts: ['local', 'emulator'],
        ports: [1, 2, 3],
        probe: (host, port) {
          final key = '$host:$port';
          calls.add(key);
          return (pending[key] = Completer<bool>()).future;
        });
    expect(calls, ['local:1', 'local:2', 'local:3']);
    for (final c in pending.values) {
      c.complete(false);
    }
    await tester.pump();
    expect(calls, [
      'local:1',
      'local:2',
      'local:3',
      'emulator:1',
      'emulator:2',
      'emulator:3'
    ]);
    pending['emulator:3']!.complete(true);
    pending['emulator:2']!.complete(true);
    pending['emulator:1']!.complete(false);
    expect(await result, 'http://emulator:2');
  });
  testWidgets('two unreachable host groups finish within two 500ms windows',
      (tester) async {
    var finished = false;
    final result = SystemProxyDetector.probeLocalProxy(
        hosts: ['a', 'b'],
        probe: (_, __) => Completer<bool>().future).then((value) {
      finished = true;
      return value;
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(finished, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(await result, isNull);
  });
  testWidgets(
      'VPN enumeration timeout falls back without blocking startup indefinitely',
      (tester) async {
    final result = SystemProxyDetector.detect(
        environmentProxy: () => null,
        vpnCheck: () => Completer<bool>().future,
        localProbe: () async => throw TestFailure('Unexpected port scan'));
    await tester.pump(const Duration(milliseconds: 500));
    expect((await result).proxyUrl, isNull);
  });
}
