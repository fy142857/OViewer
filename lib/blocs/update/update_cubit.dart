import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/services/apk_download_service.dart';
import '../../core/services/apk_installer.dart';
import '../../core/services/apk_update_platform.dart';
import '../../models/apk_update.dart';
import '../../repositories/update_repository.dart';

enum ApkUpdatePhase {
  idle,
  checking,
  available,
  downloading,
  pausing,
  verifying,
  waitingPermission,
  ready,
  interrupted,
  error
}

class ApkUpdateState {
  const ApkUpdateState(this.phase,
      {this.result, this.update, this.path, this.received = 0, this.error});
  final ApkUpdatePhase phase;
  final UpdateCheckResult? result;
  final ApkUpdate? update;
  final String? path;
  final int received;
  final String? error;
  bool get working => const [
        ApkUpdatePhase.checking,
        ApkUpdatePhase.downloading,
        ApkUpdatePhase.pausing,
        ApkUpdatePhase.verifying
      ].contains(phase);
}

class UpdateCubit extends Cubit<ApkUpdateState> with WidgetsBindingObserver {
  UpdateCubit(this.repository, this.downloads, this.installer, {this.platform})
      : super(const ApkUpdateState(ApkUpdatePhase.idle)) {
    WidgetsBinding.instance.addObserver(this);
    platform?.onCancel = cancel;
    platform?.onInterrupted = (reason) {
      _autoInstall = false;
      _interruption = reason;
      downloads.interrupt();
    };
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }
  final UpdateRepository repository;
  final ApkDownloadService downloads;
  final ApkInstaller installer;
  final ApkUpdatePlatform? platform;
  int _windows = 0;
  int _visibilityRevision = 0;
  bool get windowVisible => _windows > 0;
  String? _notificationInstallId;
  String? _interruption;
  void windowOpened() {
    _windows++;
  }

  void windowClosed() {
    _visibilityRevision++;
    if (_windows > 0) _windows--;
    _autoInstall = false;
  }

  String? get taskId =>
      state.update == null ? null : ApkUpdatePlatform.taskId(state.update!);
  Future<void> installFromNotification(String id) async {
    if (id != taskId || state.phase != ApkUpdatePhase.ready) return;
    if (!_foreground) {
      _notificationInstallId = id;
      return;
    }
    _notificationInstallId = null;
    await install();
  }

  UpdateCheckOperation? _check;
  int _generation = 0;
  bool _foreground = true;
  bool _autoInstall = false;
  bool _installing = false;
  bool _settingsOpened = false;
  bool _settingsLeftApp = false;

  bool _active(int generation) => !isClosed && generation == _generation;
  void _set(ApkUpdatePhase phase,
      {UpdateCheckResult? result,
      ApkUpdate? update,
      String? path,
      int? received,
      String? error}) {
    if (!isClosed)
      emit(ApkUpdateState(phase,
          result: result ?? state.result,
          update: update ?? state.update,
          path: path ?? state.path,
          received: received ?? state.received,
          error: error));
  }

  String _error(Object error) => error is ApkUpdateException
      ? error.code
      : error is PlatformException
          ? error.code
          : error is UpdateCheckException
              ? error.failure.name
              : error is FileSystemException
                  ? 'storage'
                  : error is StateError &&
                          error.message == 'background_unavailable'
                      ? 'background_unavailable'
                      : 'network';

