import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/blocs/update/update_cubit.dart';
import 'package:oviewer/core/services/apk_download_service.dart';
import 'package:oviewer/core/services/apk_installer.dart';
import 'package:oviewer/models/apk_update.dart';
import 'package:oviewer/repositories/update_repository.dart';
import '../core/network/apk_download_service_test.dart' show packageFor;

class FakeUpdates extends UpdateRepository {
  final package = packageFor([1, 2, 3]);
  int checks = 0;
  @override
  UpdateCheckOperation check({bool android = false}) {
    checks++;
    return UpdateCheckOperation(
        Future.value(UpdateCheckResult(UpdateStatus.available,
            apk: package,
            version: package.version,
            releaseUrl: package.releaseUrl)),
        () {});
  }
}

class ControlledDownloads extends ApkDownloadService {
  Completer<File> pending = Completer<File>();
  SavedApk? saved;
  int starts = 0;
  int cancels = 0;
  int discards = 0;
  Object? verifyError;
  void Function(int)? progress;
  @override
  Future<SavedApk?> restore() async => saved;
  @override
  Future<void> verify(File file, ApkUpdate update) async {
    if (verifyError != null) throw verifyError!;
  }

  @override
  Future<File> download(ApkUpdate update,
      {required void Function(int) progress,
      required void Function() verifying}) {
    starts++;
    this.progress = progress;
    return pending.future;
  }

  @override
  void cancel() {
    cancels++;
  }

  @override
  Future<void> discard() async {
    discards++;
    saved = null;
  }
}

class FakeInstaller extends ApkInstaller {
  bool allowed = true;
  bool settingsOpened = true;
  int installs = 0;
  int settings = 0;
  Object? inspectError;
  @override
  Future<void> inspect(String path, ApkUpdate update) async {
    if (inspectError != null) throw inspectError!;
  }

  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<bool> openSettings() async {
    settings++;
    return settingsOpened;
  }

  @override
  Future<void> install(String path, ApkUpdate update) async {
    installs++;
  }
}

Future<void> settleUpdate() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeUpdates repo;
  late ControlledDownloads downloads;
  late FakeInstaller installer;
  late UpdateCubit cubit;
  setUp(() {
    repo = FakeUpdates();
    downloads = ControlledDownloads();
    installer = FakeInstaller();
    cubit = UpdateCubit(repo, downloads, installer);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });
  tearDown(() async {
    await cubit.close();
  });

  test('download is singleton and installation opens once, not again on resume',
      () async {
    await cubit.check();
    final work = cubit.start();
    await cubit.start();
    await cubit.check();
    expect(downloads.starts, 1);
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(installer.installs, 1);
    cubit.didChangeAppLifecycleState(AppLifecycleState.paused);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleUpdate();
    expect(installer.installs, 1);
    expect(cubit.state.phase, ApkUpdatePhase.ready);
    await cubit.install();
    expect(installer.installs, 2);
  });

  test('background completion waits until foreground and installs only once',
      () async {
    await cubit.check();
    final work = cubit.start();
    cubit.didChangeAppLifecycleState(AppLifecycleState.paused);
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(installer.installs, 0);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleUpdate();
    expect(installer.installs, 1);
  });

  for (final allowed in [true, false]) {
    test('return from permission settings (allowed=$allowed) never loops',
        () async {
      installer.allowed = false;
      await cubit.check();
      final work = cubit.start();
      downloads.pending.complete(File('package.apk'));
      await work;
      expect(installer.settings, 1);
      cubit.didChangeAppLifecycleState(AppLifecycleState.paused);
      installer.allowed = allowed;
      cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settleUpdate();
      cubit.didChangeAppLifecycleState(AppLifecycleState.paused);
      cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settleUpdate();
      expect(installer.installs, allowed ? 1 : 0);
      expect(installer.settings, 1);
      expect(cubit.state.phase, ApkUpdatePhase.ready);
    });
  }

  test('declining permission explanation retains package without auto retry',
      () async {
    installer.allowed = false;
    installer.settingsOpened = false;
    await cubit.check();
    final work = cubit.start();
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(cubit.state.phase, ApkUpdatePhase.ready);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleUpdate();
    expect(installer.settings, 1);
  });

  test('cancel invalidates a late completion before native installation',
      () async {
    await cubit.check();
    final work = cubit.start();
    cubit.cancel();
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(installer.installs, 0);
    expect(cubit.state.phase, ApkUpdatePhase.available);
    expect(cubit.state.path, isNull);
  });

  test('complete package restoration is local and never auto installs',
      () async {
    downloads.saved = SavedApk(repo.package, File('package.apk'));
    await cubit.check();
    expect(repo.checks, 0);
    expect(cubit.state.phase, ApkUpdatePhase.ready);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleUpdate();
    expect(installer.installs, 0);
  });

  test('upgraded installation discards obsolete package and checks release',
      () async {
    downloads.saved = SavedApk(repo.package, File('package.apk'));
    installer.inspectError = PlatformException(code: 'not_newer');
    await cubit.check();
    expect(downloads.discards, 1);
    expect(repo.checks, 1);
  });

  test('rechecking same release reuses already verified package', () async {
    downloads.saved = SavedApk(repo.package, File('package.apk'));
    await cubit.check(fresh: true);
    expect(repo.checks, 1);
    expect(cubit.state.phase, ApkUpdatePhase.ready);
    expect(downloads.starts, 0);
    expect(installer.installs, 0);
  });

  test('failed native validation never opens installer', () async {
    await cubit.check();
    installer.inspectError = PlatformException(code: 'signature_mismatch');
    final work = cubit.start();
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(cubit.state.error, 'signature_mismatch');
    expect(installer.installs, 0);
  });
}
