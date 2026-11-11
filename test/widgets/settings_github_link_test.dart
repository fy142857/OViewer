import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// Config accepts this interface without exporting it.
// ignore: implementation_imports
import 'package:flutter_cache_manager/src/storage/file_system/file_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/services/release_link_opener.dart';
import 'package:oviewer/repositories/update_repository.dart';
import 'package:oviewer/screens/settings/settings_screen.dart';

class _Settings extends Mock implements SettingsBloc {}

class _Auth extends Mock implements AuthBloc {}

class _Cache extends Mock implements CacheInfoRepository {}

class _Files extends Mock implements FileSystem {}

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets('About link stays right aligned and opens GitHub ($locale)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final cache = _Cache();
      when(() => cache.open()).thenAnswer((_) async => true);
      when(() => cache.close()).thenAnswer((_) async => true);
      final files = _Files();
      final memory = MemoryFileSystem();
      when(() => files.createFile(any())).thenAnswer(
          (i) async => memory.file('/cache/${i.positionalArguments[0]}'));
      await tester.runAsync(() async {
        EhImageCacheManager.initForTesting(
            Config('settings-about', repo: cache, fileSystem: files));
      });
      addTearDown(() async {
        await tester.runAsync(() => EhImageCacheManager.instance.dispose());
        await GetIt.I.reset();
      });
      GetIt.I.registerSingleton<UpdateRepository>(
          UpdateRepository(readBuildNumber: () async => 161));
      GetIt.I.registerSingleton<ReleaseLinkOpener>(ReleaseLinkOpener());
      final settings = _Settings();
      when(() => settings.state).thenReturn(SettingsState(locale: locale));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      final auth = _Auth();
      when(() => auth.state).thenReturn(const AuthState());
      when(() => auth.stream).thenAnswer((_) => const Stream.empty());
      var calls = 0;
      var succeeds = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReleaseLinkOpener.channel,
          (call) async {
        expect(call.method, 'openRepository');
        expect(call.arguments, isNull);
        calls++;
        return succeeds;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(ReleaseLinkOpener.channel, null));
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settings),
              BlocProvider<AuthBloc>.value(value: auth),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaleFactor: scale),
                  child: child!),
              home: const SettingsScreen(),
            )));
        final link = find.byKey(const ValueKey('settings-github-link'));
        await tester.scrollUntilVisible(link, 400);
        await tester.pumpAndSettle();
        expect(find.text(locale == 'zh' ? '前往GitHub' : 'Open GitHub'),
            findsOneWidget);
        expect(tester.getRect(link).right, closeTo(304, 1));
        expect(
            tester.getRect(link).left,
            greaterThanOrEqualTo(tester
                .getRect(find.text(locale == 'zh' ? '关于' : 'About'))
                .right));
        final before = calls;
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(calls, before + 1);
        if (!succeeds) {
          expect(
              find.text(locale == 'zh'
                  ? '无法打开浏览器，请重试'
                  : 'Could not open the browser. Please retry'),
              findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        succeeds = false;
      }
    });
  }
}
