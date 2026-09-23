import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/tag_translation_repository.dart';
import 'package:oviewer/screens/search/search_screen.dart';

class MockSearch extends Mock implements SearchRepository {}

class MockTags extends Mock implements TagTranslationRepository {}

class MockSettings extends Mock implements SettingsBloc {}

class MockFavorites extends Mock implements FavoritesRepository {}

void main() {
  setUpAll(() => registerFallbackValue(const SearchFilter()));
  tearDown(() => GetIt.I.reset());

  testWidgets('a recalled alias query submits and shows search results',
      (tester) async {
    const query = r'artist:"moxueyin | jiuxueran$"';
    final search = MockSearch();
    final settings = MockSettings();
    final favorites = MockFavorites();
    when(() => search.getSearchHistory()).thenReturn([query]);
    when(() => search.addSearchHistory(any())).thenAnswer((_) async {});
    when(() => search.search(any())).thenAnswer((_) async =>
        const SearchResult(galleries: [], totalPages: 0, totalResults: 0));
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    GetIt.I.registerSingleton<SearchRepository>(search);
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
      value: settings,
      child: const MaterialApp(home: SearchScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'jiuxueran');
    await tester.pump();
    await tester.tap(find.text(query));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Recent Searches'), findsNothing);
    verify(() => search.search(const SearchFilter(keyword: query))).called(1);
    verify(() => search.addSearchHistory(query)).called(1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final dictionaryAvailable in [true, false]) {
    testWidgets(
        'matching history precedes tags and fills the input '
        '(dictionary available: $dictionaryAvailable)', (tester) async {
      final search = MockSearch();
      final settings = MockSettings();
      var history = [
        'unrelated',
        r'artist:"nanao yukiji$" language:chinese',
        r'artist:"nanao yukiji$"',
      ];
      when(() => search.getSearchHistory()).thenAnswer((_) => history);
      when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      GetIt.I.registerSingleton<SearchRepository>(search);
      if (dictionaryAvailable) {
        final tags = MockTags();
        when(() => tags.searchByTranslation(any())).thenReturn([
          const TagSearchResult(
              namespace: 'artist', key: 'nanao yukiji', translation: '七尾雪路'),
          const TagSearchResult(
              namespace: 'artist',
              key: 'nanao yukiji extra',
              translation: 'Other match'),
        ]);
        GetIt.I.registerSingleton<TagTranslationRepository>(tags);
      }
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings,
        child: const MaterialApp(home: SearchScreen()),
      ));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.enterText(field, 'nanao');
      await tester.pump();
      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data)
          .toList();
      expect(titles, [
        history[1],
        history[2],
        if (dictionaryAvailable) 'artist:nanao yukiji extra',
      ]);
      // The canonical tag already present in history must not appear twice.
      expect(find.text('artist:nanao yukiji'), findsNothing);
      await tester.tap(find.text(history[1]));
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.text, history[1]);
      expect(controller.selection.extentOffset, history[1].length);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      // Read fresh history, including changes made elsewhere in the app.
      history = [];
      await tester.enterText(field, 'nanao');
      await tester.pump();
      expect(find.byIcon(Icons.history), findsNothing);
      if (dictionaryAvailable) {
        expect(find.text('artist:nanao yukiji'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
      'tapping a multiword suggestion replaces its phrase; caret edits '
      'preserve other search terms', (tester) async {
    final search = MockSearch();
    final tags = MockTags();
    final settings = MockSettings();
    when(() => search.getSearchHistory()).thenReturn([]);
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    when(() => tags.searchByTranslation(any())).thenAnswer((call) {
      final query = call.positionalArguments.single as String;
      return 'nanao yukiji'.contains(query)
          ? [
              const TagSearchResult(
                namespace: 'artist',
                key: 'nanao yukiji',
                translation: '七尾雪路',
              )
            ]
          : [];
    });
    GetIt.I.registerSingleton<SearchRepository>(search);
    GetIt.I.registerSingleton<TagTranslationRepository>(tags);
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
      value: settings,
      child: const MaterialApp(home: SearchScreen()),
    ));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.enterText(field, 'nanao yukiji');
    await tester.pump();
    await tester.tap(find.text('artist:nanao yukiji'));
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    expect(controller.text, 'artist:"nanao yukiji\$" ');
    expect(controller.selection.extentOffset, controller.text.length);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

    const text = 'language:chinese other nanao yukiji language:english';
    await tester.enterText(field, text);
    await tester.pump();
    expect(find.text('artist:nanao yukiji'), findsNothing);
    // Moving the caret alone must refresh both suggestions and their range.
    controller.selection =
        TextSelection.collapsed(offset: text.indexOf(' language:english'));
    await tester.pump();
    await tester.tap(find.text('artist:nanao yukiji'));
    await tester.pump();
    expect(controller.text,
        'language:chinese other artist:"nanao yukiji\$" language:english');
    expect(controller.selection.extentOffset,
        'language:chinese other artist:"nanao yukiji\$"'.length);
    expect(find.text('artist:nanao yukiji'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
