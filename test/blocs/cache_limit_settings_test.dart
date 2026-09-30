import 'dart:async';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockRepository extends Mock implements SettingsRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('every option persists and reaches the running cache controller',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final applied = <int>[];
    final bloc =
        SettingsBloc(SettingsRepository(storage), applyCacheLimit: (mb) async {
      applied.add(mb);
    });
    for (final mb in [100, 200, 500, 1000, 2000]) {
      final complete = Completer<void>();
      bloc.add(UpdateCacheLimit(mb, completer: complete));
      await complete.future;
      expect(bloc.state.cacheLimitMB, mb);
      final restarted = LocalStorage();
      await restarted.init();
      expect(restarted.getCacheLimit(), mb);
    }
    expect(applied, [100, 200, 500, 1000, 2000]);
    await bloc.close();
  });
  test('cleanup failure keeps confirmed saved limit and allows a later retry',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    var fail = true;
    final bloc =
        SettingsBloc(SettingsRepository(storage), applyCacheLimit: (_) async {
      if (fail) throw StateError('busy');
    });
    final failed = Completer<void>();
    final check = expectLater(failed.future, throwsStateError);
    bloc.add(UpdateCacheLimit(100, completer: failed));
    await check;
    expect(storage.getCacheLimit(), 100);
    expect(bloc.state.cacheLimitMB, 100);
    fail = false;
    final retry = Completer<void>();
    bloc.add(UpdateCacheLimit(100, completer: retry));
    await retry.future;
    await bloc.close();
  });
  test('invalid values cannot change the applied limit', () async {
    final repository = MockRepository();
    var applied = false;
    final bloc = SettingsBloc(repository, applyCacheLimit: (_) async {
      applied = true;
    });
    final complete = Completer<void>();
    final check = expectLater(complete.future, throwsArgumentError);
    bloc.add(UpdateCacheLimit(0, completer: complete));
    await check;
    expect(applied, isFalse);
    expect(bloc.state.cacheLimitMB, 500);
    verifyNever(() => repository.setCacheLimit(any()));
    await bloc.close();
  });
  test('persistence failure cannot apply a new limit', () async {
    final repository = MockRepository();
    when(() => repository.setCacheLimit(100))
        .thenThrow(StateError('storage failed'));
    var applied = false;
    final bloc = SettingsBloc(repository, applyCacheLimit: (_) async {
      applied = true;
    });
    final complete = Completer<void>();
    final check = expectLater(complete.future, throwsStateError);
    bloc.add(UpdateCacheLimit(100, completer: complete));
    await check;
    expect(applied, isFalse);
    expect(bloc.state.cacheLimitMB, 500);
    await bloc.close();
  });
}
