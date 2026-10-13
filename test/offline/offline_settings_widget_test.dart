import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/offline_settings_panel.dart';

class Coordinator extends Mock implements OfflineDownloadCoordinator {}

class Repository extends Mock implements OfflineRepository {}

class Settings extends Mock implements SettingsRepository {}

class SettingsBlocMock extends Mock implements SettingsBloc {}

void main() {
  for (final fails in [false, true]) {
    testWidgets(
        'concurrency reaches coordinator only after settings persist (fails=$fails)',
        (tester) async {
      final coordinator = Coordinator();
      final repository = Repository();
      final settings = Settings();
      final settingsBloc = SettingsBlocMock();
      when(() => coordinator.repository).thenReturn(repository);
      when(() => coordinator.changes).thenAnswer((_) => const Stream.empty());
      when(() => repository.size()).thenAnswer((_) async => 1048576);
      when(() => settings.getOfflineParallelGalleries()).thenReturn(2);
      when(() => settings.getOfflineParallelPages()).thenReturn(4);
      when(() => settings.setOfflineParallelGalleries(3)).thenAnswer((_) async {
        if (fails) throw StateError('storage');
      });
      when(() => settingsBloc.state)
          .thenReturn(const SettingsState(locale: 'en'));
      when(() => settingsBloc.stream).thenAnswer((_) => const Stream.empty());
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(
              home: Scaffold(
                  body: OfflineSettingsPanel(
                      settings: settings, coordinator: coordinator)))));
      await tester.pumpAndSettle();
      final selector = find.byKey(const ValueKey('offline-parallel-galleries'));
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<int>>(selector).value, fails ? 2 : 3);
      if (fails) {
        verifyNever(() => coordinator.configure(
            galleries: any(named: 'galleries'), pages: any(named: 'pages')));
        expect(find.text('Could not save download settings. Please retry.'),
            findsOneWidget);
      } else {
        verify(() => coordinator.configure(galleries: 3, pages: 4)).called(1);
      }
      expect(
          find.text('Page slots are shared by all galleries'), findsOneWidget);
    });
  }
}
