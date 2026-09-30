import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/history/history_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/home/home_screen.dart';

class MockGallery extends Mock implements GalleryRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

class MockHistory extends Mock implements HistoryRepository {}

class MockSettingsRepo extends Mock implements SettingsRepository {}

class MockSettings extends Mock implements SettingsBloc {}

class MockAuth extends Mock implements AuthBloc {}

class MockCookies extends Mock implements CookieManager {}

const thumb = 'https://example.test/home-swipe.png';

GalleryListResult galleries(String name, {String? nextUrl}) =>
    GalleryListResult(
        galleries: List.generate(
            40,
            (i) => GalleryPreview(
                gid: name.hashCode + i,
                token: 'abc',
                title: '$name $i',
                thumbUrl: thumb,
                category: 'Manga',
                rating: 4,
                uploader: '',
                fileCount: 12,
                postedAt: DateTime(2026))),
        totalPages: 2,
        nextPageUrl: nextUrl);

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> swipe(WidgetTester tester, {bool right = false}) async {
  await tester.drag(find.byKey(const ValueKey('home-tab-pages')),
      Offset(right ? 290 : -290, 0));
  await frames(tester);
}

int selected(WidgetTester tester) =>
    tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

void main() {
  late MockGallery repo;
  late MockHistory historyRepo;
  late MockSettings settings;
  late MockAuth auth;
  late HistoryBloc history;
  late SettingsState settingsState;
  late AuthState authState;
  late StreamController<SettingsState> settingsStream;
  late StreamController<AuthState> authStream;

  setUp(() {
    repo = MockGallery();
    historyRepo = MockHistory();
    settings = MockSettings();
    auth = MockAuth();
    settingsState = const SettingsState(locale: 'en');
    authState = const AuthState(status: AuthStatus.authenticated);
    settingsStream = StreamController.broadcast();
    authStream = StreamController.broadcast();
    when(() => settings.state).thenAnswer((_) => settingsState);
    when(() => settings.stream).thenAnswer((_) => settingsStream.stream);
    when(() => auth.state).thenAnswer((_) => authState);
    when(() => auth.stream).thenAnswer((_) => authStream.stream);
    when(() => repo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
        .thenAnswer((_) async =>
            galleries('Latest', nextUrl: 'https://example.test/latest-next'));
    when(() => repo.fetchPopularList())
        .thenAnswer((_) async => galleries('Popular'));
    when(() => repo.fetchFavoritesList(nextUrl: any(named: 'nextUrl')))
        .thenAnswer((_) async => galleries('Favorite',
            nextUrl: 'https://example.test/favorites-next'));
    when(() => historyRepo.getAllHistory()).thenAnswer((_) async => []);
    when(() => historyRepo.deleteHistory(any())).thenAnswer((_) async {});
    final favorites = MockFavorites();
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
    final preferences = MockSettingsRepo();
    when(() => preferences.getHiddenTags()).thenReturn([]);
    GetIt.I.registerSingleton<GalleryRepository>(repo);
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    GetIt.I.registerSingleton<SettingsRepository>(preferences);
  });

  tearDown(() async {
    await history.close();
    await settingsStream.close();
    await authStream.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await GetIt.I.reset();
  });

  Future<void> boot(WidgetTester tester, {int displayMode = 0}) async {
    history = HistoryBloc(historyRepo);
    EhImageCacheManager.init(MockCookies());
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    settingsState = settingsState.copyWith(displayMode: displayMode);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final pixels = await tester.runAsync(() => picture.toImage(2, 3));
    picture.dispose();
    PaintingBinding.instance.imageCache.putIfAbsent(
      const CachedNetworkImageProvider(thumb),
      () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: pixels!))),
    );
    await tester.pumpWidget(MultiBlocProvider(providers: [
      BlocProvider<SettingsBloc>.value(value: settings),
      BlocProvider<AuthBloc>.value(value: auth),
      BlocProvider<HistoryBloc>.value(value: history),
    ], child: const MaterialApp(home: HomeScreen())));
    await frames(tester);
  }

  for (final mode in [0, 1]) {
    testWidgets(
        'swipes across all tabs and back, taps stay synchronized (mode $mode)',
        (tester) async {
      await boot(tester, displayMode: mode);
      expect(selected(tester), 0);
      expect(find.text('Latest 0'), findsOneWidget);
      await swipe(tester, right: true);
      expect(selected(tester), 0);
      await swipe(tester);
      expect(selected(tester), 1);
      expect(find.text('Popular 0'), findsOneWidget);
      await swipe(tester);
      expect(selected(tester), 2);
      expect(find.text('No reading history'), findsOneWidget);
      await swipe(tester);
      expect(selected(tester), 3);
      expect(find.text('Favorite 0'), findsOneWidget);
      await swipe(tester);
      expect(selected(tester), 3);
      await swipe(tester, right: true);
      expect(selected(tester), 2);
      await swipe(tester, right: true);
      expect(selected(tester), 1);
      await swipe(tester, right: true);
      expect(selected(tester), 0);
      await tester.tap(find.widgetWithText(Tab, 'Favorites'));
      await frames(tester);
      expect(selected(tester), 3);
      expect(find.text('Favorite 0'), findsOneWidget);
      verify(() => repo.fetchGalleryList(nextUrl: null)).called(1);
      verify(() => repo.fetchPopularList()).called(1);
      verify(() => repo.fetchFavoritesList(nextUrl: null)).called(1);
      verifyNever(() =>
          repo.fetchGalleryList(nextUrl: 'https://example.test/latest-next'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'vertical scrolling and refresh do not change tabs; position survives a round trip',
      (tester) async {
    await boot(tester);
    final latest = find.byKey(const PageStorageKey('home-latest-list'));
    await tester.drag(latest, const Offset(0, -700));
    await frames(tester);
    final scrollable =
        find.descendant(of: latest, matching: find.byType(Scrollable));
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0));
    expect(selected(tester), 0);
    await swipe(tester);
    await swipe(tester, right: true);
    expect(tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(before, 1));
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.drag(latest, const Offset(0, 400));
    await frames(tester);
    expect(selected(tester), 0);
    verify(() => repo.fetchGalleryList(nextUrl: null)).called(2);
  });

  testWidgets('late responses from previous tabs never replace current content',
      (tester) async {
    final pending = Completer<GalleryListResult>();
    when(() => repo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
        .thenAnswer((_) => pending.future);
    await boot(tester);
    await swipe(tester);
    expect(selected(tester), 1);
    expect(find.text('Popular 0'), findsOneWidget);
    pending.complete(galleries('Late latest'));
    await frames(tester);
    expect(find.text('Popular 0'), findsOneWidget);
    expect(find.text('Late latest 0'), findsNothing);
    await swipe(tester, right: true);
    expect(find.text('Late latest 0'), findsOneWidget);
  });

  testWidgets(
      'favorites guard responds to login and logout without changing selected tab',
      (tester) async {
    authState = const AuthState(status: AuthStatus.unauthenticated);
    await boot(tester);
    await tester.tap(find.widgetWithText(Tab, 'Favorites'));
    await frames(tester);
    expect(find.text('Login to favorite!'), findsOneWidget);
    verifyNever(() => repo.fetchFavoritesList(nextUrl: any(named: 'nextUrl')));
    authState = const AuthState(status: AuthStatus.authenticated);
    authStream.add(authState);
    await frames(tester);
    expect(find.text('Favorite 0'), findsOneWidget);
    expect(selected(tester), 3);
    authState = const AuthState(status: AuthStatus.unauthenticated);
    authStream.add(authState);
    await frames(tester);
    expect(find.text('Login to favorite!'), findsOneWidget);
    expect(find.text('Favorite 0'), findsNothing);
    await swipe(tester, right: true);
    expect(selected(tester), 2);
  });

  testWidgets('hidden-tag changes reload previously cached tab contents',
      (tester) async {
    await boot(tester);
    await swipe(tester);
    when(() => repo.fetchPopularList())
        .thenAnswer((_) async => galleries('Filtered popular'));
    settingsState = settingsState.copyWith(hiddenTags: ['female:test']);
    settingsStream.add(settingsState);
    await frames(tester);
    expect(find.text('Filtered popular 0'), findsOneWidget);
    expect(find.text('Popular 0'), findsNothing);
    await swipe(tester, right: true);
    verify(() => repo.fetchGalleryList(nextUrl: null)).called(2);
  });

  testWidgets('site change discards all previous tab lists and late requests',
      (tester) async {
    final pending = Completer<GalleryListResult>();
    when(() => repo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
        .thenAnswer((_) => pending.future);
    await boot(tester);
    await swipe(tester);
    when(() => repo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
        .thenAnswer((_) async => galleries('New site'));
    when(() => repo.fetchPopularList())
        .thenAnswer((_) async => galleries('New popular'));
    settingsState = settingsState.copyWith(useExHentai: true);
    settingsStream.add(settingsState);
    await frames(tester);
    expect(find.text('New popular 0'), findsOneWidget);
    pending.complete(galleries('Old site'));
    await frames(tester);
    await swipe(tester, right: true);
    expect(find.text('New site 0'), findsOneWidget);
    expect(find.text('Old site 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'history rows allow swiping and delete only after long-press selection',
      (tester) async {
    final entry = HistoryEntry(
        gid: 47,
        token: 'abc',
        title: 'History item',
        thumbUrl: thumb,
        category: 'Manga',
        rating: 4,
        fileCount: 12,
        lastReadPage: 0,
        totalPages: 12,
        lastReadAt: DateTime(2026));
    when(() => historyRepo.getAllHistory()).thenAnswer((_) async => [entry]);
    await boot(tester);
    await tester.tap(find.widgetWithText(Tab, 'History'));
    await frames(tester);
    expect(selected(tester), 2);
    expect(history.state.entries, hasLength(1));
    expect(find.byIcon(Icons.delete_sweep), findsOneWidget);
    await tester.drag(find.text('History item'), const Offset(-290, 0));
    await frames(tester);
    expect(selected(tester), 3);
    verifyNever(() => historyRepo.deleteHistory(any()));
    await swipe(tester, right: true);
    await tester.longPress(find.text('History item'));
    await frames(tester);
    await tester.tap(find.text('Cancel'));
    await frames(tester);
    verifyNever(() => historyRepo.deleteHistory(any()));
    await tester.longPress(find.text('History item'));
    await frames(tester);
    await tester.tap(find.text('Delete'));
    await frames(tester);
    verify(() => historyRepo.deleteHistory(47)).called(1);
    expect(selected(tester), 2);
  });
}
