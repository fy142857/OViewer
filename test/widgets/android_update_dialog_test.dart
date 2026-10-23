import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/blocs/update/update_cubit.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/widgets/check_update_tile.dart';
import '../blocs/update_cubit_test.dart'
    show FakeUpdates, ControlledDownloads, FakeInstaller;

class _Settings extends Mock implements SettingsBloc {}

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets('Android link, download hiding and installation in $language',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
              theme: AppTheme.light,
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
      final recheck = find.widgetWithText(
          TextButton, language == 'zh' ? '重新检查版本' : 'Check again');
      final update = find.widgetWithText(
          FilledButton, language == 'zh' ? '立即更新' : 'Update now');
      final cancel =
          find.widgetWithText(TextButton, language == 'zh' ? '取消' : 'Cancel');
      for (final width in [320.0, 360.0]) {
        for (final scale in [1.0, 1.6, 2.0]) {
          await tester.binding.setSurfaceSize(Size(width, 800));
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpAndSettle();
          final recheckRect = tester.getRect(recheck);
          final updateRect = tester.getRect(update);
          expect(recheckRect.bottom, lessThanOrEqualTo(updateRect.top));
          expect(recheckRect.right, closeTo(updateRect.right, 0.1));
          expect(tester.getRect(cancel).center.dy,
              closeTo(updateRect.center.dy, 0.1));
          expect(
              tester.getRect(cancel).right, lessThanOrEqualTo(updateRect.left));
          final row =
              find.ancestor(of: update, matching: find.byType(Row)).first;
          expect(updateRect.right, closeTo(tester.getRect(row).right, 0.1));
          expect(
              tester
                  .getBottomLeft(
                      find.byKey(const ValueKey('update-release-link')))
                  .dy,
              lessThan(tester.getTopLeft(find.textContaining('1.8.0 ·')).dy));
          expect(tester.takeException(), isNull);
        }
      }
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpAndSettle();
      await tester.tap(recheck);
      await tester.pumpAndSettle();
      expect(repo.checks, 2);
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
      expect(installer.installs, 0);
      await tester.tap(find.widgetWithText(
          FilledButton, language == 'zh' ? '立即安装' : 'Install now'));
      await tester.pumpAndSettle();
      expect(installer.installs, 1);
      expect(
          find.widgetWithText(
              FilledButton, language == 'zh' ? '立即安装' : 'Install now'),
          findsOneWidget);
    });
  }
}
