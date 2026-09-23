import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/tag_translation_repository.dart';
import 'package:oviewer/screens/search/search_screen.dart';

class MockSearch extends Mock implements SearchRepository {}

class MockTags extends Mock implements TagTranslationRepository {}

class MockSettings extends Mock implements SettingsBloc {}

void main() {
  tearDown(() => GetIt.I.reset());

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
