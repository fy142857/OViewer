import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'reader_route.dart';

/// Ordinary pages retain their system-bar layout while a reader changes the
/// window's fullscreen mode, including the first frames after it is popped.
class AppPageRoute<T> extends MaterialPageRoute<T> {
  final _readerAbove = ValueNotifier<bool>(false);
  AppPageRoute(
      {required super.builder, super.settings, super.allowSnapshotting});

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    _readerAbove.value = nextRoute is ReaderRoute;
    super.didChangeNext(nextRoute);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    _readerAbove.value = false;
    super.didPopNext(nextRoute);
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      _ReaderBackgroundInsets(
          readerAbove: _readerAbove,
          child: Builder(
              builder: (context) =>
                  super.buildPage(context, animation, secondaryAnimation)));

  @override
  void dispose() {
    _readerAbove.dispose();
    super.dispose();
  }
}

class _ReaderBackgroundInsets extends StatefulWidget {
  final ValueNotifier<bool> readerAbove;
  final Widget child;
  const _ReaderBackgroundInsets(
      {required this.readerAbove, required this.child});
  @override
  State<_ReaderBackgroundInsets> createState() =>
      _ReaderBackgroundInsetsState();
}

class _ReaderBackgroundInsetsState extends State<_ReaderBackgroundInsets> {
  MediaQueryData? _last;
  MediaQueryData? _held;

  @override
  void initState() {
    super.initState();
    widget.readerAbove.addListener(_coverageChanged);
  }

  void _coverageChanged() {
    if (widget.readerAbove.value) _held ??= _last;
    // On return, wait for actual restored insets, not an arbitrary delay or
    // just the platform method's acknowledgement.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.readerAbove.removeListener(_coverageChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = MediaQuery.of(context);
    if (_last == null && widget.readerAbove.value) _held = current;
    _last ??= current;
    if (_held != null && _held!.orientation != current.orientation) {
      // A real rotation is a new layout, not a fullscreen inset animation.
      _held = null;
    }
    if (!widget.readerAbove.value &&
        _held?.viewPadding == current.viewPadding) {
      _held = null;
    }
    if (_held == null) {
      _last = current;
      return MediaQuery(data: current, child: widget.child);
    }
    final bars = _held!.viewPadding;
    final keyboard = current.viewInsets;
    return MediaQuery(
      data: current.copyWith(
        viewPadding: bars,
        padding: EdgeInsets.fromLTRB(
            math.max(0, bars.left - keyboard.left),
            math.max(0, bars.top - keyboard.top),
            math.max(0, bars.right - keyboard.right),
            math.max(0, bars.bottom - keyboard.bottom)),
      ),
      child: widget.child,
    );
  }
}
