import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FramePhase;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Opt-in, anonymous entry measurements shared by online and offline readers.
class ReaderEntryDiagnostics with WidgetsBindingObserver {
  static const enabled = bool.fromEnvironment('READER_DIAGNOSTICS');
  static int _sequence = 0;
  final int id = ++_sequence;
  final Stopwatch watch = Stopwatch()..start();
  int? _firstFrameTimestamp;
  bool _disposed = false;
  bool _visible = false;

  ReaderEntryDiagnostics() {
    if (!enabled) return;
    mark('entry');
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _firstFrameTimestamp =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    });
    // Profile timing reports are batched. Keep the observer through delivery,
    // but include only frames from the first second of this reader route.
    Timer(const Duration(seconds: 3), () {
      SchedulerBinding.instance.removeTimingsCallback(_timings);
    });
  }

  void mark(String phase, [Map<String, Object?> data = const {}]) {
    if (!enabled || _disposed) return;
    debugPrint('[reader-entry] ${jsonEncode({
          'id': id,
          'phase': phase,
          'us': watch.elapsedMicroseconds,
          ...data
        })}');
  }

  void visible() {
    if (_visible || _disposed) return;
    _visible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => mark('visible'));
  }

  void _timings(List<FrameTiming> frames) {
    final first = _firstFrameTimestamp;
    if (first == null) return;
    for (final frame in frames) {
      final timestamp = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      if (timestamp < first || timestamp > first + 1000000) continue;
      debugPrint('[reader-entry] ${jsonEncode({
            'id': id,
            'phase': 'frame',
            'us': timestamp - first,
            'build_us': frame.buildDuration.inMicroseconds,
            'raster_us': frame.rasterDuration.inMicroseconds,
            'vsync_us': frame.vsyncOverhead.inMicroseconds
          })}');
    }
  }

  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    mark('metrics', {
      'width': view.physicalSize.width,
      'height': view.physicalSize.height,
      'top': view.padding.top,
      'bottom': view.padding.bottom
    });
  }

  void dispose() {
    if (_disposed) return;
    mark('exit');
    _disposed = true;
    if (!enabled) return;
    WidgetsBinding.instance.removeObserver(this);
  }
}
