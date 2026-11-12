import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/floating_back_settings.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';

class FailedStore extends InMemorySharedPreferencesStore {
  FailedStore() : super.withData({});
  @override
  Future<bool> setValue(String type, String key, Object value) async => false;
}

class GatedSettings extends SettingsRepository {
  final started = Completer<void>(), release = Completer<void>();
  int saves = 0;
  GatedSettings(super.storage);
  @override
  Future<void> setFloatingBack(FloatingBackSettings value) async {
    if (++saves == 1) {
      started.complete();
      await release.future;
    }
    await super.setFloatingBack(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final raw in [
    null,
    true,
    42,
    'broken',
    '{}',
    '[]',
    '{"size":99,"x":-1,"y":2}'
  ]) {
    test('missing or malformed floating settings use enabled defaults: $raw',
        () async {
      SharedPreferences.setMockInitialValues(
          {if (raw != null) 'floating_back': raw});
      final storage = LocalStorage();
      await storage.init();
      expect(storage.getFloatingBack(), const FloatingBackSettings());
    });
  }
  test('patches serialize and survive restart without losing other fields',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final repo = GatedSettings(storage);
    final bloc = SettingsBloc(repo, initialState: SettingsBloc.readSaved(repo));
    addTearDown(bloc.close);
    final a = Completer<void>(), b = Completer<void>(), c = Completer<void>();
    bloc.add(UpdateFloatingBack(a, enabled: false));
    await repo.started.future;
    bloc.add(UpdateFloatingBack(b, size: 72));
    bloc.add(UpdateFloatingBack(c, x: .25, y: .4));
    await Future<void>.delayed(Duration.zero);
    expect(repo.saves, 1);
    repo.release.complete();
    await Future.wait([a.future, b.future, c.future]);
    const expected =
        FloatingBackSettings(enabled: false, size: 72, x: .25, y: .4);
    expect(bloc.state.floatingBack, expected);
    SharedPreferences.resetStatic();
    final restored = LocalStorage();
    await restored.init();
    expect(SettingsBloc.readSaved(SettingsRepository(restored)).floatingBack,
        expected);
  });
  test('failed saves preserve confirmed settings and later retry succeeds',
      () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = FailedStore();
    SharedPreferences.resetStatic();
    final storage = LocalStorage();
    await storage.init();
    final bloc = SettingsBloc(SettingsRepository(storage),
        initialState: SettingsBloc.readSaved(SettingsRepository(storage)));
    addTearDown(bloc.close);
    final done = Completer<void>();
    final failed = expectLater(done.future, throwsStateError);
    bloc.add(UpdateFloatingBack(done, enabled: false, size: 64));
    await failed;
    expect(bloc.state.floatingBack, const FloatingBackSettings());
    expect(storage.getFloatingBack(), const FloatingBackSettings());
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.withData({});
    final retry = Completer<void>();
    bloc.add(UpdateFloatingBack(retry, size: 32));
    await retry.future;
    expect(bloc.state.floatingBack.size, 32);
  });
  test('non-finite or out-of-range updates cannot enter saved state', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    for (final value in [
      const FloatingBackSettings(size: 0),
      const FloatingBackSettings(x: 2),
      FloatingBackSettings(y: double.nan)
    ]) {
      await expectLater(storage.setFloatingBack(value), throwsArgumentError);
      expect(storage.getFloatingBack(), const FloatingBackSettings());
    }
  });
}
