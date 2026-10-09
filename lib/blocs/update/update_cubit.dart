import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/services/apk_download_service.dart';
import '../../core/services/apk_installer.dart';
import '../../models/apk_update.dart';
import '../../repositories/update_repository.dart';

enum ApkUpdatePhase {
  idle,
  checking,
  available,
  downloading,
  verifying,
  waitingPermission,
  ready,
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
        ApkUpdatePhase.verifying
      ].contains(phase);
}

class UpdateCubit extends Cubit<ApkUpdateState> with WidgetsBindingObserver {
  UpdateCubit(this.repository, this.downloads, this.installer)
      : super(const ApkUpdateState(ApkUpdatePhase.idle)) {
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }
  final UpdateRepository repository;
  final ApkDownloadService downloads;
  final ApkInstaller installer;
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
      final saved = await downloads.restore();
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
          if (error.code != 'not_newer') rethrow;
        }
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
      if (saved != null && result.apk?.sha256 != saved.update.sha256)
        await downloads.discard();
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
    _autoInstall = true;
    emit(ApkUpdateState(ApkUpdatePhase.downloading,
        update: update, result: state.result));
    try {
      final file = await downloads.download(update, progress: (n) {
        if (_active(generation)) _set(ApkUpdatePhase.downloading, received: n);
      }, verifying: () {
        if (_active(generation)) _set(ApkUpdatePhase.verifying);
      });
      if (!_active(generation)) return;
      await installer.inspect(file.path, update);
      if (!_active(generation)) return;
      _set(ApkUpdatePhase.ready, path: file.path);
      if (_foreground) await install();
    } catch (error) {
      if (_active(generation)) {
        _autoInstall = false;
        _set(ApkUpdatePhase.error, error: _error(error));
      }
    }
  }

  void cancel() {
    ++_generation;
    _check?.cancel();
    _check = null;
    downloads.cancel();
    _autoInstall = false;
    emit(ApkUpdateState(ApkUpdatePhase.available,
        update: state.update, result: state.result));
  }

  Future<void> install() async {
    if (_installing ||
        state.path == null ||
        state.update == null ||
        !_foreground) return;
    _installing = true;
    _autoInstall = false;
    final generation = _generation;
    try {
      await downloads.verify(File(state.path!), state.update!);
      await installer.inspect(state.path!, state.update!);
      if (!_active(generation)) return;
      if (!_foreground) {
        _autoInstall = true;
        return;
      }
      if (!await installer.canInstall()) {
        if (_active(generation)) {
          if (!_foreground) {
            _autoInstall = true;
            return;
          }
          _set(ApkUpdatePhase.waitingPermission);
          await openPermissionSettings();
        }
        return;
      }
      if (!_active(generation)) return;
      if (!_foreground) {
        _autoInstall = true;
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
    if (!_foreground) return;
    if (_settingsOpened && _settingsLeftApp) {
      _settingsOpened = false;
      _settingsLeftApp = false;
      unawaited(_afterSettings());
    } else if (_autoInstall && this.state.phase == ApkUpdatePhase.ready) {
      unawaited(install());
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
    downloads.cancel();
    WidgetsBinding.instance.removeObserver(this);
    return super.close();
  }
}
