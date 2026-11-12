import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'comment_redirect_test.dart' show MockDatabase;
import 'dart:async';
import 'dart:io';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/core/network/native_auth_cookies.dart';

class DelayedAdapter implements HttpClientAdapter {
  final started = Completer<RequestOptions>();
  final response = Completer<ResponseBody>();
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) {
    if (!started.isCompleted) started.complete(options);
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

class AdapterCookieManager extends app.CookieManager {
  final HttpClientAdapter adapter;
  AdapterCookieManager(this.adapter)
      : super(clearBrowserAuthentication: () async {});
  @override
  void configureDio(Dio dio) {
    super.configureDio(dio);
    dio.httpClientAdapter = adapter;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
  const platform =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_platformutil');
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('oviewer-logout-');
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(platform, (_) async => '16.7');
  });
  tearDown(() async {
    NetworkProxy.beforeRequest = null;
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(platform, null);
    await directory.delete(recursive: true);
  });
  PersistCookieJar jar() => PersistCookieJar(
      ignoreExpires: true, storage: FileStorage('${directory.path}/.cookies/'));
  Future<app.CookieManager> manager({Future<void> Function()? clear}) async {
    final result =
        app.CookieManager(clearBrowserAuthentication: clear ?? () async {});
    await result.init();
    return result;
  }

  Future<void> login(app.CookieManager manager,
          [String member = 'account-a']) =>
      manager.saveLoginCookies(
          memberId: member, passHash: 'test-hash', igneous: 'test-igneous');

  Future<void> seedUploadPhpSession() async {
    final disk = jar();
    await disk.saveFromResponse(Uri.https('e-hentai.org', '/'), [
      Cookie('ipb_member_id', 'account-a')..domain = '.e-hentai.org',
      Cookie('ipb_pass_hash', 'test-hash')..domain = '.e-hentai.org',
    ]);
    await disk.saveFromResponse(Uri.https('upld.e-hentai.org', '/manage'), [
      Cookie('PHPSESSID', 'upload-session')..path = '/',
      Cookie('uconfig', 'keep-upload-preferences')..path = '/',
    ]);
    await disk.saveFromResponse(Uri.https('other.e-hentai.org', '/'), [
      Cookie('PHPSESSID', 'unrelated-session')..path = '/',
    ]);
  }

  for (final change in ['logout', 'account']) {
    test('$change clears only the upload PHP session, retaining unrelated PHP and preferences', () async {
      await seedUploadPhpSession();
      final session = await manager();
      expect(await session.getUploadCookieHeader(), contains('PHPSESSID=upload-session'));
      if (change == 'logout') { await session.clearCookies(); }
      else { await login(session, 'account-b'); }
      final upload = await jar().loadForRequest(Uri.https('upld.e-hentai.org', '/manage'));
      expect(upload.any((c) => c.name == 'PHPSESSID'), isFalse);
      expect(upload.singleWhere((c) => c.name == 'uconfig').value, 'keep-upload-preferences');
      final other = await jar().loadForRequest(Uri.https('other.e-hentai.org', '/'));
      expect(other.singleWhere((c) => c.name == 'PHPSESSID').value, 'unrelated-session');
    });
  }

  test('anonymous upload response cannot bootstrap a PHP upload session', () async {
    final adapter = DelayedAdapter();
    final session = AdapterCookieManager(adapter);
    await session.init();
    final dio = Dio(); session.configureDio(dio);
    final request = dio.get<String>('https://upld.e-hentai.org/manage');
    await adapter.started.future;
    adapter.response.complete(ResponseBody.fromString('login required', 200,
        headers: {'set-cookie': ['PHPSESSID=late-upload-session; Path=/']}));
    await request;
    final cookies = await jar().loadForRequest(Uri.https('upld.e-hentai.org', '/manage'));
    expect(cookies.any((c) => c.name == 'PHPSESSID'), isFalse);
    dio.close();
  });

  test('logout waits for native authentication invalidation and keeps retry marker on failure', () async {
    final session = await manager();
    await login(session);
    final entered = Completer<void>();
    final finish = Completer<void>();
    session.invalidateBackgroundAuthentication = () {
      entered.complete();
      return finish.future;
    };
    var completed = false;
    final logout = session.clearCookies().then((_) => completed = true);
    final assertion = expectLater(logout, throwsA(isA<LogoutCleanupException>()));
    await entered.future;
    expect(completed, isFalse);
    expect(await File('${directory.path}/.cookies/logout-pending').exists(), isTrue);
    finish.completeError(StateError('native unavailable'));
    await assertion;
    expect(await File('${directory.path}/.cookies/logout-pending').exists(), isTrue);
    session.invalidateBackgroundAuthentication = () async {};
    await session.clearCookies();
    expect(await File('${directory.path}/.cookies/logout-pending').exists(), isFalse);
    expect(await session.hasLoginCookies(), isFalse);
  });

  test('a new login cannot commit before old native authentication is invalidated', () async {
    final session = await manager();
    await login(session);
    final entered = Completer<void>();
    final finish = Completer<void>();
    session.invalidateBackgroundAuthentication = () {
      entered.complete();
      return finish.future;
    };
    var committed = false;
    final saving = session.saveLoginCookies(memberId: 'account-b', passHash: 'hash-b',
        onCommitted: () => committed = true);
    await entered.future;
    expect(committed, isFalse);
    expect(await session.getMemberId(), isNull);
    finish.complete();
    await saving;
    expect(committed, isTrue);
    expect(await session.getMemberId(), 'account-b');
  });

  test(
      'logout deletes all persisted authentication paths but preserves preferences and other hosts',
      () async {
    final disk = jar();
    for (final host in [
      'e-hentai.org',
      'forums.e-hentai.org',
      'exhentai.org',
      'extra.e-hentai.org'
    ]) {
      await disk.saveFromResponse(Uri.https(host, '/'), [
        for (final name in authenticationCookieNames)
          Cookie(name, 'test-login')..path = '/private',
        Cookie('ipb_member_id', 'test-member')
          ..domain = '.$host'
          ..path = '/',
        Cookie('ipb_pass_hash', 'test-hash')
          ..domain = '.$host'
          ..path = '/',
        Cookie('uconfig', 'keep-preferences')
          ..domain = '.$host'
          ..path = '/',
        Cookie('cf_clearance', 'keep-challenge')..path = '/',
      ]);
    }
    await disk.saveFromResponse(
        Uri.https('example.test', '/'), [Cookie('ipb_member_id', 'unrelated')]);
    final session = await manager();
    expect(await session.hasLoginCookies(), isTrue);
    await session.clearCookies();
    expect(await session.hasLoginCookies(), isFalse);
    final reopened = jar();
    for (final host in [
      'e-hentai.org',
      'forums.e-hentai.org',
      'exhentai.org',
      'extra.e-hentai.org'
    ]) {
      final saved = await reopened.loadForRequest(Uri.https(host, '/private'));
      expect(saved.where((c) => authenticationCookieNames.contains(c.name)),
          isEmpty);
      expect(
          saved
              .any((c) => c.name == 'uconfig' && c.value == 'keep-preferences'),
          isTrue);
      expect(
          saved.any(
              (c) => c.name == 'cf_clearance' && c.value == 'keep-challenge'),
          isTrue);
    }
    expect(
        (await reopened.loadForRequest(Uri.https('example.test', '/')))
            .single
            .value,
        'unrelated');
    expect(await File('${directory.path}/.cookies/logout-pending').exists(),
        isFalse);
  });

  test('a partial or empty cookie pair never counts as logged in', () async {
    await jar().saveFromResponse(Uri.https('e-hentai.org', '/'),
        [Cookie('ipb_member_id', '1'), Cookie('ipb_pass_hash', '')]);
    final session = await manager();
    expect(await session.hasLoginCookies(), isFalse);
    expect(await session.getMemberId(), isNull);
  });

  test(
      'failed browser cleanup survives process recreation and resumes before login detection',
      () async {
    final first =
        await manager(clear: () async => throw StateError('native store busy'));
    await login(first);
    await expectLater(
        first.clearCookies(), throwsA(isA<LogoutCleanupException>()));
    expect(await first.getMemberId(), isNull);
    expect(await File('${directory.path}/.cookies/logout-pending').exists(),
        isTrue);
    await expectLater(
        login(first, 'new-account'), throwsA(isA<LogoutCleanupException>()));
    var clears = 0;
    final recovered = await manager(clear: () async {
      clears++;
    });
    expect(await recovered.hasLoginCookies(), isFalse);
    expect(clears, 1);
    expect(await File('${directory.path}/.cookies/logout-pending').exists(),
        isFalse);
    await login(recovered, 'new-account');
    expect(await recovered.getMemberId(), 'new-account');
  });

  test(
      'concurrent logout calls share cleanup and prevent login until it finishes',
      () async {
    final cleaning = Completer<void>();
    var calls = 0;
    final session = await manager(clear: () {
      calls++;
      return cleaning.future;
    });
    await login(session);
    final first = session.clearCookies();
    final second = session.clearCookies();
    expect(identical(first, second), isTrue);
    await expectLater(login(session), throwsA(isA<LogoutCleanupException>()));
    cleaning.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
  });

  for (final post in [false, true]) {
    test(
        'proxy-waiting ${post ? "POST" : "GET"} cannot acquire the next account session',
        () async {
      final adapter = DelayedAdapter();
      final session = AdapterCookieManager(adapter);
      await session.init();
      await login(session);
      final dio = DioClient(session, MockDatabase());
      final ready = Completer<void>();
      NetworkProxy.beforeRequest = () => ready.future;
      final result = expectLater(
          post
              ? dio.post('https://e-hentai.org/news.php', data: 'old action')
              : dio.get('https://e-hentai.org/news.php'),
          throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      await session.clearCookies();
      await login(session, 'account-b');
      ready.complete();
      await result;
      expect(adapter.started.isCompleted, isFalse);
      expect(await session.getMemberId(), 'account-b');
    });
  }

  for (final status in [200, 403]) {
    test(
        'late $status Set-Cookie cannot restore the old account after logout/relogin',
        () async {
      final session = await manager();
      await login(session);
      final adapter = DelayedAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      session.configureDio(dio);
      final pending = dio.get('https://e-hentai.org/news.php');
      final response = status == 200
          ? pending.then<void>((_) {})
          : expectLater(pending, throwsA(isA<DioException>()));
      await adapter.started.future;
      await session.clearCookies();
      await login(session, 'account-b');
      adapter.response
          .complete(ResponseBody.fromString('old response', status, headers: {
        'set-cookie': [
          'ipb_member_id=account-a; Domain=.e-hentai.org; Path=/',
          'ipb_pass_hash=old-hash; Domain=.e-hentai.org; Path=/'
        ],
      }));
      await response;
      expect(await session.getMemberId(), 'account-b');
      expect(
          (await jar().loadForRequest(Uri.https('e-hentai.org', '/')))
              .firstWhere((c) => c.name == 'ipb_member_id')
              .value,
          'account-b');
      dio.close();
    });
  }

  test(
      'anonymous response cannot bootstrap credentials, including comma-joined Set-Cookie',
      () async {
    final session = await manager();
    await login(session);
    await session.clearCookies();
    final adapter = DelayedAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    session.configureDio(dio);
    final request = dio.get('https://e-hentai.org/news.php');
    final options = await adapter.started.future;
    expect('${options.headers['cookie']}', isNot(contains('test-hash')));
    adapter.response
        .complete(ResponseBody.fromString('anonymous', 200, headers: {
      'set-cookie': [
        'uconfig=keep; Path=/, ipb_member_id=old; Path=/',
        'ipb_pass_hash=old; Path=/'
      ],
    }));
    await request;
    expect(await session.hasLoginCookies(), isFalse);
    final persisted =
        await jar().loadForRequest(Uri.https('e-hentai.org', '/'));
    expect(persisted.where((c) => authenticationCookieNames.contains(c.name)),
        isEmpty);
    expect(persisted.any((c) => c.name == 'uconfig'), isTrue);
    dio.close();
  });

  test(
      'logout waits for in-flight browser sync then removes its copied credentials',
      () async {
    final firstCopy = Completer<void>();
    final copied = Completer<void>();
    var browserContainsLogin = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setCookie');
      if (!copied.isCompleted) {
        copied.complete();
        await firstCopy.future;
      }
      browserContainsLogin = true;
      return true;
    });
    final session = await manager(clear: () async {
      browserContainsLogin = false;
    });
    await login(session);
    final syncing = expectLater(
        session.syncToWebView(Uri.https('e-hentai.org', '/mytags')),
        throwsStateError);
    await copied.future;
    final clearing = session.clearCookies();
    firstCopy.complete();
    await syncing;
    await clearing;
    expect(browserContainsLogin, isFalse);
    expect(await session.hasLoginCookies(), isFalse);
  });

  for (final target in [TargetPlatform.iOS, TargetPlatform.android]) {
    test(
        '$target selectively clears native host/domain cookies and verifies deletion',
        () async {
      debugDefaultTargetPlatformOverride = target;
      final native = <Map<String, dynamic>>[
        for (final domain in [
          '.e-hentai.org',
          'forums.e-hentai.org',
          '.exhentai.org'
        ])
          for (final name in [
            ...authenticationCookieNames,
            'uconfig',
            'cf_clearance'
          ])
            {'domain': domain, 'path': '/', 'name': name, 'value': 'test'},
        {
          'domain': 'example.test',
          'path': '/',
          'name': 'ipb_member_id',
          'value': 'keep'
        },
        if (target == TargetPlatform.iOS)
          {
            'domain': '.e-hentai.org',
            'path': '/nonstandard',
            'name': 'sk',
            'value': 'test'
          },
      ];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'getAllCookies') return native.toList();
        final url = Uri.parse(args['url'] as String);
        if (call.method == 'getCookies') {
          return native
              .where((c) =>
                  (url.host == (c['domain'] as String).replaceFirst('.', '') ||
                      url.host.endsWith(c['domain'] as String)) &&
                  url.path.startsWith(c['path'] as String))
              .map((c) => {'name': c['name'], 'value': c['value']})
              .toList();
        }
        expect(call.method, 'deleteCookie');
        final domain = args['domain'] ?? url.host;
        native.removeWhere((c) =>
            c['name'] == args['name'] &&
            c['domain'] == domain &&
            c['path'] == args['path']);
        return true;
      });
      await NativeAuthCookies.clear();
      expect(
          native.where((c) =>
              isAccountCookieHost(c['domain']) &&
              authenticationCookieNames.contains(c['name'])),
          isEmpty);
      expect(native.where((c) => c['name'] == 'uconfig'), hasLength(3));
      expect(native.where((c) => c['name'] == 'cf_clearance'), hasLength(3));
      expect(native.any((c) => c['domain'] == 'example.test'), isTrue);
    });
  }
}
