import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/router/route_observer.dart';
import '../core/services/reader_entry_diagnostics.dart';

/// One owner of system bars for the entire reader route, including resolution.
/// Images mount only after the initial fullscreen layout has settled.
class ReaderPresentation extends StatefulWidget {
  final Widget child;
  final ReaderEntryDiagnostics? diagnostics;
  const ReaderPresentation({super.key, required this.child, this.diagnostics});

  static ReaderPresentationState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PresentationScope>()?.owner;

  @override
  State<ReaderPresentation> createState() => ReaderPresentationState();
}

class ReaderPresentationState extends State<ReaderPresentation>
    with WidgetsBindingObserver, RouteAware {
  bool ready = false;
  bool _active = true;
  bool _closed = false;
  bool _showControls = false;
  SystemUiMode? _applied;
  int _metrics = 0;
  int _generation = 0;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_prepare());
  }

  Future<void> _apply(SystemUiMode mode) async {
    if (_applied == mode) return;
    _applied = mode;
    widget.diagnostics?.mark('system_ui_request', {'mode': mode.name});
    try {
      await SystemChrome.setEnabledSystemUIMode(mode);
    } on PlatformException {
      if (_applied == mode) _applied = null;
      widget.diagnostics?.mark('system_ui_failed');
      return;
    }
    widget.diagnostics?.mark('system_ui_applied', {'mode': mode.name});
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    try {
      await _apply(SystemUiMode.immersiveSticky);
      // Metrics can arrive after the platform call returns. Require two stable
      // layouts; bound the handshake so a continuously resizing window can read.
      final elapsed = Stopwatch()..start();
      var stable = 0;
      var previous = _metrics;
      void afterLayout(Duration _) {
        if (!mounted || _closed || generation != _generation) return;
        stable = previous == _metrics ? stable + 1 : 0;
        previous = _metrics;
        if (stable >= 2 || elapsed.elapsedMilliseconds >= 250) {
          widget.diagnostics?.mark('viewport_ready');
          setState(() => ready = true);
        } else {
          WidgetsBinding.instance.addPostFrameCallback(afterLayout);
          WidgetsBinding.instance.scheduleFrame();
        }
      }

      WidgetsBinding.instance.addPostFrameCallback(afterLayout);
      WidgetsBinding.instance.scheduleFrame();
      return;
    } on PlatformException {
      // Fullscreen is best effort; an unsupported host must still render.
    }
    if (!mounted || _closed || generation != _generation) return;
    widget.diagnostics?.mark('viewport_ready');
    setState(() => ready = true);
  }

  void showControls(bool show) {
    _showControls = show;
    if (_closed || !_active) return;
    unawaited(
        _apply(show ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky));
  }

  @override
  void didChangeMetrics() => _metrics++;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route == route) return;
    appRouteObserver.unsubscribe(this);
    _route = route;
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() {
    _active = false;
    unawaited(_apply(SystemUiMode.edgeToEdge));
  }

  @override
  void didPopNext() {
    _active = true;
    showControls(_showControls);
  }

  @override
  void didPop() {
    _closed = true;
    _generation++;
    unawaited(_apply(SystemUiMode.edgeToEdge));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    if (!_closed && _active) unawaited(_apply(SystemUiMode.edgeToEdge));
    _closed = true;
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _PresentationScope(
      owner: this,
      ready: ready,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light, child: widget.child));
}

class _PresentationScope extends InheritedWidget {
  final ReaderPresentationState owner;
  final bool ready;
  const _PresentationScope(
      {required this.owner, required this.ready, required super.child});
  @override
  bool updateShouldNotify(_PresentationScope oldWidget) =>
      ready != oldWidget.ready;
}
