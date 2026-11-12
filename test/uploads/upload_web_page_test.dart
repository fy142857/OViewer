import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/core/network/network_preparation.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/features/uploads/presentation/upload_web_page.dart';

class MockCookies extends Mock implements app.CookieManager {}

class MockAuth extends Mock implements AuthBloc {}

class MockWebController extends Mock implements InAppWebViewController {
  final String? apiUid;
  final scripts = <String>[];
  MockWebController({this.apiUid});
  @override
  Future<dynamic> evaluateJavascript(
      {required String source, ContentWorld? contentWorld}) async {
    scripts.add(source);
    return apiUid;
  }
}

class TestProxy extends UploadWebProxy {
  final events = <String>[];
  bool available = true;
  bool valid = true;
  bool failClose = false;
  Completer<bool>? pending;
  @override
  Future<bool> begin(String id, String? proxy) async {
    events.add('begin:${proxy ?? 'system'}');
    return pending == null ? available : await pending!.future;
  }

  @override
  Future<bool> check(String id) async => valid;
  @override
  Future<void> close(String id) async {
    events.add('close');
    if (failClose) throw PlatformException(code: 'proxy_cleanup');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const cookieChannel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
  const platformUtil =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_platformutil');
  final entry =
      Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=12345');
  late MockCookies cookies;
  late MockAuth auth;
  late AuthState authState;
  late StreamController<AuthState> authEvents;
  late TestProxy proxy;
  late int revision;
  late int before;
  late int after;
  late List<Map> views;
  late List<MethodCall> webCalls;
  late List<MethodCall> cookieCalls;
  late List<Map<String, Object>> browserCookies;
  late bool canGoBack;
  Completer<bool>? historyCheck;
  late GlobalKey<NavigatorState> navigator;

  setUpAll(() {
    registerFallbackValue(entry);
  });
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    NetworkProxy.setProxy(null);
    NetworkProxy.beforeRequest = null;
    cookies = MockCookies();
    auth = MockAuth();
    proxy = TestProxy();
    authState = const AuthState(status: AuthStatus.authenticated);
    authEvents = StreamController<AuthState>.broadcast(sync: true);
    revision = 0;
    before = 0;
    after = 0;
    views = [];
    webCalls = [];
    cookieCalls = [];
    canGoBack = false;
    historyCheck = null;
    navigator = GlobalKey<NavigatorState>();
    browserCookies = [
      {
        'name': 'ipb_member_id',
        'value': '101',
        'domain': '.e-hentai.org',
        'path': '/'
      },
      {
        'name': 'ipb_pass_hash',
        'value': 'fixture',
        'domain': '.e-hentai.org',
        'path': '/'
      }
    ];
    when(() => auth.state).thenAnswer((_) => authState);
    when(() => auth.stream).thenAnswer((_) => authEvents.stream);
    when(() => cookies.sessionRevision).thenAnswer((_) => revision);
    when(() => cookies.getUploadCookieHeader())
        .thenAnswer((_) async => 'ipb_member_id=101; ipb_pass_hash=fixture');
    when(() => cookies.syncToWebView(any())).thenAnswer((_) async {});
    messenger.setMockMethodCallHandler(cookieChannel, (call) async {
      cookieCalls.add(call);
      if (call.method == 'deleteCookie' &&
          (call.arguments as Map)['name'] == 'PHPSESSID') {
        browserCookies.removeWhere((cookie) => cookie['name'] == 'PHPSESSID');
      }
      return {'getCookies', 'getAllCookies'}.contains(call.method)
          ? browserCookies
          : true;
    });
    messenger.setMockMethodCallHandler(platformUtil, (call) async => '12.0');
    messenger.setMockMethodCallHandler(SystemChannels.platform_views,
        (call) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        final params = const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(args['params'] as Uint8List)) as Map;
        views.add({'id': args['id'], ...params});
        messenger.setMockMethodCallHandler(
            MethodChannel(
                'com.pichillilorenzo/flutter_inappwebview_${args['id']}'),
            (call) async {
          webCalls.add(call);
          if (call.method == 'canGoBack') {
            return historyCheck == null
                ? canGoBack
                : await historyCheck!.future;
          }
          return null;
        });
        return defaultTargetPlatform == TargetPlatform.android
            ? args['id']
            : null;
      }
      if (call.method == 'resize') {
        final args = call.arguments as Map;
        return {'width': args['width'], 'height': args['height']};
      }
      return null;
    });
  });
  tearDown(() async {
    for (final view in views) {
      messenger.setMockMethodCallHandler(
          MethodChannel(
              'com.pichillilorenzo/flutter_inappwebview_${view['id']}'),
          null);
    }
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMethodCallHandler(cookieChannel, null);
    messenger.setMockMethodCallHandler(platformUtil, null);
    await authEvents.close();
    NetworkProxy.beforeRequest = null;
    NetworkProxy.setProxy(null);
    debugDefaultTargetPlatformOverride = null;
  });

  Widget host(
          {Uri? url,
          Future<void> Function()? beforeOpen,
          Future<void> Function()? afterClose,
          UploadWebProxy? route,
          NetworkPreparation? network}) =>
      MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => UploadWebPage(
                                    url: url ?? entry,
                                    cookies: cookies,
                                    auth: auth,
                                    proxy: route ?? proxy,
                                    network: network,
                                    beforeOpen: beforeOpen ??
                                        () async {
                                          before++;
                                        },
                                    afterClose: afterClose ??
                                        () async {
                                          after++;
                                        },
                                  ))),
                      child: const Text('Open browser')))));

  Future<void> open(WidgetTester tester, {Widget? widget}) async {
    await tester.pumpWidget(widget ?? host());
    await tester.tap(find.text('Open browser'));
    await tester.pumpAndSettle();
  }

  Future<void> clear(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }

  InAppWebView web(WidgetTester tester) =>
      tester.widget<InAppWebView>(find.byType(InAppWebView).last);
  Future<void> dirty(WidgetTester tester, {String kind = 'dirty'}) async {
    final script = web(tester).initialUserScripts!.single.source;
    final nonce = RegExp(r'nonce:("[^"]+")').firstMatch(script)![1]!;
    final complete = Completer<void>();
    await messenger.handlePlatformMessage(
        'com.pichillilorenzo/flutter_inappwebview_${views.last['id']}',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('onCallJsHandler', {
          'handlerName': 'oviewerUploadState',
          'args': jsonEncode([
            {'nonce': jsonDecode(nonce), 'kind': kind, 'href': entry.toString()}
          ]),
        })),
        (_) => complete.complete());
    await complete.future;
    await tester.pump();
  }

  test('entry policy cannot auto-load mutation links or lookalike hosts', () {
    for (final path in [
      '/manage',
      '/managefolders',
      '/managegallery?act=new',
      '/managegallery?ulgid=12345'
    ]) {
      expect(
          UploadWebPolicy.safeEntry(
              Uri.parse('https://upld.e-hentai.org$path')),
          isTrue);
    }
    for (final url in [
      'https://upld.e-hentai.org/managegallery?ulgid=12345&act=delete',
      'https://upld.e-hentai.org/managegallery?ulgid=12345&act=new',
      'https://upld.e-hentai.org/managegallery?act=new&act=delete',
      'https://upld.e-hentai.org/managegallery?ulgid=12345&act%00=delete',
      'https://upld.e-hentai.org/managefolders?act=delete',
      'https://upld.e-hentai.org.evil.test/manage',
      'https://user@upld.e-hentai.org/manage',
      'http://upld.e-hentai.org/manage',
      'https://upld.e-hentai.org:444/manage',
    ]) {
      expect(UploadWebPolicy.safeEntry(Uri.parse(url)), isFalse, reason: url);
    }
  });

  testWidgets('waits for handoff and cookie sync before creating a browser',
      (tester) async {
    final handoff = Completer<void>();
    final sync = Completer<void>();
    when(() => cookies.syncToWebView(entry)).thenAnswer((_) => sync.future);
    await tester.pumpWidget(host(beforeOpen: () {
      before++;
      return handoff.future;
    }));
    await tester.tap(find.text('Open browser'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(before, 1);
    expect(views, isEmpty);
    handoff.complete();
    await tester.pump();
    expect(views, isEmpty);
    sync.complete();
    await tester.pumpAndSettle();
    expect(views, hasLength(1));
    expect(views.single['initialUrlRequest']['url'], entry.toString());
    verify(() => cookies.syncToWebView(entry)).called(1);
    expect(web(tester).onReceivedServerTrustAuthRequest, isNull);
    expect(
        web(tester)
            .initialOptions!
            .crossPlatform
            .allowUniversalAccessFromFileURLs,
        isFalse);
    await clear(tester);
    expect(after, 1);
  });

  testWidgets(
      'new browser removes only the upload PHP session before sync once',
      (tester) async {
    browserCookies.add({'name': 'PHPSESSID', 'value': 'old-account-session'});
    var syncs = 0;
    when(() => cookies.syncToWebView(any())).thenAnswer((_) async {
      if (syncs++ == 0) {
        expect(browserCookies.where((c) => c['name'] == 'PHPSESSID'), isEmpty);
        expect(views, isEmpty);
      }
    });
    await open(tester);
    final deletions =
        cookieCalls.where((c) => c.method == 'deleteCookie').toList();
    expect(deletions, hasLength(3));
    for (final call in deletions) {
      final args = call.arguments as Map;
      expect(args['name'], 'PHPSESSID');
      expect(args['url'], 'https://upld.e-hentai.org/');
      expect(args['path'], '/');
      expect(args['domain'],
          anyOf(isNull, 'upld.e-hentai.org', '.upld.e-hentai.org'));
    }
    browserCookies.add({'name': 'PHPSESSID', 'value': 'current-page-session'});
    expect(
        await web(tester).shouldOverrideUrlLoading!(
            MockWebController(),
            NavigationAction(
                request: URLRequest(
                    url: Uri.parse('https://upld.e-hentai.org/managefolders')),
                isForMainFrame: true)),
        NavigationActionPolicy.ALLOW);
    expect(cookieCalls.where((c) => c.method == 'deleteCookie'), hasLength(3));
    expect(browserCookies.last['value'], 'current-page-session');
    await clear(tester);
  });

  testWidgets('uncleared upload PHP session blocks the first request',
      (tester) async {
    browserCookies.add({'name': 'PHPSESSID', 'value': 'old-account-session'});
    messenger.setMockMethodCallHandler(cookieChannel,
        (call) async => call.method == 'getCookies' ? browserCookies : false);
    await open(tester);
    expect(views, isEmpty);
    verifyNever(() => cookies.syncToWebView(any()));
    await clear(tester);
  });

  testWidgets(
      'iOS clears exact upload PHP scopes and ignores inapplicable auth cookies',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    browserCookies.addAll([
      {
        'name': 'PHPSESSID',
        'value': 'old-upload',
        'domain': 'upld.e-hentai.org',
        'path': '/'
      },
      {
        'name': 'PHPSESSID',
        'value': 'unrelated-site',
        'domain': 'example.org',
        'path': '/'
      },
      {
        'name': 'ipb_member_id',
        'value': 'other-path',
        'domain': 'upld.e-hentai.org',
        'path': '/other'
      },
      {
        'name': 'ipb_member_id',
        'value': 'host-only-parent',
        'domain': 'e-hentai.org',
        'path': '/'
      },
      {
        'name': 'ipb_member_id',
        'value': 'expired-account',
        'domain': '.e-hentai.org',
        'path': '/',
        'expiresDate': 1
      },
    ]);
    messenger.setMockMethodCallHandler(cookieChannel, (call) async {
      cookieCalls.add(call);
      if (call.method == 'getAllCookies') return browserCookies;
      if (call.method == 'deleteCookie') {
        final args = call.arguments as Map;
        browserCookies.removeWhere((cookie) =>
            cookie['name'] == args['name'] &&
            cookie['domain'] == args['domain'] &&
            cookie['path'] == args['path']);
      }
      return true;
    });
    await open(tester);
    expect(views, hasLength(1));
    final deletes =
        cookieCalls.where((call) => call.method == 'deleteCookie').toList();
    expect(deletes, hasLength(1));
    expect((deletes.single.arguments as Map)['domain'], 'upld.e-hentai.org');
    expect(browserCookies.any((cookie) => cookie['value'] == 'old-upload'),
        isFalse);
    expect(browserCookies.any((cookie) => cookie['value'] == 'unrelated-site'),
        isTrue);
    expect(cookieCalls.where((call) => call.method == 'getCookies'), isEmpty);
    await clear(tester);
  });

  testWidgets(
      'closing waits for pending PHP cleanup before releasing the route',
      (tester) async {
    final deletion = Completer<bool>();
    var requested = false;
    messenger.setMockMethodCallHandler(cookieChannel, (call) async {
      if (call.method == 'deleteCookie' && !requested) {
        requested = true;
        return deletion.future;
      }
      return call.method == 'getCookies' ? browserCookies : true;
    });
    await tester.pumpWidget(host());
    await tester.tap(find.text('Open browser'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(requested, isTrue);
    await tester.tap(find.byTooltip('Close official page'));
    await tester.pump();
    expect(proxy.events.where((e) => e == 'close'), isEmpty);
    expect(after, 0);
    deletion.complete(true);
    await tester.pumpAndSettle();
    expect(proxy.events.where((e) => e == 'close'), isNotEmpty);
    expect(after, 1);
    expect(views, isEmpty);
    verifyNever(() => cookies.syncToWebView(any()));
    await clear(tester);
  });

  testWidgets('public page account mismatch closes the old browser',
      (tester) async {
    await open(tester);
    final controller = MockWebController(apiUid: '102');
    web(tester).onLoadStop!(controller, entry);
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.textContaining('old page was closed'), findsOneWidget);
    expect(controller.scripts.single, contains('window.apiuid'));
    expect(controller.scripts.single, isNot(contains('apikey')));
    expect(controller.scripts.single, isNot(contains('querySelector')));
    await clear(tester);
  });

  testWidgets('matching or absent public page account permits normal pages',
      (tester) async {
    await open(tester);
    web(tester).onLoadStop!(MockWebController(apiUid: '101'), entry);
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsOneWidget);
    web(tester).onLoadStop!(MockWebController(), entry);
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsOneWidget);
    await clear(tester);
  });

  testWidgets(
      'auth change during handoff never creates the old account browser and releases handoff',
      (tester) async {
    final handoff = Completer<void>();
    await tester.pumpWidget(host(beforeOpen: () {
      before++;
      return handoff.future;
    }));
    await tester.tap(find.text('Open browser'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    revision++;
    authState = const AuthState(
        status: AuthStatus.unauthenticated, sessionGeneration: 1);
    authEvents.add(authState);
    handoff.complete();
    await tester.pumpAndSettle();
    expect(views, isEmpty);
    expect(after, 1);
    expect(find.textContaining('old page was closed'), findsOneWidget);
    await clear(tester);
    expect(after, 1);
  });

  testWidgets('iOS app proxy requires explicit system-network choice',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    NetworkProxy.setProxy('http://127.0.0.1:7890');
    await open(tester, widget: host(route: UploadWebProxy()));
    expect(views, isEmpty);
    expect(before, 0);
    await tester.tap(find.text('Load using system network / VPN'));
    await tester.pumpAndSettle();
    expect(views, hasLength(1));
    expect(before, 1);
    expect(NetworkProxy.currentProxy, 'http://127.0.0.1:7890');
    await clear(tester);
  });

  testWidgets(
      'main-frame external navigation and history POST replay are blocked',
      (tester) async {
    await open(tester);
    final view = web(tester);
    final controller = MockWebController();
    for (final url in [
      'https://evil.test/',
      'file:///private/test',
      'javascript:alert(1)'
    ]) {
      final result = await view.shouldOverrideUrlLoading!(
          controller,
          NavigationAction(
              request: URLRequest(url: Uri.parse(url)), isForMainFrame: true));
      expect(result, NavigationActionPolicy.CANCEL);
    }
    expect(
        await view.shouldOverrideUrlLoading!(
            controller,
            NavigationAction(
                request: URLRequest(url: entry, method: 'POST'),
                isForMainFrame: true,
                iosWKNavigationType: IOSWKNavigationType.BACK_FORWARD)),
        NavigationActionPolicy.CANCEL);
    expect(
        await view.shouldOverrideUrlLoading!(
            controller,
            NavigationAction(
                request: URLRequest(url: entry, method: 'POST'),
                isForMainFrame: true,
                iosWKNavigationType: IOSWKNavigationType.FORM_SUBMITTED)),
        NavigationActionPolicy.ALLOW);
    expect(await view.androidOnFormResubmission!(controller, entry),
        FormResubmissionAction.DONT_RESEND);
    await clear(tester);
  });

  testWidgets('JS confirmation waits for a user and rejects a changed session',
      (tester) async {
    await open(tester);
    final view = web(tester);
    var resolved = false;
    final response = view.onJsConfirm!(MockWebController(),
            JsConfirmRequest(url: entry, message: 'Publish gallery?'))
        .then((value) {
      resolved = true;
      return value;
    });
    await tester.pumpAndSettle();
    expect(resolved, isFalse);
    expect(find.text('Publish gallery?'), findsOneWidget);
    revision++;
    authState = const AuthState(
        status: AuthStatus.unauthenticated, sessionGeneration: 1);
    authEvents.add(authState);
    await tester.pumpAndSettle();
    expect((await response)!.action!.toValue(),
        JsConfirmResponseAction.CANCEL.toValue());
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.text('Publish gallery?'), findsNothing);
    await clear(tester);
  });

  testWidgets(
      'back uses browser history before exiting and close refreshes once',
      (tester) async {
    await open(tester);
    canGoBack = true;
    final handled = navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    await handled;
    expect(webCalls.where((c) => c.method == 'goBack'), hasLength(1));
    expect(after, 0);
    canGoBack = false;
    await tester.tap(find.byTooltip('Close official page'));
    await tester.pumpAndSettle();
    expect(find.text('Open browser'), findsOneWidget);
    expect(after, 1);
    expect(
        webCalls
            .where((c) => c.method == 'loadUrl')
            .last
            .arguments['urlRequest']['url'],
        'about:blank');
    expect(proxy.events.last, 'close');
    await clear(tester);
    expect(after, 1);
  });

  testWidgets('dirty form requires a leave decision and does not auto-publish',
      (tester) async {
    await open(tester);
    await dirty(tester);
    await tester.tap(find.byTooltip('Close official page'));
    await tester.pumpAndSettle();
    expect(find.text('Leave the official page?'), findsOneWidget);
    expect(after, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(after, 0);
    await tester.tap(find.byTooltip('Close official page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(after, 1);
    expect(webCalls.where((c) => c.method == 'evaluateJavascript'), isEmpty);
    await clear(tester);
  });

  testWidgets(
      'network policy replacement destroys old page and requires explicit reload',
      (tester) async {
    final network = NetworkPreparation(
        manualProxy: null, autoProxy: false, apply: NetworkProxy.setProxy);
    await network.start();
    await open(tester, widget: host(network: network));
    expect(views, hasLength(1));
    await network.configure(
        manualProxy: 'http://127.0.0.1:7890', autoProxy: false);
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsNothing);
    expect(views, hasLength(1));
    expect(find.textContaining('Network settings changed'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(views, hasLength(2));
    expect(before, 1);
    expect(proxy.events, contains('begin:http://127.0.0.1:7890'));
    await clear(tester);
    network.dispose();
  });

  testWidgets(
      'popup targets stay inside the guarded browser and close back to the parent',
      (tester) async {
    await open(tester);
    final root = web(tester);
    final controller = MockWebController();
    expect(
        await root.onCreateWindow!(
            controller,
            CreateWindowAction(
                windowId: 81,
                request: URLRequest(url: Uri.parse('https://evil.test')),
                isForMainFrame: true)),
        isFalse);
    expect(
        await root.onCreateWindow!(
            controller,
            CreateWindowAction(
                windowId: 82,
                request: URLRequest(url: null),
                isForMainFrame: true)),
        isTrue);
    await tester.pumpAndSettle();
    expect(views, hasLength(2));
    expect(views.last['windowId'], 82);
    expect(web(tester).initialUrlRequest, isNull);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsOneWidget);
    expect(after, 0);
    await clear(tester);
  });

  testWidgets('browser identity mismatch destroys the account-scoped page',
      (tester) async {
    await open(tester);
    browserCookies = [
      {'name': 'ipb_member_id', 'value': 'other'},
      {'name': 'ipb_pass_hash', 'value': 'other'}
    ];
    web(tester).onLoadStop!(MockWebController(), entry);
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.textContaining('old page was closed'), findsOneWidget);
    await clear(tester);
  });

  testWidgets(
      'conflicting applicable cookie values invalidate even when one matches',
      (tester) async {
    await open(tester);
    browserCookies.add({'name': 'ipb_member_id', 'value': 'another-account'});
    web(tester).onLoadStop!(MockWebController(), entry);
    await tester.pumpAndSettle();
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.textContaining('old page was closed'), findsOneWidget);
    await clear(tester);
  });

  testWidgets(
      'conflicting browser identity is rejected before the first page request',
      (tester) async {
    browserCookies.add({'name': 'ipb_member_id', 'value': 'another-account'});
    await open(tester);
    expect(views, isEmpty);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.textContaining('old page was closed'), findsOneWidget);
    expect(after, 1);
    await clear(tester);
  });

  testWidgets(
      'dirty history and popup back need a decision before leaving their frame',
      (tester) async {
    await open(tester);
    await dirty(tester);
    canGoBack = true;
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Return to the previous page?'), findsOneWidget);
    expect(webCalls.where((call) => call.method == 'goBack'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    canGoBack = false;
    await web(tester).onCreateWindow!(
        MockWebController(),
        CreateWindowAction(
            windowId: 99,
            request: URLRequest(url: null),
            isForMainFrame: true));
    await tester.pumpAndSettle();
    await dirty(tester);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Close this website window?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(web(tester).windowId, 99);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(web(tester).windowId, isNull);
    expect(after, 0);
    await clear(tester);
  });

  testWidgets(
      'delayed history answer cannot navigate after session destruction',
      (tester) async {
    await open(tester);
    historyCheck = Completer<bool>();
    final back = navigator.currentState!.maybePop();
    await tester.pump();
    revision++;
    authState = const AuthState(
        status: AuthStatus.unauthenticated, sessionGeneration: 1);
    authEvents.add(authState);
    await tester.pumpAndSettle();
    historyCheck!.complete(true);
    await tester.pumpAndSettle();
    await back;
    expect(webCalls.where((call) => call.method == 'goBack'), isEmpty);
    expect(find.byType(InAppWebView), findsNothing);
    await clear(tester);
  });

  testWidgets(
      'cancelled JS submit confirmation does not permanently block official popups',
      (tester) async {
    await open(tester);
    await dirty(tester, kind: 'submit');
    final view = web(tester);
    final confirmation = view.onJsConfirm!(MockWebController(),
        JsConfirmRequest(url: entry, message: 'Continue?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((await confirmation)!.action!.toValue(),
        JsConfirmResponseAction.CANCEL.toValue());
    expect(
        await view.onCreateWindow!(
            MockWebController(),
            CreateWindowAction(
                windowId: 100,
                request: URLRequest(
                    url: Uri.parse(
                        'https://e-hentai.org/gallerytorrents.php?gid=12345')),
                isForMainFrame: true)),
        isTrue);
    await tester.pumpAndSettle();
    expect(views, hasLength(2));
    await clear(tester);
  });

  testWidgets(
      'ordinary manager exit leaves reader cache alone but settings visit clears it once',
      (tester) async {
    var beforeGeneration = ReaderIndexCache.shared.generation;
    await open(tester);
    await tester.tap(find.byTooltip('Close official page'));
    await tester.pumpAndSettle();
    expect(ReaderIndexCache.shared.generation, beforeGeneration);
    await clear(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    beforeGeneration = ReaderIndexCache.shared.generation;
    await open(tester);
    web(tester).onLoadStop!(
        MockWebController(), Uri.parse('https://e-hentai.org/uconfig.php'));
    await tester.pumpAndSettle();
    expect(ReaderIndexCache.shared.generation, beforeGeneration);
    await tester.tap(find.byTooltip('Close official page'));
    await tester.pumpAndSettle();
    expect(ReaderIndexCache.shared.generation, beforeGeneration + 1);
    await clear(tester);
    expect(ReaderIndexCache.shared.generation, beforeGeneration + 1);
  });

  testWidgets(
      'a new official destination is synchronized before navigation and conflicting cookies stop it',
      (tester) async {
    await open(tester);
    final destination =
        Uri.parse('https://forums.e-hentai.org/index.php?showtopic=19797');
    final sync = Completer<void>();
    when(() => cookies.syncToWebView(destination))
        .thenAnswer((_) => sync.future);
    var settled = false;
    final navigation = web(tester)
        .shouldOverrideUrlLoading!(
            MockWebController(),
            NavigationAction(
                request: URLRequest(url: destination), isForMainFrame: true))
        .then((value) {
      settled = true;
      return value;
    });
    await tester.pump();
    expect(settled, isFalse);
    browserCookies.add({'name': 'ipb_member_id', 'value': 'old-forum-account'});
    sync.complete();
    await tester.pumpAndSettle();
    expect(await navigation, NavigationActionPolicy.CANCEL);
    expect(find.byType(InAppWebView), findsNothing);
    await clear(tester);
  });

  testWidgets(
      'Android POST cannot bypass an unprepared cross-domain navigation',
      (tester) async {
    await open(tester);
    final destination =
        Uri.parse('https://e-hentai.org/gallerytorrents.php?gid=12345');
    final view = web(tester);
    WebResourceRequest request() => WebResourceRequest(
        url: destination,
        method: 'POST',
        hasGesture: true,
        isForMainFrame: true,
        isRedirect: false);
    final blocked = await view.androidShouldInterceptRequest!(
        MockWebController(), request());
    expect(blocked?.statusCode, 403);
    expect(
        await view.shouldOverrideUrlLoading!(
            MockWebController(),
            NavigationAction(
                request: URLRequest(url: destination), isForMainFrame: true)),
        NavigationActionPolicy.ALLOW);
    expect(
        await view.androidShouldInterceptRequest!(
            MockWebController(), request()),
        isNull);
    await clear(tester);
  });
}
