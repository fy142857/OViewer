import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/search/search_screen.dart';

class MockSearch extends Mock implements SearchRepository {}

class MockSettings extends Mock implements SettingsRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

void main() {
  setUpAll(() => registerFallbackValue(const SearchFilter()));
  tearDown(() => GetIt.I.reset());
  for (final locale in ['zh', 'en']) {
    testWidgets(
        '$locale: portrait hint fits, input expands and results retain toggle',
        (tester) async {
      final search = MockSearch();
      final settings = MockSettings();
      final favorites = MockFavorites();
      when(() => search.getSearchHistory()).thenReturn([]);
      when(() => search.addSearchHistory(any())).thenAnswer((_) async {});
      when(() => search.search(any())).thenAnswer((_) async =>
          const SearchResult(galleries: [], totalPages: 0, totalResults: 0));
      when(() => settings.setLocale(any())).thenAnswer((_) async {});
      when(() => settings.setDisplayMode(any())).thenAnswer((_) async {});
      when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
      GetIt.I.registerSingleton<SearchRepository>(search);
      GetIt.I.registerSingleton<FavoritesRepository>(favorites);
      final bloc = SettingsBloc(settings)..add(UpdateLocale(locale));
      final scale = ValueNotifier(1.0);
      addTearDown(bloc.close);
      addTearDown(scale.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpWidget(BlocProvider.value(
          value: bloc,
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => ValueListenableBuilder<double>(
              valueListenable: scale,
              builder: (context, value, _) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaleFactor: value),
                  child: child!),
            ),
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => const SearchScreen())),
                        child: const Text('Open search')))),
          )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      final toggle = find.byKey(const ValueKey('search-view-toggle'));
      final normalFontSize =
          Theme.of(tester.element(field)).textTheme.bodyLarge!.fontSize!;
      final hint = locale == 'zh'
          ? '输入标题、作者、Tag、画廊gid、上传者...'
          : 'Enter title, author, Tag, gallery GID, uploader...';
      void expectCompleteHint() {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(hint));
        // A clipped/ellipsized last character has no laid-out selection box.
        final lastGlyph = paragraph.getBoxesForSelection(TextSelection(
            baseOffset: hint.length - 1, extentOffset: hint.length));
        expect(lastGlyph, isNotEmpty);
        expect(lastGlyph.last.right,
            lessThanOrEqualTo(paragraph.size.width + 0.01));
      }

      expect(toggle, findsNothing);
      expect(tester.getSize(find.byType(BackButton)).width, 48);
      expect(tester.getRect(field).left, 56);
      expect(tester.getRect(field).right, 352);
      for (final textScale in [1.0, 1.5]) {
        scale.value = textScale;
        for (final width in [320.0, 360.0, 390.0, 800.0, 1024.0]) {
          await tester.binding
              .setSurfaceSize(Size(width, width >= 800 ? 400 : 800));
          await tester.pumpAndSettle();
          expectCompleteHint();
          final fontSize =
              tester.widget<TextField>(field).decoration!.hintStyle!.fontSize!;
          expect(fontSize, lessThanOrEqualTo(normalFontSize));
          if (width == 1024 && textScale == 1) {
            expect(fontSize, normalFontSize);
          }
          expect(tester.takeException(), isNull);
        }
      }
      scale.value = 1;
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.enterText(field, 'normal query');
      await tester.pumpAndSettle();
      expect(
          tester.widget<EditableText>(find.byType(EditableText)).style.fontSize,
          normalFontSize);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      final resultWidth = tester.getSize(field).width;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(bloc.state.displayMode, 1);
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(toggle, findsNothing);
      expect(tester.getSize(field).width, greaterThan(resultWidth));
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expectCompleteHint();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Open search'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
