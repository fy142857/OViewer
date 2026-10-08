import 'dart:async';
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/history/history_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/router/app_router.dart';
import 'package:oviewer/models/gallery_detail.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/search/search_screen.dart';
import 'package:oviewer/widgets/gallery_card.dart';
import 'package:oviewer/widgets/gallery_grid_item.dart';

class MockSearch extends Mock implements SearchRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

class MockGallery extends Mock implements GalleryRepository {}

class MockHistory extends Mock implements HistoryRepository {}

class MockSettings extends Mock implements SettingsBloc {}

class MockPreferences extends Mock implements SettingsRepository {}

class MockCookies extends Mock implements CookieManager {}

const thumb = 'https://example.test/gid-cover.png';
GalleryPreview gallery(int gid) => GalleryPreview(
    gid: gid,
    token: 'abcdef1234',
    title: 'Gallery $gid',
    thumbUrl: thumb,
    category: 'Manga',
    rating: 4,
    uploader: 'tester',
    fileCount: 20,
    postedAt: DateTime(2026));
SearchResult results(List<int> ids) => SearchResult(
    galleries: ids.map(gallery).toList(),
    totalPages: 1,
    totalResults: ids.length);

Future<void> boot(WidgetTester tester, MockSearch repo,
    {String locale = 'zh',
    bool grid = false,
    String keyword = '00042',
    double width = 360,
    double textScale = 1,
    int? favoritedSlot}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final settings = MockSettings();
  final favorites = MockFavorites();
  final galleries = MockGallery();
  final history = MockHistory();
  when(() => settings.state)
      .thenReturn(SettingsState(locale: locale, displayMode: grid ? 1 : 0));
  when(() => settings.stream).thenAnswer((_) => const Stream.empty());
  when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
  when(() => repo.getSearchHistory()).thenReturn([]);
  when(() => repo.addSearchHistory(any())).thenAnswer((_) async {});
  when(() => galleries.fetchGalleryDetail(42, 'abcdef1234')).thenAnswer(
      (_) async => GalleryDetail(
          gid: 42,
          favoritedSlot: favoritedSlot,
          token: 'abcdef1234',
          title: 'Gallery 42',
          thumbUrl: thumb,
          category: 'Manga',
          uploader: 'tester',
          postedAt: DateTime(2026),
          fileCount: 20,
          rating: 4));
  when(() => history.getProgress(any())).thenAnswer((_) async => null);
  when(() => history.recordVisit(any())).thenAnswer((_) async {});
  when(() => history.getAllHistory()).thenAnswer((_) async => []);
  GetIt.I.registerSingleton<SearchRepository>(repo);
  GetIt.I.registerSingleton<FavoritesRepository>(favorites);
  GetIt.I.registerSingleton<GalleryRepository>(galleries);
  GetIt.I.registerSingleton<HistoryRepository>(history);
  final preferences = MockPreferences();
  when(() => preferences.getFavoriteDestination()).thenReturn(0);
  GetIt.I.registerSingleton<SettingsRepository>(preferences);
  EhImageCacheManager.init(MockCookies());
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
  final picture = recorder.endRecording();
  final pixels = await tester.runAsync(() => picture.toImage(2, 3));
  picture.dispose();
  PaintingBinding.instance.imageCache.putIfAbsent(
      const CachedNetworkImageProvider(thumb),
      () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: pixels!))));
  await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<SettingsBloc>.value(value: settings),
        BlocProvider(create: (_) => HistoryBloc(history)),
      ],
      child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaleFactor: textScale),
              child: child!),
          onGenerateRoute: AppRouter.generateRoute,
          home: SearchScreen(initialKeyword: keyword))));
  await tester.pump();
}

