import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/reader_settings_dialog.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets(
        'two selectors save global preferences while panel stays open ($locale)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = LocalStorage();
      await storage.init();
      final repository = SettingsRepository(storage);
      final bloc = SettingsBloc(repository,
          initialState:
              SettingsBloc.readSaved(repository).copyWith(locale: locale));
      addTearDown(bloc.close);
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(BlocProvider.value(
          value: bloc,
          child: MaterialApp(
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () => showReaderSettings(context),
                          child: const Text('Open')))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-page-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '双页' : 'Double page').last);
      await tester.pumpAndSettle();
      expect(bloc.state.pageLayout, ReaderPageLayout.doublePage);
      expect(repository.getReaderPageLayout(), ReaderPageLayout.doublePage);
      expect(find.byType(ReaderSettingsDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-direction')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.text(locale == 'zh' ? '从右到左' : 'Right to Left').last);
      await tester.pumpAndSettle();
      expect(repository.getReadingMode(), 1);
      expect(repository.getReaderPageLayout(), ReaderPageLayout.doublePage);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(locale == 'zh' ? '关闭' : 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsDialog), findsNothing);
      expect(SettingsBloc.readSaved(repository).pageLayout,
          ReaderPageLayout.doublePage);
      expect(SettingsBloc.readSaved(repository).readingMode, 1);
    });
  }
}
