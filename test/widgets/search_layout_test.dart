import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/search/search_screen.dart';
import 'package:oviewer/widgets/gallery_card.dart';
import 'package:oviewer/widgets/gallery_grid_item.dart';

class MockSearch extends Mock implements SearchRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

class MockSettings extends Mock implements SettingsRepository {}

class MockCookies extends Mock implements CookieManager {}

void main() {
  setUpAll(() => registerFallbackValue(const SearchFilter()));
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await GetIt.I.reset();
  });

  testWidgets(
      'search switches layouts, adapts portrait covers and keeps navigation/pagination',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = MockSettings();
    when(() => settings.setDisplayMode(any())).thenAnswer((_) async {});
    final settingsBloc = SettingsBloc(settings);
    addTearDown(settingsBloc.close);
    final repo = MockSearch();
    final favorites = MockFavorites();
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {1});
    when(() => repo.getSearchHistory()).thenReturn([]);
    when(() => repo.addSearchHistory(any())).thenAnswer((_) async {});
    const thumb = 'https://example.test/layout.png';
    List<GalleryPreview> items(int start, int count) => List.generate(
        count,
        (i) => GalleryPreview(
            gid: start + i,
            token: 'abc',
            title: 'Gallery ${start + i}',
            thumbUrl: thumb,
            category: 'Manga',
            rating: 4,
            uploader: '',
            fileCount: 30,
            postedAt: DateTime(2026)));
    var requests = 0;
    when(() => repo.search(any(),
        page: any(named: 'page'),
        nextUrl: any(named: 'nextUrl'))).thenAnswer((call) async {
      requests++;
      final next = call.namedArguments[#nextUrl] != null;
      return SearchResult(
          galleries: next ? items(31, 5) : items(1, 30),
          totalPages: 2,
          totalResults: 35,
          nextPageUrl: next ? null : '/?next=30');
    });
    GetIt.I.registerSingleton<SearchRepository>(repo);
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    EhImageCacheManager.init(MockCookies());
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
    Map<String, dynamic>? opened;
    await tester.pumpWidget(BlocProvider.value(
      value: settingsBloc,
      child: MaterialApp(
        home: const SearchScreen(initialKeyword: 'test'),
        onGenerateRoute: (route) {
          opened = route.arguments as Map<String, dynamic>;
          return MaterialPageRoute<void>(
              builder: (_) =>
                  Scaffold(appBar: AppBar(title: const Text('Detail'))));
        },
      ),
    ));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('search-view-toggle'));
    final listController =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    listController.jumpTo(450);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(GalleryCard), findsNothing);
    expect(find.byType(GalleryGridItem), findsWidgets);
    verify(() => settings.setDisplayMode(1)).called(1);

    for (final viewport in [
      const Size(320, 720),
      const Size(600, 800),
      const Size(900, 400),
      const Size(1200, 800)
    ]) {
      await tester.binding.setSurfaceSize(viewport);
      await tester.pumpAndSettle();
      final fieldRect = tester.getRect(find.byType(TextField));
      final buttonRect = tester.getRect(toggle);
      expect(fieldRect.right, lessThanOrEqualTo(buttonRect.left));
      expect(buttonRect.right, closeTo(viewport.width, 1));
      final grid = tester.widget<MasonryGridView>(find.byType(MasonryGridView));
      final delegate =
          grid.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, ((viewport.width - 8) / 228).ceil());
      final cover = find.descendant(
          of: find.byType(GalleryGridItem).first,
          matching: find.byType(CachedNetworkImage));
      final size = tester.getSize(cover);
      expect(size.width / size.height, closeTo(2 / 3, 0.001));
      expect(tester.takeException(), isNull);
    }
    expect(requests, 1);
    await tester.tap(find.byType(GalleryGridItem).first);
    await tester.pumpAndSettle();
    expect(opened, {'gid': 1, 'token': 'abc'});
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(GalleryGridItem), findsWidgets);
    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(listController.offset, 450);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'test');
    expect(requests, 1);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final grid = tester.widget<MasonryGridView>(find.byType(MasonryGridView));
    grid.controller!.jumpTo(grid.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
