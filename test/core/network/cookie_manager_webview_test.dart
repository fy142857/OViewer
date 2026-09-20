import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const cookieChannel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
  );
  const platformChannel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_platformutil',
  );
  final expiry = DateTime.utc(2037, 1, 2, 3, 4, 5);

  late Directory directory;
  late List<MethodCall> nativeCalls;

  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('oviewer-webview-cookies-');
    nativeCalls = [];
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      expect(call.method, 'getApplicationDocumentsDirectory');
      return directory.path;
    });
    messenger.setMockMethodCallHandler(platformChannel, (call) async {
      expect(call.method, 'getSystemVersion');
      return '12.0';
    });
    messenger.setMockMethodCallHandler(cookieChannel, (call) async {
      nativeCalls.add(call);
      expect(call.method, 'setCookie');
      return true;
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(cookieChannel, null);
    messenger.setMockMethodCallHandler(platformChannel, null);
    await directory.delete(recursive: true);
  });

  Future<app.CookieManager> managerWithBothSiteSessions() async {
    final jar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage('${directory.path}/.cookies/'),
    );
    for (final site in ['e-hentai.org', 'exhentai.org']) {
      final uri = Uri.https(site, '/mytags');
      await jar.saveFromResponse(uri, [
        Cookie('ipb_member_id', '$site-member')
          ..domain = '.$site'
          ..path = '/',
        Cookie('ipb_pass_hash', '$site-hash')
          ..domain = '.$site'
          ..path = '/',
        Cookie('igneous', '$site-igneous')
          ..domain = '.$site'
          ..path = '/',
        Cookie('sk', '$site-sk')
          ..domain = '.$site'
          ..path = '/mytags'
          ..expires = expiry
          ..secure = true
          ..httpOnly = true,
        Cookie('uconfig', 'app-preferences')
          ..domain = '.$site'
          ..path = '/',
      ]);
    }
    final manager = app.CookieManager();
    await manager.init();
    return manager;
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    group(platform.name, () {
      for (final site in ['e-hentai.org', 'exhentai.org']) {
        test('copies only $site authentication without overwriting preferences',
            () async {
          debugDefaultTargetPlatformOverride = platform;
          final manager = await managerWithBothSiteSessions();
          final uri = Uri.https(site, '/mytags');

          await manager.syncToWebView(uri);

          final cookies = {
            for (final call in nativeCalls)
              call.arguments['name'] as String:
                  Map<String, dynamic>.from(call.arguments as Map),
          };
          expect(
              cookies.keys,
              unorderedEquals([
                'ipb_member_id',
                'ipb_pass_hash',
                'sk',
                if (site == 'exhentai.org') 'igneous',
              ]));
          for (final cookie in cookies.values) {
            expect(cookie['url'], uri.toString());
            expect(cookie['domain'], '.$site');
            expect(cookie['value'], startsWith('$site-'));
          }
          expect(cookies['sk'], containsPair('path', '/mytags'));
          expect(
              cookies['sk'],
              containsPair(
                  'expiresDate', expiry.millisecondsSinceEpoch.toString()));
          expect(cookies['sk'], containsPair('isSecure', true));
          expect(cookies['sk'], containsPair('isHttpOnly', true));
          expect(cookies['ipb_member_id'], containsPair('path', '/'));
          expect(cookies['ipb_member_id'], containsPair('expiresDate', null));
          expect(cookies, isNot(contains('uconfig')));
        });
      }

      test('manual login cookies reach native WebView and writes are awaited',
          () async {
        debugDefaultTargetPlatformOverride = platform;
        final manager = app.CookieManager();
        await manager.init();
        await manager.saveLoginCookies(
          memberId: '123',
          passHash: 'manual-hash',
          igneous: 'manual-igneous',
        );
        final firstWrite = Completer<void>();
        final finishWrite = Completer<bool>();
        messenger.setMockMethodCallHandler(cookieChannel, (call) async {
          nativeCalls.add(call);
          if (!firstWrite.isCompleted) {
            firstWrite.complete();
            return finishWrite.future;
          }
          return true;
        });

        var finished = false;
        final syncing = manager
            .syncToWebView(Uri.parse('https://exhentai.org/uconfig.php'))
            .then((_) => finished = true);
        await firstWrite.future;
        expect(finished, isFalse);
        expect(nativeCalls, hasLength(1));

        finishWrite.complete(true);
        await syncing;
        expect(finished, isTrue);
        expect(
          {
            for (final call in nativeCalls)
              call.arguments['name']: call.arguments['value']
          },
          {
            'ipb_member_id': '123',
            'ipb_pass_hash': 'manual-hash',
            'igneous': 'manual-igneous',
          },
        );
      });
    });
  }

  test('rejects non-site and insecure destinations without native writes',
      () async {
    final manager = await managerWithBothSiteSessions();
    for (final url in [
      'http://exhentai.org/mytags',
      'https://example.org/mytags',
      'https://exhentai.org.example.org/mytags',
    ]) {
      await expectLater(
          manager.syncToWebView(Uri.parse(url)), throwsArgumentError);
    }
    expect(nativeCalls, isEmpty);
  });

  test('an empty app session does not erase native WebView cookies', () async {
    final manager = app.CookieManager();
    await manager.init();

    await manager.syncToWebView(Uri.parse('https://exhentai.org/mytags'));

    expect(nativeCalls, isEmpty);
  });

  test('retained expired authentication becomes a native session cookie',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final uri = Uri.parse('https://exhentai.org/uconfig.php');
    final jar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage('${directory.path}/.cookies/'),
    );
    await jar.saveFromResponse(uri, [
      Cookie('ipb_pass_hash', 'retained-hash')
        ..domain = '.exhentai.org'
        ..path = '/'
        ..expires = DateTime.utc(2000)
        ..secure = true
        ..httpOnly = true,
      Cookie('uconfig', 'app-preferences')
        ..domain = '.exhentai.org'
        ..path = '/',
    ]);
    // Model an on-disk cookie that expired after a previous app session.
    // PersistCookieJar filters already-expired cookies on save, even when
    // ignoreExpires lets the live jar retain them, so persist this fixture
    // directly using the jar's own serializable cookie objects.
    await jar.storage.write('.domains', jsonEncode(jar.domainCookies));
    final manager = app.CookieManager();
    await manager.init();

    await manager.syncToWebView(uri);

    expect(nativeCalls, hasLength(1));
    expect(nativeCalls.single.arguments, containsPair('name', 'ipb_pass_hash'));
    expect(
        nativeCalls.single.arguments, containsPair('value', 'retained-hash'));
    expect(nativeCalls.single.arguments, containsPair('expiresDate', null));
    expect(nativeCalls.single.arguments, containsPair('isSecure', true));
    expect(nativeCalls.single.arguments, containsPair('isHttpOnly', true));
  });
}
