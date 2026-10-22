import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/download/download_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/screens/download/download_screen.dart';
import 'offline_gallery_ui_test.dart' show book;

class Settings extends Mock implements SettingsBloc {}

class Coordinator extends Mock implements OfflineDownloadCoordinator {}

class Repository extends Mock implements OfflineRepository {}

void main() {
  for (final locale in ['zh', 'en']) {
    for (final action in ['finish', 'pause', 'delete', 'failure']) {
      testWidgets('resume feedback and $action while waiting ($locale)',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        final coordinator = Coordinator();
        final repo = Repository();
        final settings = Settings();
        final changes = StreamController<void>.broadcast();
        final gate = Completer<void>();
        var resuming = <String>{};
        var tasks = [book(status: 'paused', pages: 0)];
        when(() => coordinator.initialize()).thenAnswer((_) async {});
        when(() => coordinator.repository).thenReturn(repo);
        when(() => coordinator.changes).thenAnswer((_) => changes.stream);
        when(() => coordinator.resumingIds).thenAnswer((_) => Set.of(resuming));
        when(() => repo.all()).thenAnswer((_) async => tasks);
        when(() => coordinator.resume('book-eh')).thenAnswer((_) {
          resuming = {'book-eh'};
          return gate.future.whenComplete(() => resuming = {});
        });
        when(() => coordinator.pause('book-eh')).thenAnswer((_) async {
          resuming = {};
          gate.complete();
        });
        when(() => coordinator.delete('book-eh')).thenAnswer((_) async {
          tasks = [];
          resuming = {};
          gate.complete();
        });
        when(() => settings.state).thenReturn(SettingsState(locale: locale));
        when(() => settings.stream).thenAnswer((_) => const Stream.empty());
        final bloc = DownloadBloc(coordinator);
        await tester.pumpWidget(MultiBlocProvider(
            providers: [
              BlocProvider<DownloadBloc>.value(value: bloc),
              BlocProvider<SettingsBloc>.value(value: settings),
            ],
            child: MaterialApp(
                theme: AppTheme.light, home: const DownloadScreen())));
        await tester.pumpAndSettle();
        await tester
            .tap(find.text(locale == 'zh' ? '继续下载' : 'Resume download'));
        await tester.pump();
        final label = locale == 'zh' ? '正在恢复…' : 'Resuming…';
        final button = find.widgetWithText(TextButton, label);
        expect(button, findsOneWidget);
        expect(tester.widget<TextButton>(button).onPressed, isNull);
        verify(() => coordinator.resume('book-eh')).called(1);
        if (action == 'pause') {
          await tester.tap(find.text(locale == 'zh' ? '暂停' : 'Pause'));
        } else if (action == 'delete') {
          await tester.tap(find.byIcon(Icons.delete_outline));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(
              FilledButton, locale == 'zh' ? '删除' : 'Delete'));
        } else if (action == 'failure') {
          gate.completeError(const OfflineFailure('background_unavailable'));
        } else {
          tasks = [book(status: 'downloading', pages: 0)];
          gate.complete();
        }
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextButton, label), findsNothing);
        if (action == 'failure' || action == 'pause') {
          expect(find.text(locale == 'zh' ? '继续下载' : 'Resume download'),
              findsOneWidget);
        }
        if (action == 'failure') expect(find.byType(SnackBar), findsOneWidget);
        if (action == 'delete')
          expect(find.text('Offline gallery'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => bloc.close());
        await tester.runAsync(() => changes.close());
        await tester.binding.setSurfaceSize(null);
      });
    }
  }
}