  /// Opening the entry restores a verified complete package before networking.
  Future<void> check({bool fresh = false}) async {
    if (state.working ||
        _installing ||
        state.phase == ApkUpdatePhase.waitingPermission) return;
    if (!fresh && state.update != null) return;
    final generation = ++_generation;
    emit(const ApkUpdateState(ApkUpdatePhase.checking));
    try {
      var saved = await downloads.restore();
      if (!_active(generation)) return;
      if (saved != null) {
        _set(ApkUpdatePhase.checking,
            update: saved.update,
            result: UpdateCheckResult(UpdateStatus.available,
                version: saved.update.version,
                releaseUrl: saved.update.releaseUrl,
                apk: saved.update));
        try {
          await installer.inspect(saved.file.path, saved.update);
          if (!_active(generation)) return;
          if (!fresh) {
            _set(ApkUpdatePhase.ready,
                update: saved.update,
                path: saved.file.path,
                result: UpdateCheckResult(UpdateStatus.available,
                    version: saved.update.version,
                    releaseUrl: saved.update.releaseUrl,
                    apk: saved.update));
            return;
          }
        } on PlatformException catch (error) {
          await downloads.discard();
          saved = null;
          if (error.code != 'not_newer') rethrow;
        }
      }
      final partial = saved == null ? await downloads.restorePartial() : null;
      if (!_active(generation)) return;
      if (partial != null && !fresh) {
        emit(ApkUpdateState(ApkUpdatePhase.interrupted,
            update: partial.update, received: partial.received));
        return;
      }
      if (!_active(generation)) return;
      _check = repository.check(android: true);
      final result = await _check!.result;
      if (!_active(generation)) return;
      if (saved != null && result.apk?.sha256 == saved.update.sha256) {
        _set(ApkUpdatePhase.ready,
            result: result, update: result.apk, path: saved.file.path);
        return;
      }
      if ((saved != null && result.apk?.sha256 != saved.update.sha256) ||
          (partial != null && result.apk?.sha256 != partial.update.sha256)) {
        await downloads.discard();
      }
      if (partial != null && result.apk?.sha256 == partial.update.sha256) {
        emit(ApkUpdateState(ApkUpdatePhase.interrupted,
            result: result,
            update: partial.update,
            received: partial.received));
        return;
      }
      if (!_active(generation)) return;
      emit(ApkUpdateState(ApkUpdatePhase.available,
          result: result, update: result.apk));
    } catch (error) {
      if (_active(generation)) _set(ApkUpdatePhase.error, error: _error(error));
    } finally {
      if (_active(generation)) _check = null;
    }
  }

  Future<void> start() async {
    final update = state.update;
    if (update == null || state.working || _installing) return;
    final generation = ++_generation;
    _autoInstall = _foreground && _windows > 0;
    _interruption = null;
    int? session;
    var outcome = 'cancelled';
    emit(ApkUpdateState(ApkUpdatePhase.downloading,
        update: update, result: state.result, received: state.received));
    try {
      if (platform != null) session = await platform!.start(update);
      if (!_active(generation)) return;
      if (_interruption != null) throw ApkUpdateException(_interruption!);
      final file = await downloads.download(update, progress: (n) {
        if (_active(generation) && _interruption == null) {
          _set(ApkUpdatePhase.downloading, received: n);
          if (session != null) platform?.progress(session, n);
        }
      }, verifying: () {
        if (_active(generation) && _interruption == null) {
          _set(ApkUpdatePhase.verifying);
          if (session != null)
            platform?.progress(session, update.size, verifying: true);
        }
      });
      if (!_active(generation)) return;
      await installer.inspect(file.path, update);
      if (!_active(generation)) return;
      outcome = 'ready';
      if (session != null) {
        await platform!.finish(session, outcome);
        session = null;
      }
      if (!_active(generation)) return;
      _set(ApkUpdatePhase.ready, path: file.path, received: update.size);
      if (_autoInstall && _foreground && _windows > 0)
        await install(automatic: true);
    } catch (error) {
      if (_active(generation)) {
        _autoInstall = false;
        final code = _interruption ?? _error(error);
        if (const [
          'integrity',
          'range',
          'signature_mismatch',
          'package_mismatch',
          'version_mismatch',
          'not_newer',
          'invalid_apk'
        ].contains(code)) {
          await downloads.discard();
        }
        final partial = await downloads.restorePartial();
        if (!_active(generation)) return;
        final paused = code == 'paused';
        outcome = paused
            ? 'paused'
            : partial != null
                ? 'interrupted'
                : 'error';
        if (session != null) {
          await platform!.finish(session, outcome);
          session = null;
        }
        if (!_active(generation)) return;
        emit(ApkUpdateState(
            paused || partial != null
                ? ApkUpdatePhase.interrupted
                : ApkUpdatePhase.error,
            update: update,
            result: state.result,
            received: partial?.received ?? 0,
            error: code));
      }
    } finally {
      if (session != null) {
        try {
          await platform!
              .finish(session, _active(generation) ? outcome : 'cancelled');
        } catch (_) {
          /* Native lifecycle also stops abandoned foreground work. */
        }
      }
    }
  }

