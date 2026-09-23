import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/history/history_bloc.dart';
import 'package:oviewer/blocs/search/search_bloc.dart';
import 'package:oviewer/blocs/search/search_event.dart';
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
import 'package:oviewer/widgets/gallery_card.dart';

class MockSearch extends Mock implements SearchRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

class MockGallery extends Mock implements GalleryRepository {}

class MockHistory extends Mock implements HistoryRepository {}

class MockSettings extends Mock implements SettingsBloc {}

class MockCookies extends Mock implements CookieManager {}

const thumbUrl = 'https://example.test/cover.png';

GalleryPreview preview(int id) => GalleryPreview(
      gid: id,
      token: 'token',
      title: 'Gallery $id',
      thumbUrl: thumbUrl,
      category: 'Manga',
      rating: 4,
      uploader: 'test',
      fileCount: 10,
      postedAt: DateTime(2026),
    );

void main() {
  setUpAll(() {
    registerFallbackValue(const SearchFilter());
    registerFallbackValue(preview(0));
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await GetIt.I.reset();
  });

  for (final completeBeforePop in [true, false]) {
    testWidgets(
        'search → detail → similar → back preserves results and cursor '
        '(similar completes before pop: $completeBeforePop)', (tester) async {
      final search = MockSearch();
      final favorites = MockFavorites();
      final gallery = MockGallery();
      final history = MockHistory();
      final settings = MockSettings();
      final similar = Completer<SearchResult>();
      final navigator = GlobalKey<NavigatorState>();
      final original = List.generate(20, (i) => preview(i + 1));
      final secondPage = List.generate(10, (i) => preview(i + 21));
      final requests = <(String?, int, String?)>[];

      when(() => search.getSearchHistory()).thenReturn(['original']);
      when(() => search.addSearchHistory(any())).thenAnswer((_) async {});
      when(() => search.search(any(),
          page: any(named: 'page'),
          nextUrl: any(named: 'nextUrl'))).thenAnswer((call) async {
        final filter = call.positionalArguments.single as SearchFilter;
        final page = call.namedArguments[#page] as int? ?? 0;
        final cursor = call.namedArguments[#nextUrl] as String?;
        requests.add((filter.keyword, page, cursor));
        if (filter.keyword == 'Similar title') return similar.future;
        return SearchResult(
          galleries:
              page == 0 ? original : (page == 1 ? secondPage : [preview(31)]),
          totalPages: 3,
          totalResults: 31,
          nextPageUrl: page < 2 ? '/?original-page=${page + 1}' : null,
        );
      });
      when(() => favorites.getLocalFavoriteGids())
          .thenAnswer((_) async => <int>{});
      when(() => gallery.fetchGalleryDetail(any(), any())).thenAnswer(
        (call) async => GalleryDetail(
          gid: call.positionalArguments.first as int,
          token: 'token',
          title: 'Similar title',
          thumbUrl: thumbUrl,
          category: 'Manga',
          uploader: 'test',
          postedAt: DateTime(2026),
          fileCount: 10,
          rating: 4,
        ),
      );
      when(() => history.getProgress(any())).thenAnswer((_) async => null);
      when(() => history.recordVisit(any())).thenAnswer((_) async {});
      when(() => history.getAllHistory()).thenAnswer((_) async => []);
      when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      GetIt.I.registerSingleton<SearchRepository>(search);
      GetIt.I.registerSingleton<FavoritesRepository>(favorites);
      GetIt.I.registerSingleton<GalleryRepository>(gallery);
      GetIt.I.registerSingleton<HistoryRepository>(history);

      // Seed decoded pixels so the navigation test never starts image IO.
      EhImageCacheManager.init(MockCookies());
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final pixels = await tester.runAsync(() => picture.toImage(1, 1));
      picture.dispose();
      PaintingBinding.instance.imageCache.putIfAbsent(
        const CachedNetworkImageProvider(thumbUrl),
        () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: pixels!))),
      );

      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<SettingsBloc>.value(value: settings),
          BlocProvider(create: (_) => HistoryBloc(history)),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          onGenerateRoute: AppRouter.generateRoute,
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.pushNamed(
                          context, AppRouter.search,
                          arguments: 'original'),
                      child: const Text('Open search'),
                    ),
                  )),
        ),
      ));
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      final originalBloc =
          tester.element(find.byType(GalleryCard).first).read<SearchBloc>();
      originalBloc.add(LoadMoreSearchResults());
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(find.byType(ListView));
      list.controller!.jumpTo(450);
      await tester.pumpAndSettle();
      final offset = list.controller!.offset;
      final savedState = originalBloc.state;

      await tester.tap(find.byType(GalleryCard).hitTestable().first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Similar Galleries'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Similar Galleries'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final similarBloc =
          tester.element(find.byType(TextField)).read<SearchBloc>();
      expect(identical(similarBloc, originalBloc), isFalse);
      expect(originalBloc.state, savedState);
      final similarResult = SearchResult(
        galleries: [preview(100)],
        totalPages: 1,
        totalResults: 1,
      );
      if (completeBeforePop) {
        similar.complete(similarResult);
        await tester.pumpAndSettle();
        expect(find.text('Gallery 100'), findsOneWidget);
      }

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      if (!completeBeforePop) {
        similar.complete(similarResult);
        await tester.pumpAndSettle();
      }
      await tester.pump();
      expect(originalBloc.state, savedState);
      expect(list.controller!.offset, offset);
      expect(find.text('Gallery 100'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'original');
      expect(requests.where((r) => r.$1 == 'original' && r.$2 == 0).length, 1);
      verifyNever(() => search.addSearchHistory('Similar title'));

      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(requests.last, ('original', 2, '/?original-page=2'));
      expect(originalBloc.state.results.map((g) => g.gid),
          List.generate(31, (i) => i + 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pump();
    });
  }
}
