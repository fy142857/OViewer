import 'package:flutter/foundation.dart';

/// Phase names and elapsed time only; never URLs, credentials or user data.
class StartupTimings {
  static Stopwatch? _clock;
  static final _recorded = <String>{};
  static void start() {
    _recorded.clear();
    _clock = Stopwatch()..start();
  }

  static void mark(String phase, {String result = 'ok', int? durationMs}) {
    if (_clock == null || !_recorded.add(phase)) return;
    debugPrint(
        '[startup] phase=$phase elapsed_ms=${_clock!.elapsedMilliseconds}'
        '${durationMs == null ? '' : ' duration_ms=$durationMs'} result=$result');
  }

  static Future<T> measure<T>(String phase, Future<T> Function() work) async {
    final watch = Stopwatch()..start();
    try {
      final value = await work();
      mark(phase, durationMs: watch.elapsedMilliseconds);
      return value;
    } catch (_) {
      mark(phase, result: 'failed', durationMs: watch.elapsedMilliseconds);
      rethrow;
    }
  }
}
