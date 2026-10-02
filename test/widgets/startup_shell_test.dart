import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/app.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/network_preparation.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'package:oviewer/core/network/system_proxy_detector.dart';
import 'package:oviewer/core/services/startup_tasks.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/repositories/auth_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/shimmer_loading.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/main.dart' as entry;
import '../widget_test.dart'
    show MockAuth, MockFavorites, MockGallery, MockHistory, MockSettings;

void main() {
  tearDown(() async {
    NetworkProxy.beforeRequest = null;
    AppConstants.useExHentai = false;
    await GetIt.I.reset();
  });
  testWidgets(
      'essential initialization failure shows a working retry instead of a blank screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), (_) async {
      attempts++;
      throw PlatformException(code: 'temporarily_unavailable');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null));
    await entry.main();
    await tester.pumpAndSettle();
    expect(find.text('Startup failed. Please retry.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'home shell and history remain usable while all startup jobs take ten seconds',
      (tester) async {
    final history = MockHistory();
    when(() => history.getAllHistory())
        .thenAnswer((_) async => <HistoryEntry>[]);
    final auth = MockAuth();
    when(() => auth.isLoggedIn()).thenAnswer((_) async => false);
    final favorites = MockFavorites();
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
    final gallery = MockGallery();
    final settings = MockSettings();
    when(() => settings.getHiddenTags()).thenReturn([]);
    var sent = 0;
    var probes = 0;
    var cleanups = 0;
    var translations = 0;
    final network = NetworkPreparation(
        manualProxy: null,
        autoProxy: true,
        apply: (_) {},
        detect: () {
          probes++;
          return Future.delayed(const Duration(seconds: 10),
              () => const AutoProxyResult(proxyUrl: null, vpnActive: false));
        });
    NetworkProxy.beforeRequest = network.waitUntilReady;
    when(() => gallery.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
        .thenAnswer((_) async {
      await NetworkProxy.waitUntilReady();
      sent++;
      return const GalleryListResult(galleries: [], totalPages: 1);
    });
    GetIt.I.registerSingleton<HistoryRepository>(history);
    GetIt.I.registerSingleton<AuthRepository>(auth);
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    GetIt.I.registerSingleton<GalleryRepository>(gallery);
    GetIt.I.registerSingleton<SettingsRepository>(settings);
    const initial = SettingsState(locale: 'en', themeMode: 2, displayMode: 1);
    final firstFrame = Completer<void>();
    final jobs = StartupTasks(
        prepareNetwork: network.start,
        maintainCache: () {
          cleanups++;
          return Future.delayed(const Duration(seconds: 10));
        },
        loadTranslations: () {
          translations++;
          return Future.delayed(const Duration(seconds: 10));
        });
    final completion = jobs.afterFirstFrame(firstFrame.future);
    expect(
        identical(completion, jobs.afterFirstFrame(firstFrame.future)), isTrue);
    await tester
        .pumpWidget(OViewerApp(initialSettings: initial, network: network));
    await tester.pump();
    expect(find.byType(ShimmerGalleryGrid), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark);
    expect(sent, 0);
    expect(probes, 0);
    expect(cleanups, 0);
    expect(translations, 0);
    verify(() => history.getAllHistory()).called(1);
    firstFrame.complete();
    await tester.pump();
    expect(probes, 1);
    expect(cleanups, 1);
    expect(translations, 1);
    await tester.tap(find.widgetWithText(Tab, 'History'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('No reading history'), findsOneWidget);
    expect(sent, 0);
    await tester.pump(const Duration(seconds: 9));
    expect(sent, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await completion;
    expect(sent, 1);
    expect(probes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    network.dispose();
  });
}
