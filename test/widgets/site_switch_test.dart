import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/site_mode_tile.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class Settings extends Mock implements SettingsRepository {}

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences() : super.empty();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.use_exhentai' && value == true) return false;
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppConstants.onSiteChanged = null;
    AppConstants.useExHentai = false;
  });
  tearDown(() {
    AppConstants.onSiteChanged = null;
    AppConstants.useExHentai = false;
  });

  test('platform write rejection restores both preferences memory and disk',
      () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = FailingPreferences();
    final storage = LocalStorage();
    await storage.init();
    await expectLater(storage.setUseExHentai(true), throwsStateError);
    expect(storage.getUseExHentai(), false);
    await storage.prefs.reload();
    expect(storage.getUseExHentai(), false);
  });

  for (final language in ['zh', 'en']) {
    testWidgets('site feedback precedes cookies and persistence ($language)',
        (tester) async {
      final repository = Settings();
      final cookies = Completer<void>();
      final save = Completer<void>();
      var syncs = 0;
      var commits = 0;
      when(() => repository.setUseExHentai(true))
          .thenAnswer((_) => save.future);
      final bloc = SettingsBloc(repository,
          initialState: SettingsState(locale: language),
          sessionRevision: () => 1,
          syncSiteCookies: () {
            syncs++;
            return cookies.future;
          });
      AppConstants.onSiteChanged = () => commits++;
      addTearDown(bloc.close);
      await tester.pumpWidget(BlocProvider.value(
          value: bloc,
          child: const MaterialApp(home: Scaffold(body: SiteModeTile()))));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, true);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.text('ExHentai'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(bloc.state.useExHentai, false);
      expect(AppConstants.useExHentai, false);
      expect(commits, 0);
      verifyNever(() => repository.setUseExHentai(any()));
      bloc.add(const ToggleSiteMode(false));
      bloc.add(const ToggleSiteMode(true));
      await tester.pump();
      expect(syncs, 1);
      cookies.complete();
      await tester.pump();
      expect(bloc.state.switchingSite, true);
      expect(commits, 0);
      save.complete();
      await tester.pumpAndSettle();
      expect(bloc.state.useExHentai, true);
      expect(AppConstants.useExHentai, true);
      expect(commits, 1);
      expect(bloc.state.pendingSite, isNull);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final failure in [
    'cookies',
    'storage',
    'session-before-save',
    'session-during-save'
  ]) {
    test('failed preparation retains site and permits retry: $failure',
        () async {
      final repository = Settings();
      var revision = 0;
      var fail = true;
      final writes = <bool>[];
      when(() => repository.setUseExHentai(any())).thenAnswer((call) async {
        final value = call.positionalArguments.single as bool;
        writes.add(value);
        if (fail && failure == 'storage') throw StateError('write failure');
        if (fail && failure == 'session-during-save' && value) revision++;
      });
      final bloc = SettingsBloc(repository,
          sessionRevision: () => revision,
          syncSiteCookies: () async {
            if (!fail) return;
            if (failure == 'cookies') throw StateError('cookie failure');
            if (failure == 'session-before-save') revision++;
          });
      addTearDown(bloc.close);
      final failed = bloc.stream.firstWhere((s) => s.siteSwitchError != null);
      bloc.add(const ToggleSiteMode(true));
      await failed;
      expect(bloc.state.pendingSite, isNull);
      expect(bloc.state.useExHentai, false);
      expect(AppConstants.useExHentai, false);
      if (failure == 'session-during-save') expect(writes, [true, false]);
      fail = false;
      final done = bloc.stream.firstWhere((s) => s.useExHentai);
      bloc.add(const ToggleSiteMode(true));
      await done;
      expect(bloc.state.siteSwitchError, isNull);
    });
  }

  testWidgets(
      'leaving the settings tile does not interrupt app-owned switching',
      (tester) async {
    final repository = Settings();
    final cookies = Completer<void>();
    when(() => repository.setUseExHentai(true)).thenAnswer((_) async {});
    final bloc = SettingsBloc(repository,
        sessionRevision: () => 0, syncSiteCookies: () => cookies.future);
    addTearDown(bloc.close);
    await tester.pumpWidget(BlocProvider.value(
        value: bloc,
        child: const MaterialApp(home: Scaffold(body: SiteModeTile()))));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    cookies.complete();
    await tester.pumpAndSettle();
    expect(bloc.state.useExHentai, true);
    expect(tester.takeException(), isNull);
  });
}
