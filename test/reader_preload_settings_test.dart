import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/reader_preload_setting.dart';
import 'package:oviewer/widgets/reader_settings_menu.dart';

class _FailedStore extends InMemorySharedPreferencesStore {
  _FailedStore() : super.withData({'flutter.reader_preload_count': 3});
  @override
  Future<bool> setValue(String type, String key, Object value) async => false;
}

class _SlowSettings extends SettingsRepository {
  _SlowSettings(super.storage);
  final save = Completer<void>();
  int calls = 0;
  @override
  Future<void> setReaderPreloadCount(int value) {
    calls++;
    return save.future;
  }
}

Future<LocalStorage> storage() async {
  final result = LocalStorage();
  await result.init();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final saved in [null, -1, 0, 1, 3, 5, 6, '3', true]) {
    test('saved count $saved defaults safely and persists 1 through 5',
        () async {
      SharedPreferences.setMockInitialValues({
        if (saved != null) 'reader_preload_count': saved,
      });
      final repo = SettingsRepository(await storage());
      expect(repo.getReaderPreloadCount(),
          saved is int && saved >= 1 && saved <= 5 ? saved : 1);
      final bloc =
          SettingsBloc(repo, initialState: SettingsBloc.readSaved(repo));
      addTearDown(bloc.close);
      for (var n = 1; n <= 5; n++) {
        final done = Completer<void>();
        bloc.add(UpdateReaderPreloadCount(n, completer: done));
        await done.future;
        expect(bloc.state.preloadCount, n);
        SharedPreferences.resetStatic();
        expect(
            SettingsBloc.readSaved(SettingsRepository(await storage()))
                .preloadCount,
            n);
      }
      await expectLater(repo.setReaderPreloadCount(0), throwsArgumentError);
      await expectLater(repo.setReaderPreloadCount(6), throwsArgumentError);
      expect(repo.getReaderPreloadCount(), 5);
    });
  }

  test(
      'failed preference write preserves last confirmed value in memory and on disk',
      () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = _FailedStore();
    SharedPreferences.resetStatic();
    final prefs = await storage();
    expect(prefs.getReaderPreloadCount(), 3);
    await expectLater(prefs.setReaderPreloadCount(5), throwsStateError);
    expect(prefs.getReaderPreloadCount(), 3);
    SharedPreferences.resetStatic();
    expect((await storage()).getReaderPreloadCount(), 3);
  });

  for (final locale in ['zh', 'en']) {
    testWidgets('both entries share saved page/group count ($locale)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository(await storage());
      final bloc = SettingsBloc(repo,
          initialState: SettingsBloc.readSaved(repo).copyWith(locale: locale));
      addTearDown(bloc.close);
      await tester.pumpWidget(BlocProvider.value(
          value: bloc,
          child: MaterialApp(
              home: Scaffold(
            appBar: AppBar(actions: const [
              ReaderPreloadSetting(toolbar: true),
              ReaderSettingsButton(),
            ]),
            body: const ReaderPreloadSetting(),
          ))));
      expect(find.text(locale == 'zh' ? '预加载图片数量' : 'Image preload count'),
          findsOneWidget);
      expect(find.byIcon(Icons.autorenew), findsNWidgets(2));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('reader-preload-button')),
              matching: find.byType(Text)),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-preload-count')));
      await tester.pumpAndSettle();
      expect(find.byType(RadioListTile<int>), findsNWidgets(5));
      expect(
          tester
              .widgetList<RadioListTile<int>>(find.byType(RadioListTile<int>))
              .map((tile) => (tile.title! as Text).data),
          ['1', '2', '3', '4', '5']);
      await tester.tap(find.byKey(const ValueKey('reader-preload-option-5')));
      await tester.pumpAndSettle();
      expect(bloc.state.preloadCount, 5);
      bloc.add(const UpdateReaderPageLayout(ReaderPageLayout.doublePage));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('reader-preload-count')),
              matching: find.text(
                  locale == 'zh' ? '前后各 5 组' : '5 spreads before and after')),
          findsOneWidget);
      expect(
          tester
              .getCenter(find.byKey(const ValueKey('reader-preload-button')))
              .dx,
          lessThan(tester
              .getCenter(find.byKey(const ValueKey('reader-settings')))
              .dx));
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      final directionFontSize = tester
          .widget<Text>(find.descendant(
              of: find.byKey(const ValueKey('reader-direction')),
              matching: find.byType(Text)))
          .style!
          .fontSize;
      expect(
          find.descendant(
              of: find.byType(ReaderSettingsOptions),
              matching: find.byType(ReaderPreloadSetting)),
          findsNothing);
      await tester.tapAt(const Offset(10, 350));
      await tester.pumpAndSettle();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 240);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-preload-button')));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(
          find.byKey(const ValueKey('reader-preload-title')), findsOneWidget);
      final heading = find.byKey(const ValueKey('reader-preload-title'));
      final headingText =
          find.descendant(of: heading, matching: find.byType(Text));
      final headingIcon =
          find.descendant(of: heading, matching: find.byIcon(Icons.autorenew));
      expect(
          tester.widget<Text>(headingText).style!.fontSize, directionFontSize);
      expect(tester.getCenter(headingIcon).dx,
          lessThan(tester.getCenter(headingText).dx));
      expect(tester.getSize(heading).width, lessThanOrEqualTo(260));
      expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('reader-preload-title')))
              .dy,
          greaterThanOrEqualTo(tester
              .getBottomLeft(
                  find.byKey(const ValueKey('reader-preload-button')))
              .dy));
      for (var n = 1; n <= 5; n++) {
        expect(
            find.descendant(
                of: find.byKey(ValueKey('reader-preload-option-$n')),
                matching: find.text(locale == 'zh'
                    ? '前后各 $n 组'
                    : '$n ${n == 1 ? 'spread' : 'spreads'} before and after')),
            findsOneWidget);
      }
      final last = find.byKey(const ValueKey('reader-preload-option-5'));
      await tester.ensureVisible(last);
      expect(find.descendant(of: last, matching: find.byIcon(Icons.check)),
          findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const ValueKey('reader-preload-option-1')));
      await tester.tap(find.byKey(const ValueKey('reader-preload-option-1')));
      await tester.pumpAndSettle();
      expect(bloc.state.preloadCount, 1);
      expect(repo.getReaderPreloadCount(), 1);
      expect(bloc.state.pageLayout, ReaderPageLayout.doublePage);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'pending save blocks both entries; failure keeps count and displays error',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = _SlowSettings(await storage());
    final bloc =
        SettingsBloc(repo, initialState: const SettingsState(preloadCount: 3));
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: const MaterialApp(
            home: Scaffold(
                body: Column(children: [
          ReaderPreloadSetting(),
          ReaderPreloadSetting(toolbar: true),
        ])))));
    await tester.tap(find.byKey(const ValueKey('reader-preload-count')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-preload-option-5')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(bloc.state.savingPreloadCount, true);
    expect(bloc.state.preloadCount, 3);
    expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .every((tile) => !tile.enabled),
        true);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(const ValueKey('reader-preload-button')))
            .onPressed,
        isNull);
    final repeated = Completer<void>();
    bloc.add(UpdateReaderPreloadCount(1, completer: repeated));
    await tester.pump();
    expect(repeated.isCompleted, true);
    expect(repo.calls, 1);
    repo.save.completeError(StateError('test save failed'));
    await tester.pumpAndSettle();
    expect(bloc.state.preloadCount, 3);
    expect(bloc.state.savingPreloadCount, false);
    expect(find.text('预加载图片数量保存失败，请重试'), findsOneWidget);
  });
}
