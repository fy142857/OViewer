import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_bloc.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_event.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/gallery_favorite_buttons.dart';

class MockDio extends Mock implements DioClient {}

class MockDb extends Mock implements AppDatabase {}

class MockGallery extends Mock implements GalleryRepository {}

class MockSettings extends Mock implements SettingsRepository {}

Future<SettingsRepository> settings() async {
  final storage = LocalStorage();
  await storage.init();
  return SettingsRepository(storage);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const LocalFavoritesCompanion()));
  tearDown(() => AppConstants.useExHentai = false);

  test('destination survives fresh storage and remains independent of filter',
      () async {
    SharedPreferences.setMockInitialValues({});
    var prefs = await settings();
    expect(prefs.getFavoriteDestination(), 0);
    await prefs.setFavoriteCategory(-1);
    for (var slot = 0; slot <= 9; slot++) {
      await prefs.setFavoriteDestination(slot);
      final shared = await SharedPreferences.getInstance();
      final disk = Map<String, Object>.fromEntries(
          shared.getKeys().map((key) => MapEntry(key, shared.get(key)!)));
      SharedPreferences.setMockInitialValues(disk);
      prefs = await settings();
      expect(prefs.getFavoriteDestination(), slot);
      expect(prefs.getFavoriteCategory(), -1);
    }
    await expectLater(prefs.setFavoriteDestination(-1), throwsArgumentError);
    await expectLater(prefs.setFavoriteDestination(10), throwsArgumentError);
    expect(prefs.getFavoriteDestination(), 9);
  });

  for (final invalid in [-1, 10, '9']) {
    test('invalid saved destination $invalid falls back to 0', () async {
      SharedPreferences.setMockInitialValues({'favorite_destination': invalid});
      expect((await settings()).getFavoriteDestination(), 0);
    });
  }

  for (final ex in [false, true]) {
    test(
        'detail heart sends selected slot to ${ex ? 'EX' : 'EH'}; removal stays removal',
        () async {
      AppConstants.useExHentai = ex;
      final dio = MockDio();
      final db = MockDb();
      final gallery = MockGallery();
      final posts = <Map<String, String>>[];
      when(() => db.addLocalFavorite(any())).thenAnswer((_) async {});
      when(() => db.getLocalFavorite(any())).thenAnswer((_) async => null);
      when(() => db.removeLocalFavorite(any())).thenAnswer((_) async {});
      when(() => dio.post(any(), data: any(named: 'data')))
          .thenAnswer((call) async {
        expect(Uri.parse(call.positionalArguments.first as String).host,
            ex ? 'exhentai.org' : 'e-hentai.org');
        posts.add(
            Map.fromEntries((call.namedArguments[#data] as FormData).fields));
        return '';
      });
      when(() => gallery.fetchGalleryDetail(42, 'abc')).thenAnswer((_) async =>
          GalleryDetailParser.parse('<h1 id="gn">Gallery</h1>', 42, 'abc'));
      final bloc = GalleryDetailBloc(gallery, FavoritesRepository(dio, db));
      final loaded =
          bloc.stream.firstWhere((s) => s.status == GalleryDetailStatus.loaded);
      bloc.add(const FetchGalleryDetail(gid: 42, token: 'abc'));
      await loaded;
      for (var slot = 0; slot <= 9; slot++) {
        bloc.add(ToggleFavorite(gid: 42, token: 'abc', slot: slot));
        await flush();
        expect(bloc.state.detail!.favoritedSlot, slot);
        expect(posts.last['favcat'], '$slot');
        bloc.add(const ToggleFavorite(gid: 42, token: 'abc', slot: 0));
        await flush();
        expect(bloc.state.detail!.isFavorited, false);
        expect(posts.last['favcat'], 'favdel');
      }
      addTearDown(bloc.close);
    });
  }

  for (final locale in ['zh', 'en']) {
    testWidgets(
        'menu above heart selects all ten slots, persists and cancels ($locale)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final prefs = await settings();
      final bloc =
          SettingsBloc(prefs, initialState: SettingsState(locale: locale));
      final actions = <int>[];
      Future<void> mount() => tester.pumpWidget(BlocProvider.value(
          value: bloc,
          child: MaterialApp(
              home: Scaffold(
                  body: Center(
                      child: GalleryFavoriteButtons(
                          settings: prefs,
                          isFavorited: false,
                          onToggle: actions.add))))));
      await mount();
      final menu = find.byKey(const ValueKey('choose-favorite-destination'));
      final heart = find.byKey(const ValueKey('toggle-gallery-favorite'));
      expect(tester.getCenter(menu).dx, tester.getCenter(heart).dx);
      expect(tester.getRect(menu).bottom, lessThan(tester.getRect(heart).top));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text(locale == 'zh' ? '收藏到' : 'Save favorites to'),
          findsOneWidget);
      expect(
          (tester.widget<ListView>(find.byType(ListView)).childrenDelegate
                  as SliverChildListDelegate)
              .children
              .length,
          10);
      final last = find.byKey(const ValueKey('favorite-destination-9'));
      await tester.scrollUntilVisible(last, 180);
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(prefs.getFavoriteDestination(), 9);
      expect(actions, isEmpty);
      await tester.tap(heart);
      expect(actions, [9]);
      await tester.pumpWidget(const SizedBox());
      await mount();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(last, 180);
      expect(tester.widget<ListTile>(last).selected, true);
      Navigator.of(tester.element(last)).pop();
      await tester.pumpAndSettle();
      expect(prefs.getFavoriteDestination(), 9);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      addTearDown(bloc.close);
    });
  }

  testWidgets(
      'saving blocks heart; failed save reports error and keeps old choice',
      (tester) async {
    final prefs = MockSettings();
    when(() => prefs.getFavoriteDestination()).thenReturn(2);
    final save = Completer<void>();
    when(() => prefs.setFavoriteDestination(0)).thenAnswer((_) => save.future);
    final bloc = SettingsBloc(prefs, initialState: const SettingsState());
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: MaterialApp(
            home: Scaffold(
                body: GalleryFavoriteButtons(
                    settings: prefs,
                    isFavorited: true,
                    onToggle: (_) => fail('Must not toggle during save'))))));
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favorite 0'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('toggle-gallery-favorite')))
            .onPressed,
        isNull);
    save.completeError(StateError('disk unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('无法保存收藏目标分组，请重试'), findsOneWidget);
    expect(prefs.getFavoriteDestination(), 2);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    addTearDown(bloc.close);
  });
}

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
