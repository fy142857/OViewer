import 'dart:async';
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/network/dio_client.dart';

class HistoryDio extends Mock implements DioClient {}

class MockSearch extends Mock implements SearchRepository {}

class MockTags extends Mock implements TagTranslationRepository {}

void stubPhrases(MockTags tags) {
  when(() => tags.searchPhrases(any())).thenAnswer((call) {
    final queries = call.positionalArguments.single as List<String>;
    for (var i = 0; i < queries.length; i++) {
      final matches = tags.searchByTranslation(queries[i]);
      if (matches.isNotEmpty) return TagPhraseMatch(i, matches);
    }
    return null;
  });
}

class MockSettings extends Mock implements SettingsBloc {}

class MockFavorites extends Mock implements FavoritesRepository {}

void main() {
  setUpAll(() => registerFallbackValue(const SearchFilter()));
  tearDown(() => GetIt.I.reset());

  for (final inputOnly in [false, true]) {
    testWidgets(
        'deleting history keeps suggestions mounted on every frame ($inputOnly)',
        (tester) async {
      final search = MockSearch();
      final tags = MockTags();
      final settings = MockSettings();
      final history = ['solo one', 'solo two'];
      final saved = Completer<void>();
      when(() => search.getSearchHistory()).thenAnswer((_) => [...history]);
      when(() => search.removeSearchHistory('solo one')).thenAnswer((_) async {
        await saved.future;
        history.remove('solo one');
      });
      when(() => tags.searchByTranslation(any())).thenReturn([
        const TagSearchResult(namespace: 'male', key: 'solo', translation: '独自')
      ]);
      stubPhrases(tags);
      when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      GetIt.I.registerSingleton<SearchRepository>(search);
      GetIt.I.registerSingleton<TagTranslationRepository>(tags);
      GetIt.I.registerSingleton<FavoritesRepository>(MockFavorites());
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(home: SearchScreen(inputOnly: inputOnly))));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'solo');
      await tester.pumpAndSettle();
      final list = tester.element(find.byType(ListView));
      await tester.longPress(find.text('solo one'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('solo one'), findsOneWidget);
      expect(find.text('male:solo'), findsOneWidget);
      saved.complete();
      // Inspect intermediate frames, not just the settled result: the old
      // implementation briefly replaced this list with full search history.
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('male:solo'), findsOneWidget);
        expect(find.text('solo two'), findsOneWidget);
        expect(tester.element(find.byType(ListView)), same(list));
        expect(find.text('Clear'), findsNothing);
      }
      expect(find.text('solo one'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'solo');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  for (final inputOnly in [false, true]) {
    testWidgets('long press deletes matching history persistently ($inputOnly)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = LocalStorage();
      await storage.init();
      final search = SearchRepository(HistoryDio(), storage);
      await search.addSearchHistory(r'male:solo$');
      await search.addSearchHistory(r'female:elf$ male:solo$');
      final settings = MockSettings();
      when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      GetIt.I.registerSingleton<SearchRepository>(search);
      GetIt.I.registerSingleton<FavoritesRepository>(MockFavorites());
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(home: SearchScreen(inputOnly: inputOnly))));
      await tester.pumpAndSettle();
      const query = r'female:elf$ male:so';
      await tester.enterText(find.byType(TextField), query);
      await tester.pumpAndSettle();
      expect(find.text(r'male:solo$'), findsOneWidget);
      await tester.longPress(find.text(r'male:solo$'));
      await tester.pumpAndSettle();
      expect(find.text(r'male:solo$'), findsNothing);
      expect(find.text(r'female:elf$ male:solo$'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          query);
      final reopened = LocalStorage();
      await reopened.init();
      expect(reopened.getSearchHistory(), [r'female:elf$ male:solo$']);
      await tester.longPress(find.text(r'female:elf$ male:solo$'));
      await tester.pumpAndSettle();
      expect(find.text(r'female:elf$ male:solo$'), findsNothing);
      expect(search.getSearchHistory(), isEmpty);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.history), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('later tag history offers standalone and combined entries',
      (tester) async {
    final search = MockSearch();
    final settings = MockSettings();
    when(() => search.getSearchHistory())
        .thenReturn([r'male:solo$', r'female:elf$ male:solo$']);
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    GetIt.I.registerSingleton<SearchRepository>(search);
    GetIt.I.registerSingleton<FavoritesRepository>(MockFavorites());
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings,
        child: const MaterialApp(home: SearchScreen(inputOnly: true))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), r'female:elf$ male:so');
    await tester.pumpAndSettle();
    expect(find.text(r'male:solo$'), findsOneWidget);
    expect(find.text(r'female:elf$ male:solo$'), findsOneWidget);
    await tester.tap(find.text(r'male:solo$'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        r'female:elf$ male:solo$ ');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('long search history builds on demand and recalls older entries',
      (tester) async {
    final search = MockSearch();
    final settings = MockSettings();
    final favorites = MockFavorites();
    final history = List.generate(1000, (i) => 'saved query $i');
    when(() => search.getSearchHistory()).thenReturn(history);
    when(() => search.addSearchHistory(any())).thenAnswer((_) async {});
    when(() => search.search(any())).thenAnswer((_) async =>
        const SearchResult(galleries: [], totalPages: 0, totalResults: 0));
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    GetIt.I.registerSingleton<SearchRepository>(search);
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings, child: const MaterialApp(home: SearchScreen())));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    await tester.scrollUntilVisible(find.text('saved query 40'), 400,
        scrollable: find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable)));
    await tester.tap(find.text('saved query 40'));
    await tester.pumpAndSettle();
    verify(() => search.addSearchHistory('saved query 40')).called(1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('caret/selection bursts debounce; submit and dispose cancel work',
      (tester) async {
    final search = MockSearch();
    final tags = MockTags();
    final settings = MockSettings();
    final favorites = MockFavorites();
    when(() => search.getSearchHistory()).thenReturn([]);
    when(() => search.addSearchHistory(any())).thenAnswer((_) async {});
    when(() => search.search(any())).thenAnswer((_) async =>
        const SearchResult(galleries: [], totalPages: 0, totalResults: 0));
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    final phraseCalls = <List<String>>[];
    var selectionCalls = 0;
    when(() => tags.searchPhrases(any())).thenAnswer((call) {
      phraseCalls.add(call.positionalArguments.single as List<String>);
      return null;
    });
    when(() => tags.searchByTranslation(any())).thenAnswer((_) {
      selectionCalls++;
      return [];
    });
    GetIt.I.registerSingleton<SearchRepository>(search);
    GetIt.I.registerSingleton<TagTranslationRepository>(tags);
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings, child: const MaterialApp(home: SearchScreen())));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    final text = List.filled(48, 'unknownword').join(' ');
    await tester.enterText(field, text);
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    final inputWidget = tester.widget<TextField>(field);
    for (var i = 0; i < 10; i++) {
      controller.selection =
          TextSelection.collapsed(offset: text.length - i % 2);
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(phraseCalls, isEmpty);
    await tester.pump(const Duration(milliseconds: 160));
    expect(phraseCalls, hasLength(1));
    // Updating the candidate region must not rebuild the text field.
    expect(identical(tester.widget<TextField>(field), inputWidget), isTrue);
    for (var end = 10; end < 20; end++) {
      controller.selection = TextSelection(baseOffset: 0, extentOffset: end);
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(selectionCalls, 0);
    await tester.pump(const Duration(milliseconds: 160));
    expect(selectionCalls, 1);
    controller.value = controller.value
        .copyWith(composing: const TextRange(start: 0, end: 19));
    await tester.pump(const Duration(milliseconds: 200));
    expect(selectionCalls, 1);
    controller.value = TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: text.length));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 200));
    expect(phraseCalls, hasLength(1));
    await tester.tap(field);
    await tester.enterText(field, 'new pending input');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(phraseCalls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

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
    await tester.pump(const Duration(milliseconds: 160));
    await tester.tap(find.text(query));
    await tester.pump(const Duration(milliseconds: 160));
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
        stubPhrases(tags);
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
      await tester.pump(const Duration(milliseconds: 160));
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
      await tester.pump(const Duration(milliseconds: 160));
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.text, '${history[1]} ');
      expect(controller.selection.extentOffset, history[1].length + 1);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      // Read fresh history, including changes made elsewhere in the app.
      history = [];
      await tester.enterText(field, 'nanao');
      await tester.pump(const Duration(milliseconds: 160));
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
    stubPhrases(tags);
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
    await tester.pump(const Duration(milliseconds: 160));
    final oldTap = tester
        .widget<ListTile>(find.widgetWithText(ListTile, 'artist:nanao yukiji'))
        .onTap!;
    final editing = tester.widget<TextField>(field).controller!;
    editing.selection = const TextSelection.collapsed(offset: 0);
    oldTap();
    expect(editing.text, 'nanao yukiji');
    editing.selection = TextSelection.collapsed(offset: editing.text.length);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.tap(find.text('artist:nanao yukiji'));
    await tester.pump(const Duration(milliseconds: 160));
    final controller = tester.widget<TextField>(field).controller!;
    expect(controller.text, 'artist:"nanao yukiji\$" ');
    expect(controller.selection.extentOffset, controller.text.length);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

    const text = 'language:chinese other nanao yukiji language:english';
    await tester.enterText(field, text);
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.text('artist:nanao yukiji'), findsNothing);
    // Moving the caret alone must refresh both suggestions and their range.
    controller.selection =
        TextSelection.collapsed(offset: text.indexOf(' language:english'));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.tap(find.text('artist:nanao yukiji'));
    await tester.pump(const Duration(milliseconds: 160));
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
