import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../../models/apk_update.dart';

/// Engine-owned bridge: no Activity is needed to keep a transfer alive.
class ApkUpdatePlatform {
  ApkUpdatePlatform({String Function()? language})
      : language = language ?? (() => 'zh');
  static const channel = MethodChannel('oviewer/update_download');
  final String Function() language;
  void Function()? onCancel;
  void Function(String)? onInterrupted;
  Future<void> Function(String, bool)? onOpen;
  Map<String, dynamic>? _pendingOpen;
  Timer? _progressTimer;
  Map<String, dynamic>? _progress;
  int? _session;
  static String taskId(ApkUpdate update) =>
      '${update.buildNumber}:${update.sha256}';

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    channel.setMethodCallHandler((call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'open') {
        _pendingOpen = args;
        await drainOpen();
      } else if (args['session'] == _session) {
        if (call.method == 'cancel') onCancel?.call();
        if (call.method == 'interrupted') {
          onInterrupted?.call(args['reason'] as String? ?? 'interrupted');
        }
      }
    });
    final pending = await channel.invokeMapMethod<String, dynamic>('ready');
    if (pending != null) _pendingOpen = pending;
    await drainOpen();
  }

  Future<void> drainOpen() async {
    if (onOpen == null || _pendingOpen == null) return;
    final pending = _pendingOpen!;
    _pendingOpen = null;
    await onOpen!(pending['id'] as String? ?? '', pending['install'] == true);
  }

  Future<int> start(ApkUpdate update) async {
    if (_session != null) throw StateError('background_unavailable');
    final session = DateTime.now().microsecondsSinceEpoch;
    _session = session;
    try {
      final started = await channel.invokeMethod<bool>('start', {
        'session': session,
        'id': taskId(update),
        'version': update.version,
        'total': update.size,
        'language': language(),
      }).timeout(const Duration(seconds: 8));
      if (started != true) throw StateError('background_unavailable');
      return session;
    } catch (_) {
      try {
        await finish(session, 'cancelled');
      } catch (_) {}
      rethrow;
    }
  }

  void progress(int session, int received, {bool verifying = false}) {
    if (session != _session) return;
    _progress = {
      'session': session,
      'received': received,
      'verifying': verifying
    };
    if (verifying) {
      _progressTimer?.cancel();
      _progressTimer = null;
      unawaited(_sendProgress());
    } else {
      _progressTimer ??= Timer(const Duration(seconds: 1), () {
        _progressTimer = null;
        unawaited(_sendProgress());
      });
    }
  }

  Future<void> _sendProgress() async {
    final payload = _progress;
    _progress = null;
    if (payload == null || payload['session'] != _session) return;
    try {
      await channel.invokeMethod<void>('progress', payload);
    } on PlatformException {
      if (payload['session'] == _session)
        onInterrupted?.call('background_unavailable');
    } on MissingPluginException {
      if (payload['session'] == _session)
        onInterrupted?.call('background_unavailable');
    }
  }

  Future<void> finish(int session, String outcome) async {
    if (_session != session) return;
    _progressTimer?.cancel();
    _progressTimer = null;
    _progress = null;
    try {
      await channel.invokeMethod<void>('finish', {
        'session': session,
        'outcome': outcome
      }).timeout(const Duration(seconds: 8));
    } finally {
      if (_session == session) _session = null;
    }
  }

  Future<void> clearNotification() async {
    if (Platform.isAndroid) await channel.invokeMethod<void>('clear');
  }

  Future<void> maintainNotification(int installedBuild) async {
    if (Platform.isAndroid) {
      await channel
          .invokeMethod<void>('maintain', {'installedBuild': installedBuild});
    }
  }

  void dispose() {
    _progressTimer?.cancel();
    if (Platform.isAndroid) channel.setMethodCallHandler(null);
  }
}
