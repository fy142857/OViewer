import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/core/router/route_observer.dart';
import 'package:oviewer/core/services/reader_volume_keys.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/reader_volume_setting.dart';

class _FailedStore extends InMemorySharedPreferencesStore {
  _FailedStore() : super.withData({});
  @override
  Future<bool> setValue(String type, String key, Object value) async => false;
}

Future<void> turn(int delta) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
          ReaderVolumeKeys.channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall('turn', delta)),
          (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  for (final initial in [null, false, true, 'true', 1]) {
    test('volume preference safely restores and persists: $initial', () async {
      SharedPreferences.setMockInitialValues(
          {if (initial != null) 'reader_volume_keys': initial});
      final storage = LocalStorage();
      await storage.init();
      final repo = SettingsRepository(storage);
      expect(repo.getReaderVolumeKeys(), initial == true);
      final bloc =
          SettingsBloc(repo, initialState: SettingsBloc.readSaved(repo));
      addTearDown(bloc.close);
      for (final enabled in [true, false]) {
        final done = Completer<void>();
        bloc.add(UpdateReaderVolumeKeys(enabled, done));
        await done.future;
        expect(bloc.state.volumeKeys, enabled);
        SharedPreferences.resetStatic();
        final restored = LocalStorage();
        await restored.init();
        expect(restored.getReaderVolumeKeys(), enabled);
      }
    });
  }
  testWidgets('failed save keeps the old setting and shows a retry hint',
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
        child: const MaterialApp(home: Scaffold(body: ReaderVolumeSetting()))));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(bloc.state.volumeKeys, false);
    expect(repo.getReaderVolumeKeys(), false);
    expect(find.text('音量键设置保存失败，请重试'), findsOneWidget);
  });
  testWidgets('Android selectors share saved state; iOS hides both',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final repo = SettingsRepository(storage);
    final bloc = SettingsBloc(repo, initialState: SettingsBloc.readSaved(repo));
    addTearDown(bloc.close);
    Widget app() => BlocProvider.value(
        value: bloc,
        child: const MaterialApp(
            home: Scaffold(
                body: Column(children: [
          ReaderVolumeSetting(),
          SizedBox(width: 240, child: ReaderVolumeSetting(inReader: true))
        ]))));
    await tester.pumpWidget(app());
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(tester.widgetList<Switch>(find.byType(Switch)).every((s) => s.value),
        true);
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(bloc.state.volumeKeys, false);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    expect(find.byType(Switch), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
      'only resumed, enabled, uncovered reader captures keys and releases ownership',
      (tester) async {
    final native = <bool>[];
    final turns = <int>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderVolumeKeys.channel, (call) async {
      native.add(call.arguments as bool);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderVolumeKeys.channel, null));
    final enabled = ValueNotifier(false);
    addTearDown(enabled.dispose);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [appRouteObserver],
        home: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, value, __) => ReaderVolumeKeys(
                enabled: value,
                onTurn: turns.add,
                child: const Scaffold(body: Text('reader'))))));
    await tester.pumpAndSettle();
    expect(native.last, false);
    await turn(1);
    expect(turns, isEmpty);
    enabled.value = true;
    await tester.pumpAndSettle();
    expect(native.last, true);
    await turn(1);
    await turn(-1);
    await turn(42);
    expect(turns, [1, -1]);
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('covered')))));
    await tester.pumpAndSettle();
    expect(native.last, false);
    await turn(1);
    expect(turns, [1, -1]);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(native.last, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(native.last, false);
    await turn(1);
    expect(turns, [1, -1]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(native.last, true);
    await turn(1);
    expect(turns, [1, -1, 1]);
    unawaited(showDialog<void>(
        context: nav.currentContext!,
        builder: (_) => const AlertDialog(content: Text('menu'))));
    await tester.pumpAndSettle();
    expect(native.last, false);
    await turn(1);
    expect(turns, [1, -1, 1]);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(native.last, true);
    enabled.value = false;
    await tester.pumpAndSettle();
    expect(native.last, false);
    await turn(1);
    expect(turns, [1, -1, 1]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(native.last, false);
  });
}
