import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'offline_download_coordinator.dart';

class OfflinePlatform with WidgetsBindingObserver {
  static const channel = MethodChannel('oviewer/offline');
  OfflineDownloadCoordinator? _coordinator;
  StreamSubscription<void>? _changes;
  Timer? _notification;
  VoidCallback? openDownloads;
  bool _pendingOpen = false;
  final String Function() language;
  OfflinePlatform(this.language);
  void bind(OfflineDownloadCoordinator coordinator) {
    _coordinator = coordinator;
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'pause') await coordinator.pauseAll();
        if (call.method == 'timeout')
          await coordinator.pauseAll(reason: 'service_timeout');
        if (call.method == 'serviceUnavailable')
          await coordinator.pauseAll(reason: 'background_unavailable');
        if (call.method == 'openDownloads') {
          if (openDownloads == null)
            _pendingOpen = true;
          else
            openDownloads!();
        }
      });
      unawaited(channel.invokeMethod<void>('ready'));
      _changes = coordinator.changes.listen((_) {
        _notification ??= Timer(const Duration(seconds: 1), () {
          _notification = null;
          unawaited(_updateNotification());
        });
      });
    }
  }

  void attachNavigator(VoidCallback open) {
    openDownloads = open;
    if (_pendingOpen) {
      _pendingOpen = false;
      open();
    }
    if (Platform.isAndroid)
      unawaited(
          channel.invokeMethod<bool>('consumeOpenRequest').then((pending) {
        if (pending == true) openDownloads?.call();
      }).catchError((Object _) {}));
  }

  Future<void> start() async {
    if (Platform.isAndroid) {
      final started =
          await channel.invokeMethod<bool>('start', {'language': language()});
      if (started != true) throw StateError('background_unavailable');
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) await channel.invokeMethod<void>('stop');
  }

  Future<void> _updateNotification() async {
    try {
      final coordinator = _coordinator;
      if (coordinator == null || !coordinator.running) return;
      final books = (await coordinator.repository.all()).where(
          (b) => const ['preparing', 'downloading'].contains(b.record.status));
      await channel.invokeMethod<void>('progress', {
        'pages': books.fold<int>(0, (n, b) => n + b.completedPages),
        'total': books.fold<int>(0, (n, b) => n + b.record.totalPages),
        'active': coordinator.activeGalleries,
        'language': language(),
      });
    } catch (_) {
      /* A detached Activity does not stop the service-owned worker. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isIOS) return;
    if (state == AppLifecycleState.paused) {
      unawaited(_coordinator?.suspendForIOS());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_coordinator?.returnToForeground().catchError((Object _) {}));
    }
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    _notification?.cancel();
    await _changes?.cancel();
    if (Platform.isAndroid) channel.setMethodCallHandler(null);
  }
}
