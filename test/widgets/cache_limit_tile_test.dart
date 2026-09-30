import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/widgets/cache_limit_tile.dart';
import 'package:oviewer/widgets/clear_image_cache_tile.dart';

class MockSettings extends Mock implements SettingsBloc {}

Widget app(Widget child, {String locale = 'zh'}) {
  final settings = MockSettings();
  when(() => settings.state).thenReturn(SettingsState(locale: locale));
  when(() => settings.stream).thenAnswer((_) => const Stream.empty());
  return BlocProvider<SettingsBloc>.value(
      value: settings, child: MaterialApp(home: Scaffold(body: child)));
}

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets(
        '$locale lower limit requires confirmation; cancel leaves it unchanged',
        (tester) async {
      final applied = <int>[];
      await tester.pumpWidget(app(
          CacheLimitTile(
              limitMB: 500,
              onApply: (value) async {
                applied.add(value);
              }),
          locale: locale));
      Future<void> choose() async {
        await tester.tap(find.byKey(const ValueKey('cache-limit')));
        await tester.pumpAndSettle();
        for (final mb in [100, 200, 500, 1000, 2000]) {
          expect(find.widgetWithText(RadioListTile<int>, '$mb MB'),
              findsOneWidget);
        }
        await tester.tap(find.text('100 MB'));
        await tester.pumpAndSettle();
      }

      await choose();
      expect(applied, isEmpty);
      expect(
          find.text(locale == 'zh'
              ? '调低限制后，自动清理超出部分！'
              : 'Lowering the limit will automatically remove excess cached images!'),
          findsOneWidget);
      await tester.tap(find.text(locale == 'zh' ? '取消' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(applied, isEmpty);
      await choose();
      await tester.tap(find.text(locale == 'zh' ? '确认' : 'Confirm'));
      await tester.pumpAndSettle();
      expect(applied, [100]);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'raising limit needs no warning, prevents duplicates and permits retry',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(app(CacheLimitTile(
        limitMB: 100,
        onApply: (_) {
          calls++;
          return calls == 1 ? pending.future : Future.value();
        })));
    await tester.tap(find.byKey(const ValueKey('cache-limit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('200 MB'));
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cache-limit')));
    await tester.pump();
    expect(calls, 1);
    pending.completeError(StateError('disk busy'));
    await tester.pumpAndSettle();
    expect(find.text('缓存限制设置或清理失败，请重试'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cache-limit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('200 MB'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });
  testWidgets('leaving during application of limit has no late UI updates',
      (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
        app(CacheLimitTile(limitMB: 100, onApply: (_) => pending.future)));
    await tester.tap(find.byKey(const ValueKey('cache-limit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('200 MB'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('disk busy'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'automatic cleanup refreshes actual size and retry removes failure message',
      (tester) async {
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    var bytes = 1024 * 1024;
    var failed = false;
    var retries = 0;
    await tester.pumpWidget(app(ClearImageCacheTile(
        onClear: () async {},
        readSize: () async => bytes,
        changes: changes,
        cleanupFailed: () => failed,
        retryCleanup: () async {
          retries++;
          bytes = 512;
          failed = false;
          changes.value++;
        })));
    await tester.pumpAndSettle();
    expect(find.text('1.0 MB'), findsOneWidget);
    bytes = 2048;
    failed = true;
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.text('2.0 KB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-cache-quota')));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.text('512 B'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-cache-quota')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.value++;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
