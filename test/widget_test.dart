import 'dart:async';
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/app.dart';
import 'package:oviewer/blocs/history/history_bloc.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/repositories/auth_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/screens/home/home_screen.dart';

class MockAuth extends Mock implements AuthRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

class MockGallery extends Mock implements GalleryRepository {}

class MockHistory extends Mock implements HistoryRepository {}

class MockSearch extends Mock implements SearchRepository {}

class MockSettings extends Mock implements SettingsRepository {}

class MockDio extends Mock implements DioClient {}

class MockCookies extends Mock implements CookieManager {}

void main() {
  tearDown(() async {
    AppConstants.useExHentai = false;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await GetIt.I.reset();
  });
  for (final empty in [false, true]) {
    testWidgets(
        'application preloads history before its first tab visit (empty: $empty)',
        (tester) async {
      final pending = Completer<List<HistoryEntry>>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete([]);
      });
      final history = MockHistory();
      when(() => history.getAllHistory()).thenAnswer((_) => pending.future);
      final gallery = MockGallery();
      when(() => gallery.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
          .thenAnswer((_) async =>
              const GalleryListResult(galleries: [], totalPages: 1));
      final auth = MockAuth();
      when(() => auth.isLoggedIn()).thenAnswer((_) async => false);
      final favorites = MockFavorites();
      when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
      final settings = MockSettings();
      when(() => settings.getUseExHentai()).thenReturn(false);
      when(() => settings.getAutoProxy()).thenReturn(false);
      when(() => settings.getProxy()).thenReturn(null);
      when(() => settings.getThemeMode()).thenReturn(0);
      when(() => settings.getReadingMode()).thenReturn(0);
      when(() => settings.getDisplayMode()).thenReturn(0);
      when(() => settings.getCacheLimit()).thenReturn(500);
      when(() => settings.getHiddenTags()).thenReturn([]);
      when(() => settings.getLocale()).thenReturn('en');
      GetIt.I.registerSingleton<HistoryRepository>(history);
      GetIt.I.registerSingleton<GalleryRepository>(gallery);
      GetIt.I.registerSingleton<AuthRepository>(auth);
      GetIt.I.registerSingleton<FavoritesRepository>(favorites);
      GetIt.I.registerSingleton<SettingsRepository>(settings);
      GetIt.I.registerSingleton<SearchRepository>(MockSearch());
      GetIt.I.registerSingleton<DioClient>(MockDio());
      EhImageCacheManager.init(MockCookies());
      const thumb = 'https://example.test/preloaded-history.png';
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final picture = recorder.endRecording();
      final pixels = await tester.runAsync(() => picture.toImage(2, 3));
      picture.dispose();
      PaintingBinding.instance.imageCache.putIfAbsent(
          const CachedNetworkImageProvider(thumb),
          () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: pixels!))));
      await tester.pumpWidget(const OViewerApp());
      await tester.pump();
      // No history tab lookup or bloc read has occurred yet.
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      verify(() => history.getAllHistory()).called(1);
      final entries = empty
          ? <HistoryEntry>[]
          : [
              HistoryEntry(
                  gid: 47,
                  token: 'abc',
                  title: 'Preloaded record',
                  thumbUrl: thumb,
                  category: 'Manga',
                  rating: 4,
                  fileCount: 12,
                  lastReadPage: 0,
                  totalPages: 12,
                  lastReadAt: DateTime(2026))
            ];
      pending.complete(entries);
      await tester.pump();
      await tester.pump();
      expect(
          tester
              .element(find.byType(HomeScreen))
              .read<HistoryBloc>()
              .state
              .entries,
          entries);
      await tester.tap(find.widgetWithText(Tab, 'History'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Loading history…'), findsNothing);
      expect(find.text('No reading history'),
          empty ? findsOneWidget : findsNothing);
      if (!empty) expect(find.text('Preloaded record'), findsOneWidget);
      verifyNever(() => history.getAllHistory());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
