import 'package:oviewer/blocs/auth/auth_event.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/repositories/auth_repository.dart';
import 'package:oviewer/screens/login/login_screen.dart';
import 'package:oviewer/widgets/login_webview.dart';
import 'package:oviewer/core/network/account_login_client.dart';
import 'package:oviewer/core/network/automatic_login_check.dart';

class MockSettingsBloc extends Mock implements SettingsBloc {}

class MockAuthBloc extends Mock implements AuthBloc {}

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(CheckLoginStatus()));
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  const cookieChannel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
  const platformChannel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_platformutil');
  final loginUrl = Uri.parse('https://forums.e-hentai.org/index.php?act=Login');
  final completeCookies = [
    {'name': 'ipb_member_id', 'value': '123'},
    {'name': 'ipb_pass_hash', 'value': 'test-hash'},
    {'name': 'cf_clearance', 'value': 'test-clearance'},
  ];
  late MockSettingsBloc settings;
  late List<Map> views;
  late List<Map<String, String>> submissions;
  late List<Uri> cookieReads;
  late Future<List<Map<String, String>>> Function(Uri) readCookies;

  setUp(() {
    views = [];
    submissions = [];
    cookieReads = [];
    readCookies = (_) async => [];
    settings = MockSettingsBloc();
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    messenger.setMockMethodCallHandler(platformChannel, (_) async => '16.7.16');
    messenger.setMockMethodCallHandler(cookieChannel, (call) async {
      expect(
          call.method, 'getCookies'); // Never clear a challenge/session cookie.
      final uri = Uri.parse((call.arguments as Map)['url'] as String);
      cookieReads.add(uri);
      return readCookies(uri);
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views,
        (call) async {
      final args = call.arguments is Map ? call.arguments as Map : null;
      if (call.method == 'create') {
        views.add(Map.from(args!));
        return debugDefaultTargetPlatformOverride == TargetPlatform.android
            ? args['id'] as int
            : null;
      }
      if (call.method == 'resize') {
        return {'width': args!['width'], 'height': args['height']};
      }
      return null;
    });
  });

  tearDown(() async {
    AutomaticLoginCheck.activeView.value = null;
    for (final view in views) {
      messenger.setMockMethodCallHandler(
          MethodChannel('oviewer/login-webview/${view['id']}'), null);
    }
    messenger.setMockMethodCallHandler(cookieChannel, null);
    messenger.setMockMethodCallHandler(platformChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    debugDefaultTargetPlatformOverride = null;
    await GetIt.I.reset();
  });

  Widget app(Widget child) => BlocProvider<SettingsBloc>.value(
        value: settings,
        child: MaterialApp(home: Scaffold(body: child)),
      );
  Widget page({bool enabled = true, bool publicOnly = false}) =>
      app(LoginWebView(
        url: loginUrl,
        enabled: enabled,
        publicOnly: publicOnly,
        onLogin: submissions.add,
      ));

  test(
      'public preparation allows checks but never browser login submission or external navigation',
      () {
    expect(LoginWebView.allowsPublicNavigation(loginUrl, 'GET'), isTrue);
    expect(
        LoginWebView.allowsPublicNavigation(
            Uri.parse('https://forums.e-hentai.org/cdn-cgi/check'), 'POST'),
        isTrue);
    for (final url in [
      'http://forums.e-hentai.org/',
      'https://example.com/',
      'https://user@forums.e-hentai.org/',
      'https://forums.e-hentai.org:444/'
    ]) {
      expect(
          LoginWebView.allowsPublicNavigation(Uri.parse(url), 'GET'), isFalse);
    }
    expect(
        LoginWebView.allowsPublicNavigation(
            Uri.parse(
                'https://forums.e-hentai.org/index.php?act=Login&CODE=01'),
            'POST'),
        isFalse);
  });

  testWidgets(
      'public browser cannot submit existing authentication even when enabled',
      (tester) async {
    await tester.pumpWidget(page(publicOnly: true));
    await tester.pumpAndSettle();
    readCookies = (_) async => completeCookies;
    final view = tester.widget<InAppWebView>(find.byType(InAppWebView));
    await tester.runAsync(() async {
      view.onLoadStop!(InAppWebViewController(0, view), loginUrl);
      await Future<void>.delayed(Duration.zero);
    });
    expect(submissions, isEmpty);
    expect(cookieReads, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  Future<MockAuthBloc> accountScreen(WidgetTester tester,
      {AuthState state =
          const AuthState(status: AuthStatus.unauthenticated)}) async {
    final auth = MockAuthBloc();
    final repository = MockAuthRepository();
    when(() => auth.state).thenReturn(state);
    when(() => auth.stream).thenAnswer((_) => const Stream.empty());
    when(() => repository.loginPageUrl).thenReturn(loginUrl.toString());
    GetIt.I.registerSingleton<AuthRepository>(repository);
    await tester.pumpWidget(app(
        BlocProvider<AuthBloc>.value(value: auth, child: const LoginScreen())));
    await tester.pumpAndSettle();
    return auth;
  }

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
        'verification stays in account tab and keeps credentials: $target',
        (tester) async {
      await accountScreen(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Username'), 'test-user');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'test-password');
      AutomaticLoginCheck.activeView.value = 17;
      await tester.pumpAndSettle();
      expect(find.byType(LoginWebView), findsOneWidget);
      expect(tester.widget<LoginWebView>(find.byType(LoginWebView)).publicOnly,
          isTrue);
      expect(tester.widget<LoginWebView>(find.byType(LoginWebView)).enabled,
          isFalse);
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.controller!.index, 0);
      expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'Username'))
              .controller!
              .text,
          'test-user');
      expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'Password'))
              .controller!
              .text,
          'test-password');
      AutomaticLoginCheck.activeView.value = null;
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Completing website verification. If prompted, complete the check below; no need to re-enter your credentials.'),
          findsNothing);
    }, variant: TargetPlatformVariant.only(target));
  }

  testWidgets(
      'account is first, validates fields, submits once and clears password on switch',
      (tester) async {
    final auth = await accountScreen(tester);
    expect(tester.widget<Tab>(find.byType(Tab).first).text, 'Account');
    expect(find.byType(LoginWebView), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Login'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your username and password'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Username'), ' test ');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), ' pass ');
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Password'))
            .obscureText,
        isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Password'))
            .obscureText,
        isFalse);
    await tester.tap(find.widgetWithText(FilledButton, 'Login'));
    await tester.tap(find.widgetWithText(FilledButton, 'Login'));
    final request = verify(() => auth.add(captureAny())).captured.single
        as LoginWithAccount;
    expect(request.username, 'test');
    expect(request.password, ' pass ');
    await tester.tap(find.text('Manual Cookie'));
    await tester.pumpAndSettle();
    expect(request.cancelToken!.isCancelled, isTrue);
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Password'))
            .controller!
            .text,
        isEmpty);
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Username'))
            .controller!
            .text,
        ' test ');
  });

  testWidgets(
      'challenge uses requested Chinese text and opens WebView only on tap',
      (tester) async {
    when(() => settings.state).thenReturn(const SettingsState(locale: 'zh'));
    await accountScreen(tester,
        state: const AuthState(
            status: AuthStatus.error,
            accountFailure: AccountLoginFailure.challenge));
    const message = '因网络原因触发安全验证，前往webview完成验证';
    expect(find.text(message), findsOneWidget);
    expect(find.byType(LoginWebView), findsNothing);
    await tester.tap(find.text(message));
    await tester.pumpAndSettle();
    expect(find.byType(LoginWebView), findsOneWidget);
    expect(
        tester.widget<LoginWebView>(find.byType(LoginWebView)).enabled, isTrue);
    await tester.tap(find.text('账号登录'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<LoginWebView>(
                find.byType(LoginWebView, skipOffstage: false))
            .enabled,
        isFalse);
  });

  testWidgets(
      'registration uses fixed native entrypoint and reports launch failure',
      (tester) async {
    const channel = MethodChannel('oviewer/account_registration');
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'open');
      expect(call.arguments, isNull);
      calls++;
      return false;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await accountScreen(tester);
    await tester.tap(find.text('No account? Register'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Could not open your browser. Please retry.'),
        findsOneWidget);
  });

  testWidgets(
      'leaving account screen cancels queued credentials before network starts',
      (tester) async {
    final auth = await accountScreen(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'test');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pass');
    await tester.tap(find.widgetWithText(FilledButton, 'Login'));
    final request = verify(() => auth.add(captureAny())).captured.single
        as LoginWithAccount;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(request.cancelToken!.isCancelled, isTrue);
  });

  for (final dark in [false, true]) {
    testWidgets(
        'account form scrolls on small screen with keyboard, dark=$dark',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = MockAuthBloc();
      when(() => auth.state).thenReturn(const AuthState(
          status: AuthStatus.error,
          accountFailure: AccountLoginFailure.network));
      when(() => auth.stream).thenAnswer((_) => const Stream.empty());
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(viewInsets: const EdgeInsets.only(bottom: 220)),
                  child: child!),
              home: BlocProvider<AuthBloc>.value(
                  value: auth, child: const LoginScreen()))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('No account? Register'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('No account? Register').hitTestable(), findsOneWidget);
    });
  }

  Future<void> event(String name, {Uri? url}) {
    final done = Completer<void>();
    TestWidgetsFlutterBinding.instance.channelBuffers.push(
      'oviewer/login-webview/${views.single['id']}',
      codec.encodeMethodCall(
          MethodCall(name, {'url': (url ?? loginUrl).toString()})),
      (reply) {
        if (reply != null) codec.decodeEnvelope(reply);
        done.complete();
      },
    );
    return done.future;
  }

  void iosTest(String name, WidgetTesterCallback body) {
    testWidgets(name, body,
        variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  iosTest('iOS uses the script-free native login view', (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(views.single['viewType'], 'oviewer/login-webview');
    expect(find.byType(InAppWebView), findsNothing);
    final bytes = views.single['params'] as Uint8List;
    expect(
        const StandardMessageCodec().decodeMessage(ByteData.sublistView(bytes)),
        {'url': loginUrl.toString()});
  });

  iosTest('challenge is not login; cookies on the login URL submit once',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    readCookies = (_) async => [completeCookies.last];
    await event('onCookiesChanged');
    expect(submissions, isEmpty);
    readCookies = (_) async => completeCookies;
    await event('onCookiesChanged');
    await event('onLoadStop');
    expect(submissions, [
      {'ipb_member_id': '123', 'ipb_pass_hash': 'test-hash'}
    ]);
  });

  iosTest('untrusted URLs and partial cookie scopes cannot submit a login',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    readCookies = (_) async => completeCookies;
    for (final url in [
      'https://e-hentai.org.example.test/',
      'https://example.test/?next=e-hentai.org',
      'http://forums.e-hentai.org/',
      'about:blank',
      'https://challenges.cloudflare.com/',
    ]) {
      await event('onLoadStop', url: Uri.parse(url));
    }
    expect(cookieReads, isEmpty);
    expect(submissions, isEmpty);
    readCookies = (url) async => [
          url.host == 'forums.e-hentai.org'
              ? completeCookies.first
              : completeCookies[1]
        ];
    await event('onLoadStop');
    expect(submissions, isEmpty);
  });

  iosTest('cookie notification during a pending read is not lost',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final pending = Completer<List<Map<String, String>>>();
    var forumReads = 0;
    readCookies = (url) async {
      if (url.host != 'forums.e-hentai.org') return [];
      if (++forumReads == 1) return pending.future;
      return completeCookies;
    };
    final first = event('onCookiesChanged');
    await tester.pump();
    await event('onCookiesChanged');
    pending.complete([]);
    await first;
    expect(submissions, hasLength(1));
    expect(forumReads, 2);
  });

  iosTest('load error and reload retain the same native session',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    var reloads = 0;
    messenger.setMockMethodCallHandler(
        MethodChannel('oviewer/login-webview/${views.single['id']}'),
        (call) async {
      expect(call.method, 'reload');
      reloads++;
      return null;
    });
    await event('onLoadError');
    await tester.pumpAndSettle();
    expect(find.text('Load failed, tap to retry'), findsOneWidget);
    await tester.tap(find.text('Reload login page'));
    await tester.pumpAndSettle();
    expect(reloads, 1);
    expect(views, hasLength(1));
    expect(find.text('Load failed, tap to retry'), findsNothing);
  });

  iosTest('disposed or disabled session never submits a pending cookie read',
      (tester) async {
    for (final dispose in [false, true]) {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final pending = Completer<List<Map<String, String>>>();
      readCookies = (_) => pending.future;
      final loading = event('onCookiesChanged');
      await tester.pump();
      await tester
          .pumpWidget(dispose ? const SizedBox.shrink() : page(enabled: false));
      await tester.pump();
      pending.complete(completeCookies);
      await loading;
      expect(submissions, isEmpty);
    }
  });

  testWidgets('Android keeps its existing browser with native navigation',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final view = tester.widget<InAppWebView>(find.byType(InAppWebView));
    expect(view.initialOptions!.crossPlatform.useShouldOverrideUrlLoading,
        isFalse);
    expect(view.initialOptions!.android.domStorageEnabled, isTrue);
    readCookies = (_) async => completeCookies;
    await tester.runAsync(() async {
      view.onLoadStop!(InAppWebViewController(0, view), loginUrl);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(submissions, hasLength(1));
  });

  iosTest('auth loading, errors and tab switches do not recreate login view',
      (tester) async {
    final auth = MockAuthBloc();
    final repository = MockAuthRepository();
    var state = const AuthState(status: AuthStatus.unauthenticated);
    final states = StreamController<AuthState>.broadcast();
    addTearDown(states.close);
    when(() => auth.state).thenAnswer((_) => state);
    when(() => auth.stream).thenAnswer((_) => states.stream);
    when(() => repository.loginPageUrl).thenReturn(loginUrl.toString());
    GetIt.I.registerSingleton<AuthRepository>(repository);
    await tester.pumpWidget(app(
        BlocProvider<AuthBloc>.value(value: auth, child: const LoginScreen())));
    await tester.pumpAndSettle();
    expect(views, isEmpty);
    await tester.tap(find.text('WebView Login'));
    await tester.pumpAndSettle();
    expect(views, hasLength(1));
    state = const AuthState(status: AuthStatus.loading);
    states.add(state);
    await tester.pump();
    expect(find.byType(UiKitView), findsOneWidget);
    expect(views, hasLength(1));
    state =
        const AuthState(status: AuthStatus.error, errorMessage: 'Save failed');
    states.add(state);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Tab).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('WebView Login'));
    await tester.pumpAndSettle();
    expect(views, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
        '$target logout gates browser creation through cleanup and failure',
        (tester) async {
      final auth = MockAuthBloc();
      final repository = MockAuthRepository();
      var state =
          const AuthState(status: AuthStatus.loggingOut, sessionGeneration: 1);
      final states = StreamController<AuthState>.broadcast();
      when(() => auth.state).thenAnswer((_) => state);
      when(() => auth.stream).thenAnswer((_) => states.stream);
      when(() => repository.loginPageUrl).thenReturn(loginUrl.toString());
      GetIt.I.registerSingleton<AuthRepository>(repository);
      await tester.pumpWidget(app(BlocProvider<AuthBloc>.value(
          value: auth, child: const LoginScreen())));
      await tester.pump();
      expect(find.byType(LoginWebView), findsNothing);
      expect(views, isEmpty);
      expect(find.text('Signing out…'), findsOneWidget);
      state = const AuthState(
          status: AuthStatus.logoutFailed, sessionGeneration: 1);
      states.add(state);
      await tester.pump();
      expect(find.byType(LoginWebView), findsNothing);
      expect(find.text('Sign-out cleanup could not finish. Please retry.'),
          findsOneWidget);
      await tester.tap(find.text('Retry'));
      verify(() => auth.add(LogoutRequested())).called(1);
      state = const AuthState(
          status: AuthStatus.unauthenticated, sessionGeneration: 1);
      states.add(state);
      await tester.pumpAndSettle();
      expect(find.byType(LoginWebView), findsNothing);
      await tester.tap(find.text('WebView Login'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginWebView), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await states.close();
    }, variant: TargetPlatformVariant.only(target));
  }

  iosTest(
      'disable then reenable cannot submit a cookie read from the previous generation',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    final oldRead = Completer<List<Map<String, String>>>();
    readCookies = (_) => oldRead.future;
    final notification = event('onCookiesChanged');
    await tester.pump();
    await tester.pumpWidget(page(enabled: false));
    await tester.pump();
    await tester.pumpWidget(page());
    await tester.pump();
    oldRead.complete(completeCookies);
    await notification;
    await tester.pump();
    expect(submissions, isEmpty);
    readCookies = (_) async => completeCookies;
    await event('onCookiesChanged');
    await tester.pump();
    expect(submissions, hasLength(1));
  });
}
