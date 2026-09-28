import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/models/reader_page_resource.dart';
import 'package:oviewer/widgets/reader_page_menu.dart';

class MockReader extends Mock implements ReaderBloc {}

class MockSettings extends Mock implements SettingsBloc {}

void main() {
  testWidgets(
      'save follows decoded resource of the pressed page and busy state',
      (tester) async {
    final reader = MockReader();
    final settings = MockSettings();
    final stream = StreamController<ReaderState>.broadcast();
    final saving = ValueNotifier<Set<int>>({});
    var state = const ReaderState(currentPage: 0, loadingIndices: {1});
    when(() => reader.state).thenAnswer((_) => state);
    when(() => reader.stream).thenAnswer((_) => stream.stream);
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    Object? action;
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<ReaderBloc>.value(value: reader),
          BlocProvider<SettingsBloc>.value(value: settings),
        ],
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      action = await showDialog<Object>(
                          context: context,
                          builder: (_) =>
                              ReaderPageMenu(page: 1, savingPages: saving));
                    },
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('reload-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-page')), findsNothing);
    final resource = ReaderPageResource(() async => null);
    state = state.copyWith(readyResources: {0: resource});
    stream.add(state);
    await tester.pump();
    expect(find.byKey(const ValueKey('save-page')), findsNothing);
    state = state.copyWith(loadingIndices: {}, readyResources: {1: resource});
    stream.add(state);
    await tester.pump();
    expect(find.byKey(const ValueKey('save-page')), findsOneWidget);
    saving.value = {1};
    await tester.pump();
    expect(
        tester
            .widget<SimpleDialogOption>(find.byKey(const ValueKey('save-page')))
            .onPressed,
        isNull);
    saving.value = {};
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-page')));
    await tester.pumpAndSettle();
    expect(action, same(resource));
    await tester.pumpWidget(const SizedBox.shrink());
    await stream.close();
    saving.dispose();
  });
}
