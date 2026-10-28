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
  testWidgets(
      'selected last option opens downward and scrolls in limited height',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final repository = SettingsRepository(storage);
    final bloc = SettingsBloc(repository,
        initialState: SettingsBloc.readSaved(repository).copyWith(
            readingMode: 2,
            pageLayout: ReaderPageLayout.doublePage,
            spreadAlignment: ReaderSpreadAlignment.height));
    addTearDown(bloc.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 240);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: MaterialApp(
            home: Scaffold(
                appBar: AppBar(actions: const [ReaderSettingsButton()])))));
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    final selector = find.byKey(const ValueKey('reader-spread-alignment'));
    expect(ModalRoute.of(tester.element(selector))!.transitionDuration,
        const Duration(milliseconds: 150));
    await tester.ensureVisible(selector);
    final top = tester.getTopLeft(selector).dy;
    await tester.tap(selector);
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey(
        'reader-spread-alignment-option-ReaderSpreadAlignment.width'));
    final last = find.byKey(const ValueKey(
        'reader-spread-alignment-option-ReaderSpreadAlignment.height'));
    expect(ModalRoute.of(tester.element(first))!.transitionDuration,
        const Duration(milliseconds: 150));
    expect(tester.getTopLeft(first).dy, closeTo(top + 8, 0.1));
    expect(
        tester.getTopLeft(last).dy, greaterThan(tester.getTopLeft(first).dy));
    final scroll = find
        .ancestor(of: first, matching: find.byType(SingleChildScrollView))
        .first;
    expect(tester.getBottomLeft(scroll).dy, lessThanOrEqualTo(232.1));
    await tester.drag(scroll, const Offset(0, -100));
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(repository.getReaderSpreadAlignment(), ReaderSpreadAlignment.height);
    expect(find.byType(ReaderSettingsOptions), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      expect(tester.getSize(find.byType(ReaderSettingsOptions)).width,
          lessThanOrEqualTo(228));
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
      final selectorTop =
          tester.getTopLeft(find.byKey(const ValueKey('reader-direction'))).dy;
      await tester.tap(find.byKey(const ValueKey('reader-direction')));
      await tester.pumpAndSettle();
      expect(
          tester
              .getSize(find.byKey(const ValueKey('reader-direction-option-0')))
              .width,
          tester.getSize(find.byKey(const ValueKey('reader-direction'))).width);
      expect(
          tester
              .getTopLeft(
                  find.byKey(const ValueKey('reader-direction-option-0')))
              .dy,
          closeTo(selectorTop + 8, 0.1));
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
      expect(
          find.byKey(const ValueKey('reader-spread-alignment')), findsNothing);
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-spread-alignment')),
          findsOneWidget);
      final alignmentTop = tester
          .getTopLeft(find.byKey(const ValueKey('reader-spread-alignment')))
          .dy;
      await tester.tap(find.byKey(const ValueKey('reader-spread-alignment')));
      await tester.pumpAndSettle();
      expect(
          tester
              .getTopLeft(find.byKey(const ValueKey(
                  'reader-spread-alignment-option-ReaderSpreadAlignment.width')))
              .dy,
          closeTo(alignmentTop + 8, 0.1));
      await tester.tap(find.text(locale == 'zh' ? '按高度对齐' : 'Fit height').last);
      await tester.pumpAndSettle();
      expect(
          repository.getReaderSpreadAlignment(), ReaderSpreadAlignment.height);
      await tester.tap(find.byKey(const ValueKey('reader-page-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '单页' : 'Single page').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-spread-alignment')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-page-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '双页' : 'Double page').last);
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('reader-spread-alignment')),
              matching: find.text(locale == 'zh' ? '按高度对齐' : 'Fit height')),
          findsOneWidget);

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
      await tester.tapAt(const Offset(10, 350));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderSettingsOptions), findsNothing);
      expect(SettingsBloc.readSaved(repository).pageLayout,
          ReaderPageLayout.doublePage);
      expect(SettingsBloc.readSaved(repository).readingMode, 1);
    });
  }
}
