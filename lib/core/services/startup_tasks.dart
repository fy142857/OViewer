import 'dart:async';
import 'startup_timings.dart';

/// Explicit first-frame boundary; slow background jobs never gate the shell.
class StartupTasks {
  final Future<void> Function() prepareNetwork;
  final Future<void> Function() maintainCache;
  final Future<void> Function() loadTranslations;
  Future<void>? _work;
  StartupTasks(
      {required this.prepareNetwork,
      required this.maintainCache,
      required this.loadTranslations});

  Future<void> afterFirstFrame(Future<void> firstFrame) =>
      _work ??= _run(firstFrame);
  Future<void> _run(Future<void> firstFrame) async {
    await firstFrame;
    StartupTimings.mark('first_frame');
    Future<void> guarded(String phase, Future<void> Function() action) async {
      try {
        await StartupTimings.measure(phase, action);
      } catch (_) {
        // Each subsystem exposes its own recovery; unrelated work continues.
      }
    }

    await Future.wait([
      guarded('network_ready', prepareNetwork),
      guarded('cache_maintenance', maintainCache),
      guarded('translations_ready', loadTranslations),
    ]);
  }
}
