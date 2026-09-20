import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/widgets/site_settings_webview.dart';

class MockCookieManager extends Mock implements app.CookieManager {}

class MockSettingsBloc extends Mock implements SettingsBloc {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MockCookieManager cookies;
  late MockSettingsBloc settings;
  late List<Map<dynamic, dynamic>> createdViews;

  setUp(() {
    cookies = MockCookieManager();
    settings = MockSettingsBloc();
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    GetIt.I.registerSingleton<app.CookieManager>(cookies);
    createdViews = [];
    messenger.setMockMethodCallHandler(SystemChannels.platform_views,
        (call) async {
      if (call.method == 'create') {
        final arguments = call.arguments as Map;
        final bytes = arguments['params'] as Uint8List;
        createdViews.add(const StandardMessageCodec()
            .decodeMessage(ByteData.sublistView(bytes)) as Map);
        return debugDefaultTargetPlatformOverride == TargetPlatform.android
            ? arguments['id'] as int
            : null;
      }
      if (call.method == 'resize') {
        final arguments = call.arguments as Map;
        return {'width': arguments['width'], 'height': arguments['height']};
      }
      return null;
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    await GetIt.I.reset();
  });

  Widget page(Uri url) => BlocProvider<SettingsBloc>.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(body: SiteSettingsWebView(url: url)),
        ),
      );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform waits for session sync before creating the WebView',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final url = Uri.parse('https://exhentai.org/uconfig.php');
      final ready = Completer<void>();
      when(() => cookies.syncToWebView(url)).thenAnswer((_) => ready.future);

      await tester.pumpWidget(page(url));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      expect(createdViews, isEmpty);

      ready.complete();
      await tester.pumpAndSettle();

      expect(find.byType(InAppWebView), findsOneWidget);
      expect(createdViews, hasLength(1));
      expect(createdViews.single['initialUrlRequest']['url'], url.toString());
      verify(() => cookies.syncToWebView(url)).called(1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
        '$platform resynchronizes before navigating to a different site',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final eh = Uri.parse('https://e-hentai.org/mytags');
      final ex = Uri.parse('https://exhentai.org/mytags');
      final ready = Completer<void>();
      when(() => cookies.syncToWebView(eh)).thenAnswer((_) async {});
      when(() => cookies.syncToWebView(ex)).thenAnswer((_) => ready.future);
      await tester.pumpWidget(page(eh));
      await tester.pumpAndSettle();
      expect(createdViews.single['initialUrlRequest']['url'], eh.toString());

      await tester.pumpWidget(page(ex));
      await tester.pump();
      expect(find.byType(InAppWebView), findsNothing);
      expect(createdViews, hasLength(1));

      ready.complete();
      await tester.pumpAndSettle();
      expect(createdViews, hasLength(2));
      expect(createdViews.last['initialUrlRequest']['url'], ex.toString());
      verify(() => cookies.syncToWebView(ex)).called(1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('failed sync blocks navigation and retry waits for a new session',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final url = Uri.parse('https://exhentai.org/mytags');
    final retry = Completer<void>();
    var attempts = 0;
    when(() => cookies.syncToWebView(url)).thenAnswer((_) {
      attempts++;
      return attempts == 1
          ? Future<void>.error(StateError('Native cookie store unavailable'))
          : retry.future;
    });

    await tester.pumpWidget(page(url));
    await tester.pumpAndSettle();
    expect(find.text('Load failed, tap to retry'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    expect(createdViews, isEmpty);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byType(InAppWebView), findsNothing);
    expect(createdViews, isEmpty);

    retry.complete();
    await tester.pumpAndSettle();
    expect(createdViews.single['initialUrlRequest']['url'], url.toString());
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
