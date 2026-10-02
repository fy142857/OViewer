import 'dart:async';
import 'package:flutter/foundation.dart';
import 'system_proxy_detector.dart';

/// A single, replaceable network policy. Superseded probes cannot apply results
/// or strand requests awaiting the previous policy's completion.
class NetworkPreparation extends ChangeNotifier {
  final Future<AutoProxyResult> Function() _detect;
  final void Function(String?) _apply;
  String? _manual;
  bool _auto;
  bool _started = false;
  bool _disposed = false;
  int _revision = 0;
  Completer<void> _ready = Completer<void>();
  AutoProxyResult result =
      const AutoProxyResult(proxyUrl: null, vpnActive: false);

  NetworkPreparation(
      {required String? manualProxy,
      required bool autoProxy,
      required void Function(String?) apply,
      Future<AutoProxyResult> Function()? detect})
      : _manual = manualProxy,
        _auto = autoProxy,
        _apply = apply,
        _detect = detect ?? SystemProxyDetector.detect;

  int get revision => _revision;
  Future<void> waitUntilReady() async {
    while (true) {
      final current = _ready;
      await current.future;
      if (_disposed) throw StateError('Network preparation disposed');
      if (identical(current, _ready)) return;
    }
  }

  Future<void> start() {
    if (!_started) {
      _started = true;
      unawaited(_prepare(_revision, _ready));
    }
    return waitUntilReady();
  }

  Future<void> configure(
      {required String? manualProxy, required bool autoProxy}) {
    _manual = manualProxy;
    _auto = autoProxy;
    _revision++;
    final previous = _ready;
    _ready = Completer<void>();
    if (!previous.isCompleted) previous.complete();
    _started = false;
    return start();
  }

  Future<void> _prepare(int revision, Completer<void> ready) async {
    final manual = _manual;
    AutoProxyResult detected =
        const AutoProxyResult(proxyUrl: null, vpnActive: false);
    if ((manual == null || manual.isEmpty) && _auto) {
      try {
        detected = await _detect();
      } catch (_) {/* Existing direct fallback. */}
    }
    if (revision != _revision || _disposed) return;
    result = detected;
    try {
      _apply(manual != null && manual.isNotEmpty ? manual : detected.proxyUrl);
      ready.complete();
      notifyListeners();
    } catch (error, stack) {
      ready.completeError(error, stack);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_ready.isCompleted) _ready.complete();
    super.dispose();
  }
}
