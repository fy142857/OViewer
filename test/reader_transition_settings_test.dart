import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/reader_settings_menu.dart';
import 'package:oviewer/widgets/reader_transition_setting.dart';

class _FailedStore extends InMemorySharedPreferencesStore {
  _FailedStore() : super.withData({});
  @override
  Future<bool> setValue(String type, String key, Object value) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final saved in [null, 'bad', 1, false, 'none', 'slide']) {
    test('transition preference defaults and persists: $saved', () async {
      SharedPreferences.setMockInitialValues(
          {if (saved != null) 'reader_page_transition': saved});
      final storage = LocalStorage();
      await storage.init();
      final repo = SettingsRepository(storage);
      final expected = saved == 'none'
          ? ReaderPageTransition.none
          : ReaderPageTransition.slide;
      expect(repo.getReaderPageTransition(), expected);
      final bloc =
          SettingsBloc(repo, initialState: SettingsBloc.readSaved(repo));
      addTearDown(bloc.close);
      for (final value in ReaderPageTransition.values) {
        final done = Completer<void>();
        bloc.add(UpdateReaderPageTransition(value, done));
        await done.future;
        expect(bloc.state.pageTransition, value);
        SharedPreferences.resetStatic();
        final restored = LocalStorage();
        await restored.init();
        expect(restored.getReaderPageTransition(), value);
      }
    });
  }
  testWidgets('failed save preserves preference and shows error',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = _FailedStore();
    SharedPreferences.resetStatic();
    final storage = LocalStorage();
    await storage.init();
    final repo = SettingsRepository(storage);
    final bloc = SettingsBloc(repo, initialState: SettingsBloc.readSaved(repo));
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: const MaterialApp(
            home: Scaffold(body: ReaderTransitionSetting()))));
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无'));
    await tester.pumpAndSettle();
    expect(bloc.state.pageTransition, ReaderPageTransition.slide);
    expect(repo.getReaderPageTransition(), ReaderPageTransition.slide);
    expect(find.text('保存过渡动画设置失败，请重试'), findsOneWidget);
  });
  for (final locale in ['zh', 'en']) {
    testWidgets('both selectors sync, vertical menu hides only ($locale)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = LocalStorage();
      await storage.init();
      final repo = SettingsRepository(storage);
      final bloc = SettingsBloc(repo,
          initialState: SettingsBloc.readSaved(repo).copyWith(locale: locale));
      addTearDown(bloc.close);
      await tester.binding.setSurfaceSize(const Size(320, 650));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(BlocProvider.value(
          value: bloc,
          child: MaterialApp(
              builder: (context, child) => MediaQuery(
                  // Keep this fixture compatible with local Flutter 3.13.
                  // ignore: deprecated_member_use
                  data: MediaQuery.of(context).copyWith(textScaleFactor: 1.6),
                  child: child!),
              home: const Scaffold(
                  appBar: null,
                  body: Column(children: [
                    ReaderSettingsButton(),
                    ReaderTransitionSetting()
                  ])))));
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '无' : 'None'));
      await tester.pumpAndSettle();
      expect(bloc.state.pageTransition, ReaderPageTransition.none);
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-transition')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey(
          'reader-transition-option-ReaderPageTransition.slide')));
      await tester.pumpAndSettle();
      expect(bloc.state.pageTransition, ReaderPageTransition.slide);
      bloc.add(const UpdateReadingMode(2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-transition')), findsNothing);
      expect(find.byKey(const ValueKey('settings-reader-transition')),
          findsOneWidget);
      bloc.add(const UpdateReadingMode(0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-transition')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
