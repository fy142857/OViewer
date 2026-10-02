import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/gallery_tag.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/tag_translation_repository.dart';
import 'package:oviewer/screens/search/search_screen.dart';
import 'package:oviewer/widgets/tag_chip.dart';
import '../repositories/tag_translation_startup_test.dart'
    show MockDio, MemoryTags, dictionary;

class MockSearch extends Mock implements SearchRepository {}

class MockSettings extends Mock implements SettingsBloc {}

void main() {
  tearDown(() => GetIt.I.reset());
  testWidgets(
      'dictionary arrival refreshes visible tags and search without changing composition or selection',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final dio = MockDio();
    when(() => dio.get(any()))
        .thenAnswer((_) async => throw StateError('offline'));
    final tags = TagTranslationRepository(dio, storage,
        cache: MemoryTags(dictionary('译名')));
    final settings = MockSettings();
    when(() => settings.state).thenReturn(const SettingsState(locale: 'zh'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    final search = MockSearch();
    when(() => search.getSearchHistory()).thenReturn([]);
    GetIt.I.registerSingleton<TagTranslationRepository>(tags);
    GetIt.I.registerSingleton<SearchRepository>(search);
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings,
        child: const MaterialApp(
            home: Scaffold(
                body: Column(children: [
          TagChip(tag: GalleryTag(namespace: 'artist', key: 'key0')),
          Expanded(child: SearchScreen()),
        ])))));
    await tester.pumpAndSettle();
    expect(find.text('key0'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '译名');
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.value = const TextEditingValue(
        text: '译名',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2));
    final composing = controller.value;
    await tester.runAsync(tags.loadTranslations);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('译名0'), findsOneWidget);
    expect(controller.value, composing);
    expect(find.text('artist:key0'), findsNothing);
    controller.value = composing.copyWith(composing: TextRange.empty);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('artist:key0'), findsOneWidget);
    expect(controller.selection, composing.selection);
    await tester.pumpWidget(const SizedBox.shrink());
    tags.dispose();
  });
}
