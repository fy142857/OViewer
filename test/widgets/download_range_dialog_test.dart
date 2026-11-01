import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/l10n/s.dart';
import 'package:oviewer/models/download_range.dart';
import 'package:oviewer/widgets/download_range_dialog.dart';
import 'reader_screen_test.dart' show MockSettingsBloc;

void main() {
  for (final locale in ['en', 'zh']) {
    for (final large in [false, true]) {
      testWidgets(
          'range dialog selection and keyboard layout locale=$locale large=$large',
          (tester) async {
        final settings = MockSettingsBloc();
        when(() => settings.state).thenReturn(SettingsState(locale: locale));
        when(() => settings.stream).thenAnswer((_) => const Stream.empty());
        await tester.binding.setSurfaceSize(const Size(320, 680));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        DownloadRange? selected;
        S? strings;
        await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
            value: settings,
            child: MaterialApp(
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                        // Keep this fixture runnable with local Flutter 3.13.
                        // ignore: deprecated_member_use
                        textScaleFactor: large ? 1.8 : 1,
                        viewInsets: const EdgeInsets.only(bottom: 220)),
                    child: child!),
                home: Builder(builder: (context) {
                  strings = S.of(context);
                  return Scaffold(
                      body: TextButton(
                          child: const Text('Open'),
                          onPressed: () async {
                            selected = await showDialog<DownloadRange>(
                                context: context,
                                builder: (_) => const DownloadRangeDialog(
                                    title: 'Gallery title with several words',
                                    source: 'E-Hentai',
                                    totalPages: 100,
                                    enabled: true));
                          }));
                }))));
        final s = strings!;
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final confirm = find.byKey(const ValueKey('confirm-download-range'));
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(selected!.isAll, true);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(s.downloadCustomRange));
        await tester.tap(find.text(s.downloadCustomRange));
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        final input = find.byKey(const ValueKey('download-range-input'));
        await tester.ensureVisible(input);
        await tester.enterText(input, '90-101');
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        expect(find.text(s.downloadRangeError('range_bounds', 100)),
            findsOneWidget);
        await tester.enterText(input, ' 1-5，3-8,20 ');
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(460));
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(selected!.label, '1-8, 20');
        expect(selected!.count(100), 9);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