void main() {
  setUpAll(() {
    registerFallbackValue(const SearchFilter());
    registerFallbackValue(gallery(0));
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await GetIt.I.reset();
  });
  for (final layout in [(320.0, 1.0), (360.0, 1.3), (800.0, 1.0)]) {
    for (final slot in [null, 0, 9]) {
      testWidgets(
          'detail action row and full-width read button at $layout slot=$slot',
          (tester) async {
        final repo = MockSearch();
        when(() => repo.search(any())).thenAnswer((_) async => results([]));
        await boot(tester, repo,
            keyword: 'first',
            width: layout.$1,
            textScale: layout.$2,
            favoritedSlot: slot);
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byType(TextField), 'https://e-hentai.org/g/42/abcdef1234/');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        final read = find.byKey(const ValueKey('read-gallery'));
        await tester.ensureVisible(read);
        await tester.pumpAndSettle();
        final download = find.byKey(const ValueKey('download-gallery'));
        final menu = find.byKey(const ValueKey('choose-favorite-destination'));
        final heart = find.byKey(const ValueKey('toggle-gallery-favorite'));
        expect(tester.getCenter(download).dy,
            closeTo(tester.getCenter(menu).dy, 0.1));
        expect(tester.getCenter(menu).dy,
            closeTo(tester.getCenter(heart).dy, 0.1));
        expect(tester.getBottomRight(download).dx,
            lessThan(tester.getTopLeft(menu).dx));
        expect(tester.getBottomRight(menu).dx,
            lessThan(tester.getTopLeft(heart).dx));
        expect(tester.getBottomRight(heart).dy,
            lessThan(tester.getTopLeft(read).dy));
        expect(tester.getTopLeft(read).dx, closeTo(16, 0.1));
        expect(tester.getBottomRight(read).dx, closeTo(layout.$1 - 16, 0.1));
        expect(tester.getBottomRight(heart).dx,
            closeTo(tester.getBottomRight(read).dx, 0.1));
        if (slot != null) {
          expect(
              find.descendant(of: heart, matching: find.text('Favorite $slot')),
              findsOneWidget);
        } else {
          expect(find.descendant(of: heart, matching: find.byType(Text)),
              findsNothing);
        }
        await tester.tap(download);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('pasted complete gallery URL keeps direct navigation',
      (tester) async {
    final repo = MockSearch();
    when(() => repo.search(any())).thenAnswer((_) async => results([]));
    await boot(tester, repo, keyword: 'first');
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'https://e-hentai.org/g/42/abcdef1234/');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Token'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is SelectableText && w.data == 'abcdef1234'),
        findsOneWidget);
    verify(() => repo.search(any())).called(1);
    verifyNever(() => repo.searchByGid(any()));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  for (final locale in ['zh', 'en']) {
    for (final grid in [false, true]) {
      testWidgets(
          '$locale grid=$grid: partial results, pinned match, detail and selectable metadata',
          (tester) async {
        final repo = MockSearch();
        final exact = Completer<GalleryPreview?>();
        addTearDown(() {
          if (!exact.isCompleted) exact.complete(null);
        });
        when(() => repo.search(any()))
            .thenAnswer((_) async => results([50, 42]));
        when(() => repo.searchByGid(42)).thenAnswer((_) => exact.future);
        await boot(tester, repo, locale: locale, grid: grid);
        await tester.pumpAndSettle();
        expect(find.text('Gallery 50'), findsOneWidget);
        expect(
            tester
                .widget<TextField>(find.byType(TextField))
                .decoration!
                .hintText,
            locale == 'zh'
                ? '输入标题、作者、Tag、画廊gid、上传者...'
                : 'Enter title, author, Tag, gallery GID, uploader...');
        expect(find.text(locale == 'zh' ? '正在查找 GID…' : 'Looking up GID…'),
            findsNothing);
        expect(find.text(locale == 'zh' ? '正在搜索关键词…' : 'Searching keywords…'),
            findsNothing);
        expect(
            find.text(locale == 'zh'
                ? 'GID 精确查找不受搜索页筛选影响'
                : 'Exact GID lookup ignores search filters'),
            findsNothing);
        expect(find.text(locale == 'zh' ? '没有找到结果' : 'No results found'),
            findsNothing);
        exact.complete(gallery(42));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('gid-match-label')), findsOneWidget);
        expect(find.text('Gallery 42'), findsOneWidget);
        final cards =
            grid ? find.byType(GalleryGridItem) : find.byType(GalleryCard);
        final first = tester.widget(cards.first);
        expect(
            grid
                ? (first as GalleryGridItem).gallery.gid
                : (first as GalleryCard).gallery.gid,
            42);
        await tester.tap(cards.first);
        await tester.pumpAndSettle();
        expect(find.text('GID'), findsOneWidget);
        expect(find.text('Token'), findsOneWidget);
        final gidValue = find
            .byWidgetPredicate((w) => w is SelectableText && w.data == '42');
        final tokenValue = find.byWidgetPredicate(
            (w) => w is SelectableText && w.data == 'abcdef1234');
        expect(gidValue, findsOneWidget);
        expect(tokenValue, findsOneWidget);
        expect(
            tester.getTopLeft(find.text('GID')).dy,
            greaterThan(tester
                .getTopLeft(find.text(locale == 'zh' ? '发布时间' : 'Posted'))
                .dy));
        expect(tester.getTopLeft(find.text('Token')).dy,
            greaterThan(tester.getTopLeft(find.text('GID')).dy));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
    testWidgets(
        '$locale: failed GID branch keeps results and retries from notice',
        (tester) async {
      final repo = MockSearch();
      when(() => repo.search(any())).thenAnswer((_) async => results([50]));
      when(() => repo.searchByGid(42)).thenThrow(Exception('offline'));
      await boot(tester, repo, locale: locale);
      await tester.pumpAndSettle();
      expect(find.text('Gallery 50'), findsOneWidget);
      expect(find.text(locale == 'zh' ? 'GID 查找失败' : 'GID lookup failed'),
          findsOneWidget);
      when(() => repo.searchByGid(42)).thenAnswer((_) async => gallery(42));
      await tester.tap(find.byKey(const ValueKey('retry-gid-search')));
      await tester.pumpAndSettle();
      expect(find.text('Gallery 42'), findsOneWidget);
      expect(find.byKey(const ValueKey('retry-gid-search')), findsNothing);
      verify(() => repo.search(any())).called(1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
