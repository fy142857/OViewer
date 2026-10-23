import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/automatic_login_check.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oviewer/automatic_login_check');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    NetworkProxy.setProxy(null);
  });
  AutomaticLoginCheck check() => AutomaticLoginCheck(
      timeout: const Duration(milliseconds: 100),
      pollInterval: const Duration(milliseconds: 1),
      snapshotReader: (id, script) =>
          channel.invokeMapMethod<String, dynamic>('inspect', {'id': id}));
  test(
      'automatic loading waits for the form and returns only challenge cookies',
      () async {
    var inspected = 0;
    var closed = 0;
    NetworkProxy.setProxy('http://127.0.0.1:7890');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'begin') {
        final args = call.arguments as Map;
        expect(args.keys, unorderedEquals(['id', 'proxy']));
        expect(args['proxy'], 'http://127.0.0.1:7890');
        return true;
      }
      if (call.method == 'close') {
        closed++;
        return null;
      }
      return ++inspected < 3
          ? {'ready': false}
          : {
              'ready': true,
              'userAgent': 'native',
              'formHtml': '<form method="post"></form>',
              'formUrl':
                  'https://forums.e-hentai.org/index.php?act=Login&CODE=00',
              'cookies': 'cf_clearance=abc=def; ipb_pass_hash=never; __cf_bm=bm'
            };
    });
    final result = await check().run(CancelToken());
    expect(result.status, BrowserCheckStatus.ready);
    expect(result.cookies.map((c) => c.name), ['cf_clearance', '__cf_bm']);
    expect(result.cookies.first.value, 'abc=def');
    expect(result.userAgent, 'native');
    expect(inspected, 3);
    expect(closed, 1);
  });
  for (final interactive in [true, false]) {
    test(
        interactive
            ? 'manual CAPTCHA is distinguished'
            : 'timeout does not claim manual CAPTCHA', () async {
      var closed = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'begin') return true;
        if (call.method == 'close') {
          closed = true;
          return null;
        }
        return {'interactive': interactive};
      });
      final result = await check().run(CancelToken());
      expect(
          result.status,
          interactive
              ? BrowserCheckStatus.interactive
              : BrowserCheckStatus.unavailable);
      expect(closed, isTrue);
    });
  }
  test(
      'cancelling a pending inspection closes the browser and rejects late readiness',
      () async {
    final inspected = Completer<void>();
    final pending = Completer<Map<String, dynamic>>();
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'begin') return true;
      if (call.method == 'close') {
        closed = true;
        return null;
      }
      inspected.complete();
      return pending.future;
    });
    final token = CancelToken();
    final result = check().run(token);
    final assertion = expectLater(result, throwsA(isA<DioException>()));
    await inspected.future;
    token.cancel();
    await assertion;
    expect(closed, isTrue);
    pending.complete({'ready': true, 'userAgent': 'late'});
  });
  test('proxy change prevents using clearance from the old network route',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'begin') return true;
      if (call.method == 'close') return null;
      NetworkProxy.setProxy('http://127.0.0.1:7890');
      return {'ready': true, 'userAgent': 'native'};
    });
    expect((await check().run(CancelToken())).status,
        BrowserCheckStatus.unavailable);
  });
  test('unexpected prepared form URL never releases a result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'begin') return true;
      if (call.method == 'close') return null;
      return {
        'ready': true,
        'userAgent': 'native',
        'formHtml': '<form></form>',
        'formUrl': 'https://example.com/index.php',
        'cookies': 'cf_clearance=not-imported'
      };
    });
    expect((await check().run(CancelToken())).status,
        BrowserCheckStatus.unavailable);
  });
  test(
      'inline verification remains available for user interaction until a response is ready',
      () async {
    var inspected = 0;
    Future<Map<String, dynamic>?> inspector(String script) async => null;
    void mounted() {
      final id = AutomaticLoginCheck.activeView.value;
      if (id != null) AutomaticLoginCheck.attach(id, inspector);
    }

    AutomaticLoginCheck.activeView.addListener(mounted);
    addTearDown(() => AutomaticLoginCheck.activeView.removeListener(mounted));
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'begin') return true;
      if (call.method == 'close') return null;
      if (++inspected == 1) return {'interactive': true, 'interacted': true};
      return {
        'ready': true,
        'userAgent': 'native',
        'formHtml': '<form></form>',
        'formUrl': 'https://forums.e-hentai.org/index.php?act=Login&CODE=00'
      };
    });
    expect((await check().run(CancelToken())).status, BrowserCheckStatus.ready);
    expect(inspected, 2);
    expect(AutomaticLoginCheck.activeView.value, isNull);
  });
}
