import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/reader_settings_menu.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets(
        'anchored menu conditionally shows alignment and saves global preferences ($locale)',
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
              home: Scaffold(
                  appBar: AppBar(actions: const [ReaderSettingsButton()])))));
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final anchor =
          tester.getRect(find.byKey(const ValueKey('reader-settings')));
      expect(tester.getTopLeft(find.byType(ReaderSettingsOptions)).dy,
          lessThan(anchor.bottom + 40));
      expect(
          find.byKey(const ValueKey('reader-spread-alignment')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-page-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '双页' : 'Double page').last);
      await tester.pumpAndSettle();
      expect(bloc.state.pageLayout, ReaderPageLayout.doublePage);
      expect(repository.getReaderPageLayout(), ReaderPageLayout.doublePage);
      expect(find.byType(ReaderSettingsOptions), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-direction')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.text(locale == 'zh' ? '从右到左' : 'Right to Left').last);
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reader-spread-alignment')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-direction')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.text(locale == 'zh' ? '垂直滚动' : 'Vertical Scroll').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-spread-alignment')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-spread-alignment')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.text(locale == 'zh' ? '按高度对齐' : 'Equal height').last);
      await tester.pumpAndSettle();
      expect(
          repository.getReaderSpreadAlignment(), ReaderSpreadAlignment.height);
      await tester.tap(find.byKey(const ValueKey('reader-page-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '单页' : 'Single page').last);
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reader-spread-alignment')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-page-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '双页' : 'Double page').last);
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<DropdownButtonFormField<ReaderSpreadAlignment>>(
                  find.byKey(const ValueKey('reader-spread-alignment')))
              .initialValue,
          ReaderSpreadAlignment.height);

      await tester.tap(find.byKey(const ValueKey('reader-direction')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.text(locale == 'zh' ? '从右到左' : 'Right to Left').last);
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('reader-spread-alignment')), findsNothing);
      expect(repository.getReadingMode(), 1);
      expect(repository.getReaderPageLayout(), ReaderPageLayout.doublePage);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(10, 550));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsOptions), findsNothing);
      expect(SettingsBloc.readSaved(repository).pageLayout,
          ReaderPageLayout.doublePage);
      expect(SettingsBloc.readSaved(repository).readingMode, 1);
    });
  }
}
