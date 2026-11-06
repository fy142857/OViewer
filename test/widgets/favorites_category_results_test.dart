import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/image_cache_scope.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/blocs/favorites/favorites_bloc.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/favorites_content.dart';
import 'package:oviewer/widgets/favorites_filter_button.dart';
import '../favorites_filters_test.dart' show categoryPage;
import '../favorites_scope_test.dart' show DioMock, Db;
import 'favorites_search_ui_test.dart' show Auth, Settings;
import 'favorite_icon_test.dart' show MockCookies;

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(const LocalFavoritesCompanion());
  });
  for (final entry in FavoritesEntry.values) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
          'actual favorites rows are filtered and group field is compact $entry/$scale',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = LocalStorage();
        await storage.init();
        final dio = DioMock();
        when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
            .thenAnswer((call) async {
          final uri = Uri.parse(call.positionalArguments.first as String);
          return switch (uri.queryParameters['next']) {
            '1' => categoryPage([(3, 'Misc')], next: '?next=2'),
            '2' => categoryPage([(2, 'Western'), (1, 'Manga')]),
            _ => categoryPage([(5, 'Western'), (4, 'Manga')], next: '?next=1'),
          };
        });
        final db = Db();
        when(() => db.getLocalFavorite(any())).thenAnswer((_) async => null);
        when(() => db.addLocalFavorite(any())).thenAnswer((_) async {});
        final repo = FavoritesRepository(dio, db);
        final bloc = FavoritesBloc(repo, settings: SettingsRepository(storage));
        addTearDown(bloc.close);
        bloc.syncSession(
            site: 'eh', signedIn: true, revision: 1, account: 'fixture');
        final auth = Auth();
        final settings = Settings();
        when(() => auth.state)
            .thenReturn(const AuthState(status: AuthStatus.authenticated));
        when(() => auth.stream).thenAnswer((_) => const Stream.empty());
        when(() => settings.state)
            .thenReturn(const SettingsState(locale: 'en'));
        when(() => settings.stream).thenAnswer((_) => const Stream.empty());
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        EhImageCacheManager.init(MockCookies());
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await tester.runAsync(() => picture.toImage(2, 3));
        picture.dispose();
        PaintingBinding.instance.imageCache.putIfAbsent(
            CachedNetworkImageProvider('',
                cacheKey: ImageCacheScope.capture().key('')),
            () => OneFrameImageStreamCompleter(
                Future.value(ImageInfo(image: image!))));
        addTearDown(() {
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        });
        await tester.pumpWidget(MultiBlocProvider(
            providers: [
              BlocProvider<AuthBloc>.value(value: auth),
              BlocProvider<SettingsBloc>.value(value: settings),
              BlocProvider<FavoritesBloc>.value(value: bloc),
            ],
            child: MaterialApp(
                home: Scaffold(
                    body: FavoritesContent(
                        storageKey: 'category-results', entry: entry),
                    floatingActionButton: FavoritesFilterButton(
                        heroTag: 'filter', entry: entry)))));
        await tester.pumpAndSettle();
        expect(find.text('Gallery 5'), findsOneWidget);
        expect(find.text('Gallery 4'), findsOneWidget);
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        final group = find.byKey(const ValueKey('favorite-group-selector'));
        final fieldHeight = tester.getSize(group).height;
        expect(fieldHeight, greaterThanOrEqualTo(40));
        expect(fieldHeight, lessThanOrEqualTo(scale == 1 ? 56 : 80));
        final manga = find.byKey(const ValueKey('gallery-category-Manga'));
        await tester.ensureVisible(manga);
        await tester.pumpAndSettle();
        await tester.tap(manga);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('favorite-filters-apply')));
        await tester.pumpAndSettle();
        expect(find.text('Gallery 4'), findsOneWidget);
        expect(find.text('Gallery 5'), findsNothing);
        await tester.drag(find.byType(ListView).first, const Offset(0, -300));
        await tester.pumpAndSettle();
        final active = bloc.forEntry(entry);
        expect(active.state.favorites.map((g) => g.gid), [4, 1]);
        expect(
            active.state.favorites.every((g) => g.category == 'Manga'), true);
        expect(active.state.hasReachedEnd, true);
        expect(find.text('Gallery 2'), findsNothing);
        expect(find.text('Gallery 3'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}
