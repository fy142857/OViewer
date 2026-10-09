import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/blocs/update/update_cubit.dart';
import 'package:oviewer/widgets/check_update_tile.dart';
import '../blocs/update_cubit_test.dart'
    show FakeUpdates, ControlledDownloads, FakeInstaller;

class _Settings extends Mock implements SettingsBloc {}

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets('Android link, download hiding and installation in $language',
        (tester) async {
      final repo = FakeUpdates();
      final downloads = ControlledDownloads();
      final installer = FakeInstaller();
      final cubit = UpdateCubit(repo, downloads, installer);
      addTearDown(cubit.close);
      final settings = _Settings();
      when(() => settings.state).thenReturn(SettingsState(locale: language));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      final links = <Uri>[];
      final showTile = ValueNotifier(true);
      addTearDown(showTile.dispose);
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(
              home: Scaffold(
                  body: ValueListenableBuilder<bool>(
                      valueListenable: showTile,
                      builder: (_, show, __) => show
                          ? CheckUpdateTile(
                              repository: repo,
                              androidUpdater: cubit,
                              openRelease: (url) async {
                                links.add(url);
                                return true;
                              })
                          : const Text('Other page'))))));
      expect(repo.checks, 0);
      await tester.tap(find.byKey(const ValueKey('check-update')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1.8.0 ·'), findsOneWidget);
      expect(find.text('新增\n- 测试'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-release-link')));
      await tester.pump();
      expect(links.single, repo.package.releaseUrl);
      expect(downloads.starts, 0);
      await tester.tap(find.text(language == 'zh' ? '立即更新' : 'Update now'));
      await tester.pump();
      expect(downloads.starts, 1);
      await tester.tap(find.text(language == 'zh' ? '隐藏' : 'Hide'));
      await tester.pumpAndSettle();
      showTile.value = false;
      await tester.pump();
      expect(downloads.cancels, 0);
      showTile.value = true;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('check-update')));
      await tester.pump();
      expect(downloads.starts, 1);
      downloads.pending.complete(File('package.apk'));
      await tester.pumpAndSettle();
      expect(installer.installs, 1);
      expect(
          find.widgetWithText(
              FilledButton, language == 'zh' ? '立即安装' : 'Install now'),
          findsOneWidget);
    });
  }
}