  void pause() {
    if (state.phase != ApkUpdatePhase.downloading) return;
    _autoInstall = false;
    _interruption = 'paused';
    _set(ApkUpdatePhase.pausing);
    // Interrupt preserves the partial file; cancel intentionally removes it.
    downloads.interrupt();
  }

  void cancel() {
    ++_generation;
    _check?.cancel();
    _check = null;
    downloads.cancel();
    unawaited(downloads.discard().catchError((Object _) {}));
    unawaited(platform?.clearNotification());
    _autoInstall = false;
    emit(ApkUpdateState(ApkUpdatePhase.available,
        update: state.update, result: state.result));
  }

  Future<void> install({bool automatic = false}) async {
    if (_installing ||
        state.path == null ||
        state.update == null ||
        !_foreground) return;
    _installing = true;
    _autoInstall = false;
    final generation = _generation;
    final visibility = _visibilityRevision;
    bool stillVisible() =>
        !automatic || (visibility == _visibilityRevision && _windows > 0);
    void deferTransientFocusLoss() {
      if (automatic && stillVisible()) _autoInstall = true;
    }

    try {
      await downloads.verify(File(state.path!), state.update!);
      await installer.inspect(state.path!, state.update!);
      if (!_active(generation) || !stillVisible()) return;
      if (!_foreground) {
        deferTransientFocusLoss();
        return;
      }
      if (!await installer.canInstall()) {
        if (_active(generation) && stillVisible()) {
          if (!_foreground) {
            deferTransientFocusLoss();
            return;
          }
          _set(ApkUpdatePhase.waitingPermission);
          await openPermissionSettings();
        }
        return;
      }
      if (!_active(generation) || !stillVisible()) return;
      if (!_foreground) {
        deferTransientFocusLoss();
        return;
      }
      // Consume the intent before leaving the app; returning must not relaunch.
      _set(ApkUpdatePhase.ready);
      await installer.install(state.path!, state.update!);
    } catch (error) {
      if (_active(generation)) _set(ApkUpdatePhase.error, error: _error(error));
    } finally {
      _installing = false;
    }
  }

  Future<void> openPermissionSettings() async {
    if (_settingsOpened || !_foreground) return;
    _settingsOpened = true;
    _settingsLeftApp = false;
    try {
      if (!await installer.openSettings()) declinePermission();
    } catch (error) {
      _settingsOpened = false;
      _set(ApkUpdatePhase.error, error: _error(error));
    }
  }

  void declinePermission() {
    _settingsOpened = false;
    _autoInstall = false;
    _set(ApkUpdatePhase.ready);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground && _settingsOpened) _settingsLeftApp = true;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _autoInstall = false;
      _visibilityRevision++;
    }
    if (!_foreground) return;
    final notificationId = _notificationInstallId;
    if (notificationId != null) {
      _notificationInstallId = null;
      unawaited(installFromNotification(notificationId));
    }
    if (_settingsOpened && _settingsLeftApp) {
      _settingsOpened = false;
      _settingsLeftApp = false;
      unawaited(_afterSettings());
    } else if (_autoInstall &&
        this.state.phase == ApkUpdatePhase.ready &&
        _windows > 0) {
      unawaited(install(automatic: true));
    }
  }

  Future<void> _afterSettings() async {
    try {
      final allowed = await installer.canInstall();
      if (isClosed) return;
      _set(ApkUpdatePhase.ready);
      if (allowed) {
        _autoInstall = true;
        if (_foreground) await install();
      }
    } catch (error) {
      _set(ApkUpdatePhase.error, error: _error(error));
    }
  }

  @override
  Future<void> close() {
    ++_generation;
    _check?.cancel();
    downloads.interrupt();
    platform?.onCancel = null;
    platform?.onInterrupted = null;
    WidgetsBinding.instance.removeObserver(this);
    return super.close();
  }
}
