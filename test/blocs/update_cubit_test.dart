import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/blocs/update/update_cubit.dart';
import 'package:oviewer/core/services/apk_download_service.dart';
import 'package:oviewer/core/services/apk_installer.dart';
import 'package:oviewer/core/services/apk_update_platform.dart';
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
  PartialApk? partial;
  @override
  Future<PartialApk?> restorePartial() async => partial;
  @override
  void interrupt() {
    interrupts++;
  }

  int interrupts = 0;
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
  int inspections = 0;
  Future<void> Function(int)? onInspect;
  @override
  Future<void> inspect(String path, ApkUpdate update) async {
    await onInspect?.call(++inspections);
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

class FakeUpdatePlatform extends ApkUpdatePlatform {
  Completer<int>? pendingStart;
  bool unavailable = false;
  final finished = <String>[];
  final progressEvents = <int>[];
  @override
  Future<int> start(ApkUpdate update) async {
    if (unavailable) throw StateError('background_unavailable');
    return pendingStart == null ? 1 : await pendingStart!.future;
  }

  @override
  void progress(int session, int received, {bool verifying = false}) =>
      progressEvents.add(received);
  @override
  Future<void> finish(int session, String outcome) async {
    finished.add(outcome);
  }

  @override
  Future<void> clearNotification() async {}
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
    cubit.windowOpened();
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

  test('background completion requires an explicit install even after resume',
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
    expect(installer.installs, 0);
    await cubit.installFromNotification(cubit.taskId!);
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

  test(
      'pause retains progress, stops service, and allows explicit continuation',
      () async {
    await cubit.close();
    final platform = FakeUpdatePlatform();
    cubit = UpdateCubit(repo, downloads, installer, platform: platform)
      ..windowOpened();
    await cubit.check();
    final work = cubit.start();
    await settleUpdate();
    downloads.progress!(2);
    downloads.partial = PartialApk(repo.package, File('package.part'), 2, null);
    final before = downloads.interrupts;
    cubit.pause();
    cubit.pause();
    expect(downloads.interrupts, before + 1);
    expect(cubit.state.phase, ApkUpdatePhase.pausing);
    downloads.progress!(3); // A queued progress callback cannot undo pausing.
    await cubit.start();
    expect(downloads.starts, 1);
    downloads.pending.completeError(const ApkUpdateException('interrupted'));
    await work;
    expect(cubit.state.phase, ApkUpdatePhase.interrupted);
    expect(cubit.state.error, 'paused');
    expect(cubit.state.received, 2);
    expect(downloads.discards, 0);
    expect(downloads.cancels, 0);
    expect(platform.finished, ['paused']);
    expect(installer.installs, 0);
    downloads.pending = Completer<File>();
    final resumed = cubit.start();
    await settleUpdate();
    expect(downloads.starts, 2);
    downloads.pending.complete(File('package.apk'));
    await resumed;
    expect(cubit.state.phase, ApkUpdatePhase.ready);
  });

  test('pause before service acknowledgement does not start transfer',
      () async {
    await cubit.close();
    final platform = FakeUpdatePlatform()..pendingStart = Completer<int>();
    cubit = UpdateCubit(repo, downloads, installer, platform: platform);
    await cubit.check();
    final work = cubit.start();
    cubit.pause();
    platform.pendingStart!.complete(1);
    await work;
    expect(downloads.starts, 0);
    expect(cubit.state.phase, ApkUpdatePhase.interrupted);
    expect(cubit.state.received, 0);
    expect(platform.finished, ['paused']);
    expect(downloads.discards, 0);
  });

  test('pause racing completed download retains APK without auto installation',
      () async {
    await cubit.check();
    final work = cubit.start();
    cubit.pause();
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(cubit.state.phase, ApkUpdatePhase.ready);
    expect(installer.installs, 0);
    expect(downloads.discards, 0);
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
    expect(cubit.state.phase, ApkUpdatePhase.available);
    expect(cubit.state.path, isNull);
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

  test('hidden window remains manual even when reopened before completion',
      () async {
    await cubit.check();
    final work = cubit.start();
    cubit.windowClosed();
    cubit.windowOpened();
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(installer.installs, 0);
    await cubit.installFromNotification('stale-notification');
    expect(installer.installs, 0);
    await cubit.installFromNotification(cubit.taskId!);
    expect(installer.installs, 1);
  });

  test('temporary permission prompt focus loss can finish the foreground flow',
      () async {
    await cubit.check();
    final work = cubit.start();
    cubit.didChangeAppLifecycleState(AppLifecycleState.inactive);
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(installer.installs, 0);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleUpdate();
    expect(installer.installs, 1);
  });

  test('hiding during final native revalidation cancels automatic installation',
      () async {
    final gate = Completer<void>();
    installer.onInspect = (n) async {
      if (n == 2) await gate.future;
    };
    await cubit.check();
    final work = cubit.start();
    downloads.pending.complete(File('package.apk'));
    await settleUpdate();
    expect(installer.inspections, 2);
    cubit.windowClosed();
    gate.complete();
    await work;
    cubit.windowOpened();
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleUpdate();
    expect(installer.installs, 0);
  });

  test('partial restoration never starts network or installation', () async {
    downloads.partial =
        PartialApk(repo.package, File('package.part'), 2, '"etag"');
    await cubit.check();
    expect(cubit.state.phase, ApkUpdatePhase.interrupted);
    expect(cubit.state.received, 2);
    expect(repo.checks, 0);
    expect(downloads.starts, 0);
    expect(installer.installs, 0);
  });

  test(
      'service acknowledgement gates transfer and cancellation releases its owner',
      () async {
    await cubit.close();
    final platform = FakeUpdatePlatform()..pendingStart = Completer<int>();
    cubit = UpdateCubit(repo, downloads, installer, platform: platform)
      ..windowOpened();
    await cubit.check();
    final work = cubit.start();
    expect(downloads.starts, 0);
    cubit.cancel();
    platform.pendingStart!.complete(1);
    await work;
    expect(downloads.starts, 0);
    expect(platform.finished, ['cancelled']);
  });

  test('service failure is visible and does not start unprotected downloading',
      () async {
    await cubit.close();
    final platform = FakeUpdatePlatform()..unavailable = true;
    cubit = UpdateCubit(repo, downloads, installer, platform: platform);
    await cubit.check();
    await cubit.start();
    expect(downloads.starts, 0);
    expect(cubit.state.error, 'background_unavailable');
  });

  test('background ready notification is posted after native inspection',
      () async {
    await cubit.close();
    final platform = FakeUpdatePlatform();
    cubit = UpdateCubit(repo, downloads, installer, platform: platform)
      ..windowOpened();
    await cubit.check();
    final work = cubit.start();
    await settleUpdate();
    cubit.didChangeAppLifecycleState(AppLifecycleState.paused);
    downloads.progress!(2);
    expect(platform.progressEvents, [2]);
    downloads.pending.complete(File('package.apk'));
    await work;
    expect(platform.finished, ['ready']);
    expect(installer.installs, 0);
    await cubit.installFromNotification(cubit.taskId!);
    expect(installer.installs, 0);
    cubit.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleUpdate();
    expect(installer.installs, 1);
  });
}
