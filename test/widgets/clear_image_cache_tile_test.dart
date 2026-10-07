import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/widgets/clear_image_cache_tile.dart';

class MockSettings extends Mock implements SettingsBloc {}

Widget app(Future<void> Function() clear,
    {Future<int> Function()? readSize,
    int Function()? readMemorySize,
    String locale = 'en'}) {
  final settings = MockSettings();
  when(() => settings.state).thenReturn(SettingsState(locale: locale));
  when(() => settings.stream).thenAnswer((_) => const Stream.empty());
  return BlocProvider<SettingsBloc>.value(
      value: settings,
      child: MaterialApp(
          home: Scaffold(
              body: ClearImageCacheTile(
                  onClear: clear,
                  readSize: readSize ?? () async => 0,
                  readMemorySize: readMemorySize))));
}

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets(
        'total includes reader memory with clear disk-limit explanation ($locale)',
        (tester) async {
      await tester.pumpWidget(app(() async {},
          locale: locale,
          readSize: () async => 3 * 1024 * 1024,
          readMemorySize: () => 1024 * 1024));
      await tester.pumpAndSettle();
      expect(find.text('3.0 MB'), findsOneWidget);
      expect(find.textContaining('1.0 MB'), findsOneWidget);
      expect(
          find.textContaining(
              locale == 'zh' ? '容量限制仅用于磁盘缓存' : 'limit applies to disk cache'),
          findsOneWidget);
    });
  }

  testWidgets(
      'only clear button starts cleanup and repeated taps cannot start another',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(app(() {
      calls++;
      return pending.future;
    }));
    await tester.tap(find.text('Image Cache'));
    await tester.pump();
    await tester.tap(find.text('0 B'));
    await tester.pump();
    expect(calls, 0);
    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Cache cleared'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('clear-image-cache')));
    await tester.pump();
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cache cleared'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  testWidgets(
      'shows measured size and refreshes actual remaining bytes after clear',
      (tester) async {
    final firstRead = Completer<int>();
    var reads = 0;
    await tester.pumpWidget(app(() async {},
        readSize: () => ++reads == 1 ? firstRead.future : Future.value(512)));
    expect(find.text('Calculating…'), findsOneWidget);
    firstRead.complete(1024 * 1024);
    await tester.pumpAndSettle();
    expect(find.text('1.0 MB'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('512 B'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
  });
  testWidgets('late initial result cannot replace the post-clear size',
      (tester) async {
    final old = Completer<int>();
    var reads = 0;
    await tester.pumpWidget(app(() async {},
        readSize: () => ++reads == 1 ? old.future : Future.value(0)));
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('0 B'), findsOneWidget);
    old.complete(5 * 1024 * 1024);
    await tester.pumpAndSettle();
    expect(find.text('0 B'), findsOneWidget);
    expect(find.text('5.0 MB'), findsNothing);
  });
  testWidgets('size errors are not presented as zero cache', (tester) async {
    await tester.pumpWidget(
        app(() async {}, readSize: () async => throw StateError('unreadable')));
    await tester.pumpAndSettle();
    expect(find.text('Cache size unavailable'), findsOneWidget);
    expect(find.text('0 B'), findsNothing);
  });

  testWidgets('failure reports no success and allows retry', (tester) async {
    var calls = 0;
    await tester.pumpWidget(app(() async {
      if (++calls == 1) throw StateError('failed');
    }));
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Some image cache could not be cleared. Please retry.'),
        findsOneWidget);
    expect(find.text('Cache cleared'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Cache cleared'), findsOneWidget);
  });
  testWidgets('leaving settings during cleanup never updates a disposed widget',
      (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(app(() => pending.future));
    await tester.tap(find.text('Clear'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
