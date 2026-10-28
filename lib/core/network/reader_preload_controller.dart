import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/reader_preload_window.dart';

typedef ReaderPreloadKey = (int page, int attempt);

/// One reader's bounded background work. Visible pages never wait for slots.
/// A slot spans address acquisition, download and validation of the first frame.
class ReaderPreloadController extends ChangeNotifier {
  ReaderPreloadController({required this.load});
  // null means discarded work (navigation/session change), not a failed page.
  final Future<bool?> Function(int page, int attempt) load;
  final _active = <ReaderPreloadKey>{};
  final _promoted = <ReaderPreloadKey>{};
  final _done = <ReaderPreloadKey>{};
  final _failed = <ReaderPreloadKey>{};
  List<ReaderPreloadKey> _queue = [];
  Set<int> _visible = {};
  bool _closed = false;

  int get backgroundCount =>
      _active.where((k) => !_promoted.contains(k)).length;
  bool permits(int page, int attempt) =>
      _active.contains((page, attempt)) || _done.contains((page, attempt));
  bool completed(int page, int attempt) => _done.contains((page, attempt));
  bool failed(int page, int attempt) => _failed.contains((page, attempt));

  void update(ReaderPreloadWindow window, Map<int, int> attempts) {
    if (_closed) return;
    _visible = window.visible;
    // Once taken over by the foreground, the request keeps that ownership
    // until it finishes, even if a rapid jump makes it offscreen again.
    _promoted.addAll(_active.where((k) => _visible.contains(k.$1)));
    _queue = [
      for (final page in window.neighbours) (page, attempts[page] ?? 0)
    ];
    _pump();
  }

  void fail(int page, int attempt) {
    if (_closed || !_failed.add((page, attempt))) return;
    _done.remove((page, attempt));
    notifyListeners();
  }

  void _pump() {
    if (_closed) return;
    while (backgroundCount < 2 && _queue.isNotEmpty) {
      final key = _queue.removeAt(0);
      if (_active.contains(key) ||
          _done.contains(key) ||
          _failed.contains(key)) {
        continue;
      }
      _active.add(key);
      notifyListeners();
      unawaited(_run(key));
    }
  }

  Future<void> _run(ReaderPreloadKey key) async {
    bool? success = false;
    try {
      success = await load(key.$1, key.$2);
    } catch (_) {
      // A failed neighbour is local to that attempt, never an automatic loop.
    }
    _active.remove(key);
    _promoted.remove(key);
    if (_closed) return;
    if (success != null) (success ? _done : _failed).add(key);
    notifyListeners();
    _pump();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    super.dispose();
  }
}
