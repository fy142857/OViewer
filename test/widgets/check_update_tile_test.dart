import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/repositories/update_repository.dart';
import 'package:oviewer/widgets/check_update_tile.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../repositories/update_repository_test.dart'
    show TrackingClient, release;

class MockSettings extends Mock implements SettingsBloc {}

Widget app(UpdateRepository repo, Future<bool> Function(Uri) open,
    {String locale = 'zh', GlobalKey<NavigatorState>? navigatorKey}) {
  final settings = MockSettings();
  when(() => settings.state).thenReturn(SettingsState(locale: locale));
  when(() => settings.stream).thenAnswer((_) => const Stream.empty());
  return BlocProvider<SettingsBloc>.value(
      value: settings,
      child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
              body: CheckUpdateTile(repository: repo, openRelease: open))));
}

void main() {
  testWidgets(
      'only checks on tap, prevents duplicates, opens exact release only after confirmation',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0;
    final opened = <Uri>[];
    final client = TrackingClient((_) {
      requests++;
      return pending.future;
    });
    final repo = UpdateRepository(
        clientFactory: () => client, readVersion: () async => '1.0.0');
    await tester.pumpWidget(app(repo, (url) async {
      opened.add(url);
      return true;
    }));
    expect(requests, 0);
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.text('正在检查更新…'), findsOneWidget);
    await tester.tap(find.text('检查更新'));
    expect(requests, 1);
    pending.complete(http.Response(jsonEncode(release()), 200));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.text('最新版本为 1.2.0，点击安装'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('update-available-badge')), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), release()['html_url']);
    expect(
        find.byKey(const ValueKey('update-available-badge')), findsOneWidget);
    expect(client.closes, 1);
  });

  for (final sample in [
    ('zh', '1.2.0', '当前已是最新版本'),
    ('en', '1.2.0', 'You are on the latest version'),
    ('zh', '2.0.0', '当前版本高于最新正式版'),
    ('en', '2.0.0', 'Your version is newer than the latest release'),
  ]) {
    testWidgets('reports ${sample.$2} in ${sample.$1} without opening',
        (tester) async {
      final repo = UpdateRepository(
          clientFactory: () => TrackingClient(
              (_) async => http.Response(jsonEncode(release()), 200)),
          readVersion: () async => sample.$2);
      await tester.pumpWidget(app(
          repo, (_) async => throw StateError('Must not open'),
          locale: sample.$1));
      await tester.tap(find.byKey(const ValueKey('check-update')));
      await tester.pumpAndSettle();
      expect(find.text(sample.$3), findsOneWidget);
    });
  }

  testWidgets('network failure can retry and then report no release',
      (tester) async {
    var requests = 0;
    final repo = UpdateRepository(
        clientFactory: () => TrackingClient((_) async {
              if (++requests == 1) throw http.ClientException('offline');
              return http.Response('', 404);
            }),
        readVersion: () async => '1.0.0');
    await tester.pumpWidget(app(repo, (_) async => true));
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('检查更新失败，请检查网络后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('暂无可用正式版本'), findsOneWidget);
  });

  testWidgets('browser failure retries opening without another network request',
      (tester) async {
    var requests = 0;
    var opens = 0;
    final repo = UpdateRepository(
        clientFactory: () => TrackingClient((_) async {
              requests++;
              return http.Response(jsonEncode(release()), 200);
            }),
        readVersion: () async => '1.0.0');
    await tester.pumpWidget(app(repo, (_) async => ++opens > 1));
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(opens, 0);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开浏览器，请重试'), findsOneWidget);
    await tester.tap(find.text('重新打开'));
    await tester.pumpAndSettle();
    expect(opens, 2);
    expect(requests, 1);
  });

  for (final locale in ['zh', 'en']) {
    testWidgets(
        'cancel keeps a purple reminder across recreation and an upgrade clears it ($locale)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final storage = LocalStorage();
      await storage.init();
      var requests = 0;
      var opens = 0;
      UpdateRepository repository(String installed) => UpdateRepository(
            storage: storage,
            readVersion: () async => installed,
            clientFactory: () => TrackingClient((_) async {
              requests++;
              return http.Response(jsonEncode(release()), 200);
            }),
          );
      Future<bool> open(Uri _) async {
        opens++;
        return true;
      }

      await tester.pumpWidget(app(repository('1.0.0'), open, locale: locale));
      await tester.pumpAndSettle();
      expect(requests, 0);
      await tester.tap(find.byKey(const ValueKey('check-update')));
      await tester.pumpAndSettle();
      expect(
          find.text(locale == 'zh'
              ? '最新版本为 1.2.0，点击安装'
              : 'The latest version is 1.2.0. Click to install.'),
          findsOneWidget);
      expect(opens, 0);
      await tester.tap(find.text(locale == 'zh' ? '取消' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(storage.getLatestReleaseVersion(), '1.2.0');
      final badge = find.byKey(const ValueKey('update-available-badge'));
      expect(tester.widget<Text>(badge).style!.color, Colors.purple);
      expect(tester.widget<Text>(badge).data,
          locale == 'zh' ? '已有新版本' : 'Update available');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(repository('1.0.0'), open, locale: locale));
      await tester.pumpAndSettle();
      expect(badge, findsOneWidget);
      expect(requests, 1);
      expect(opens, 0);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(repository('1.2.0'), open, locale: locale));
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(storage.getLatestReleaseVersion(), isNull);
      expect(requests, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed check does not dismiss a saved update reminder',
      (tester) async {
    SharedPreferences.setMockInitialValues({'latest_release_version': '1.2.0'});
    final storage = LocalStorage();
    await storage.init();
    final repo = UpdateRepository(
        storage: storage,
        readVersion: () async => '1.0.0',
        clientFactory: () =>
            TrackingClient((_) async => http.Response('', 500)));
    await tester.pumpWidget(app(repo, (_) async => true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('update-available-badge')), findsOneWidget);
    expect(storage.getLatestReleaseVersion(), '1.2.0');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('检查更新失败，请检查网络后重试'), findsOneWidget);
  });

  for (final dispose in [true, false]) {
    testWidgets('leaving settings suppresses late jump (dispose: $dispose)',
        (tester) async {
      final pending = Completer<http.Response>();
      final client = TrackingClient((_) => pending.future);
      final navigator = GlobalKey<NavigatorState>();
      var opens = 0;
      final repo = UpdateRepository(
          clientFactory: () => client, readVersion: () async => '1.0.0');
      await tester.pumpWidget(app(repo, (_) async {
        opens++;
        return true;
      }, navigatorKey: navigator));
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      if (dispose) {
        await tester.pumpWidget(const SizedBox());
        expect(client.closes, 1);
      } else {
        navigator.currentState!
            .push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
        await tester.pump();
      }
      pending.complete(http.Response(jsonEncode(release()), 200));
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
