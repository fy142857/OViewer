import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/tag_translation_repository.dart';
import 'package:oviewer/screens/search/search_screen.dart';
import '../repositories/tag_translation_startup_test.dart'
    show MockDio, MemoryTags;

class Search extends Mock implements SearchRepository {}

class Settings extends Mock implements SettingsBloc {}

class Favorites extends Mock implements FavoritesRepository {}

String dictionary(String translated) => jsonEncode({
      'data': [
        {
          'namespace': 'artist',
          'data': {
            'nanao yukiji | pen name': {'name': translated},
          }
        },
      ]
    });

void main() {
  setUpAll(() => registerFallbackValue(const SearchFilter()));
  tearDown(() => GetIt.I.reset());
  for (final language in ['zh', 'en']) {
    testWidgets(
        'English, Chinese and Japanese recall and submit original history ($language)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final storage = LocalStorage();
      await storage.init();
      final dio = MockDio();
      when(() => dio.get(any()))
          .thenAnswer((_) async => throw StateError('offline'));
      final tags = TagTranslationRepository(dio, storage,
          cache: MemoryTags(dictionary('七尾雪路（七尾ゆきじ）')));
      addTearDown(tags.dispose);
      await tester.runAsync(tags.loadTranslations);
      final search = Search();
      final favorites = Favorites();
      final settings = Settings();
      const newest = r'artist:"nanao yukiji$" language:chinese';
      final history = [newest, '七尾ゆきじ'];
      when(() => search.getSearchHistory()).thenAnswer((_) => history);
      when(() => search.addSearchHistory(any())).thenAnswer((_) async {});
      when(() => search.search(any())).thenAnswer((_) async =>
          const SearchResult(galleries: [], totalPages: 0, totalResults: 0));
      when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
      when(() => settings.state).thenReturn(SettingsState(locale: language));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      GetIt.I.registerSingleton<TagTranslationRepository>(tags);
      GetIt.I.registerSingleton<SearchRepository>(search);
      GetIt.I.registerSingleton<FavoritesRepository>(favorites);
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: language == 'zh' ? ThemeMode.dark : ThemeMode.light,
              home: const SearchScreen())));
      await tester.pumpAndSettle();
      for (final input in ['NANAO YUKI', '七尾雪', '七尾ゆき', 'pen name']) {
        await tester.enterText(find.byType(TextField), input);
        await tester.pump(const Duration(milliseconds: 160));
        await tester.pump();
        final rows = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .where((tile) =>
                tile.leading is Icon &&
                (tile.leading as Icon).icon == Icons.history)
            .map((tile) => (tile.title! as Text).data)
            .toList();
        expect(rows, history, reason: input);
        final recentRows = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .where((tile) =>
                tile.leading is Icon &&
                (tile.leading as Icon).icon == Icons.history)
            .toList();
        final firstAliases = (recentRows.first.subtitle! as Text).data!;
        expect((recentRows.first.subtitle! as Text).style, isNull,
            reason:
                'Keep the original ListTile subtitle theme, not outline gray');
        expect(firstAliases, contains('七尾雪路（七尾ゆきじ）'));
        expect(firstAliases, contains('七尾雪路'));
        expect(firstAliases, contains('七尾ゆきじ'));
        expect(firstAliases, contains('pen name'));
        expect(firstAliases, isNot(contains('nanao yukiji')));
        final secondAliases = (recentRows[1].subtitle! as Text).data!;
        expect(secondAliases, contains('七尾雪路'));
        expect(secondAliases, contains('nanao yukiji'));
        expect(secondAliases, contains('七尾雪路（七尾ゆきじ）'));
      }
      await tester.tap(find.text(newest));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, newest);
      expect(field.controller!.selection.extentOffset, newest.length);
      expect(field.focusNode!.hasFocus, true);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      verify(() => search.addSearchHistory(newest)).called(1);
      final filter = verify(() => search.search(captureAny())).captured.single
          as SearchFilter;
      expect(filter.keyword, newest);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'dictionary arrival and refresh update history without disturbing composition',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final dio = MockDio();
    when(() => dio.get(any()))
        .thenAnswer((_) async => throw StateError('offline'));
    final tags = TagTranslationRepository(dio, storage,
        cache: MemoryTags(dictionary('七尾雪路（七尾ゆきじ）')));
    addTearDown(tags.dispose);
    final search = Search();
    final settings = Settings();
    const saved = r'artist:"nanao yukiji$"';
    when(() => search.getSearchHistory()).thenReturn([saved]);
    when(() => settings.state).thenReturn(const SettingsState(locale: 'zh'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    GetIt.I.registerSingleton<TagTranslationRepository>(tags);
    GetIt.I.registerSingleton<SearchRepository>(search);
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings, child: const MaterialApp(home: SearchScreen())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '七尾ゆき');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(saved), findsNothing);
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.value =
        controller.value.copyWith(composing: const TextRange(start: 0, end: 4));
    final composing = controller.value;
    await tester.runAsync(() async {
      await tags.loadTranslations();
      await tags.refresh();
    });
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.value, composing);
    expect(find.text(saved), findsNothing);
    controller.value = composing.copyWith(composing: TextRange.empty);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text(saved), findsOneWidget);
    await tester.enterText(find.byType(TextField), '新しい名前');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text(saved), findsNothing);
    final before = controller.value;
    when(() => dio.get(any()))
        .thenAnswer((_) async => dictionary('新译名（新しい名前）'));
    await tester.runAsync(() async {
      await tags.refresh();
      // The compute completion notifies in the real async zone, where the
      // existing suggestion debounce timer also needs real time to elapse.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text(saved), findsOneWidget);
    expect(controller.value, before);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
