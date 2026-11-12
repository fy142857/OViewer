import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../core/services/floating_back_keyboard.dart';
import '../models/floating_back_settings.dart';

/// Preview is ephemeral: slider motion never writes preferences or rebuilds
/// the application's Navigator. The settings bloc owns only confirmed values.
class FloatingBackPreview extends ValueNotifier<double?> {
  FloatingBackPreview() : super(null);
  Object? _owner;
  bool _disposed = false;
  void set(Object owner, double size) {
    if (_disposed) return;
    _owner = owner;
    value = size;
  }

  void clear(Object owner) {
    if (_disposed || !identical(owner, _owner)) return;
    _owner = null;
    value = null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class FloatingBackScope extends InheritedWidget {
  final FloatingBackPreview preview;
  const FloatingBackScope(
      {super.key, required this.preview, required super.child});
  static FloatingBackPreview? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FloatingBackScope>()?.preview;
  @override
  bool updateShouldNotify(FloatingBackScope oldWidget) =>
      preview != oldWidget.preview;
}

class FloatingBackHost extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final Future<void> Function()? hideKeyboard;
  const FloatingBackHost(
      {super.key,
      required this.navigatorKey,
      required this.child,
      this.hideKeyboard});
  @override
  State<FloatingBackHost> createState() => _FloatingBackHostState();
}

class _FloatingBackHostState extends State<FloatingBackHost> {
  final _preview = FloatingBackPreview();
  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FloatingBackScope(
      preview: _preview,
      child: Stack(fit: StackFit.expand, children: [
        widget.child,
        _FloatingBackLayer(
            navigatorKey: widget.navigatorKey,
            preview: _preview,
            hideKeyboard: widget.hideKeyboard ?? FloatingBackKeyboard.hide),
      ]));
}

/// All geometry is in logical pixels. Keyboard clamping does not change the
/// saved position; a deliberate drag is mapped into the unobstructed rectangle.
class FloatingBackGeometry {
  final Rect base, visible;
  final double hitSize;
  FloatingBackGeometry(Size viewport, MediaQueryData media, double diameter)
      : hitSize = math.max(48, diameter),
        base = _bounds(viewport, media, math.max(48, diameter), false),
        visible = _bounds(viewport, media, math.max(48, diameter), true);

  static Rect _bounds(
      Size size, MediaQueryData media, double hit, bool keyboard) {
    double inset(double safe, double gesture, double ime) =>
        math.max(math.max(safe, gesture), keyboard ? ime : 0) + 12;
    final left = inset(media.viewPadding.left, media.systemGestureInsets.left,
        media.viewInsets.left);
    final top = inset(media.viewPadding.top, media.systemGestureInsets.top,
        media.viewInsets.top);
    final right = size.width -
        inset(media.viewPadding.right, media.systemGestureInsets.right,
            media.viewInsets.right) -
        hit;
    final bottom = size.height -
        inset(media.viewPadding.bottom, media.systemGestureInsets.bottom,
            media.viewInsets.bottom) -
        hit;
    return Rect.fromLTRB(
        left, top, math.max(left, right), math.max(top, bottom));
  }

  Offset constrain(Offset point) => Offset(
      point.dx.clamp(visible.left, visible.right),
      point.dy.clamp(visible.top, visible.bottom));
  Offset position(Offset normalized) => constrain(Offset(
      base.left + normalized.dx * base.width,
      base.top + normalized.dy * base.height));
  Offset normalize(Offset point) => Offset(
      base.width == 0 ? 1 : ((point.dx - base.left) / base.width).clamp(0, 1),
      base.height == 0
          ? .7
          : ((point.dy - base.top) / base.height).clamp(0, 1));
}

class _FloatingBackLayer extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final FloatingBackPreview preview;
  final Future<void> Function() hideKeyboard;
  const _FloatingBackLayer(
      {required this.navigatorKey,
      required this.preview,
      required this.hideKeyboard});
  @override
  State<_FloatingBackLayer> createState() => _FloatingBackLayerState();
}

class _FloatingBackLayerState extends State<_FloatingBackLayer> {
  Offset? _position;
  bool _dragging = false, _returning = false;
  int _interaction = 0;

  void _cancelDrag() {
    if (!mounted) return;
    setState(() {
      _interaction++;
      _dragging = false;
      _position = null;
    });
  }

  Future<void> _back() async {
    if (_dragging || _returning) return;
    _returning = true;
    try {
      if (MediaQuery.viewInsetsOf(context).bottom > 0) {
        await widget.hideKeyboard();
        return;
      }
      // maybePop preserves local history (drawer/sheet) and WillPopScope.
      // A root route bubbles; never forward that to SystemNavigator.pop.
      await widget.navigatorKey.currentState?.maybePop();
    } catch (_) {
      // A keyboard/route guard failure must not become a forced page exit.
    } finally {
      _returning = false;
    }
  }

  Future<void> _savePosition() async {
    _dragging = false;
    final position = _position;
    if (position == null) return;
    final interaction = _interaction;
    final done = Completer<void>();
    context
        .read<SettingsBloc>()
        .add(UpdateFloatingBack(done, x: position.dx, y: position.dy));
    try {
      await done.future;
    } catch (_) {
      if (mounted && interaction == _interaction) {
        final navigator = widget.navigatorKey.currentState;
        if (navigator != null)
          ScaffoldMessenger.maybeOf(navigator.context)?.showSnackBar(
              SnackBar(content: Text(S.of(context).floatingBackSaveFailed)));
      }
    } finally {
      if (mounted && interaction == _interaction && !_dragging)
        setState(() => _position = null);
    }
  }

  @override
  Widget build(BuildContext context) => BlocSelector<SettingsBloc,
          SettingsState, FloatingBackSettings>(
      selector: (state) => state.floatingBack,
      builder: (context, settings) => ValueListenableBuilder<double?>(
          valueListenable: widget.preview,
          builder: (context, preview, _) {
            if (!settings.enabled) return const SizedBox.shrink();
            final size = preview ?? settings.size;
            return LayoutBuilder(builder: (context, constraints) {
              final geometry = FloatingBackGeometry(
                  constraints.biggest, MediaQuery.of(context), size);
              final position = geometry
                  .position(_position ?? Offset(settings.x, settings.y));
              final colors = Theme.of(context).colorScheme;
              final label = S.of(context).floatingBackAction;
              return Stack(children: [
                Positioned(
                    left: position.dx,
                    top: position.dy,
                    child: Semantics(
                      container: true,
                      button: true,
                      label: label,
                      onTap: _back,
                      child: ExcludeSemantics(
                        child: Listener(
                          // Flutter's accepted pan can report onPanEnd for a
                          // cancelled pointer. Clear the draft before it does.
                          onPointerCancel: (_) => _cancelDrag(),
                          child: GestureDetector(
                            key: const ValueKey('floating-back-button'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _back,
                            onPanStart: (_) {
                              _interaction++;
                              _dragging = true;
                              setState(() =>
                                  _position = geometry.normalize(position));
                            },
                            onPanUpdate: (details) => setState(() {
                              final current = geometry.position(
                                  _position ?? Offset(settings.x, settings.y));
                              _position = geometry.normalize(
                                  geometry.constrain(current + details.delta));
                            }),
                            onPanEnd: (_) => _savePosition(),
                            onPanCancel: _cancelDrag,
                            child: SizedBox(
                                width: geometry.hitSize,
                                height: geometry.hitSize,
                                child: Center(
                                    child: Material(
                                  key: const ValueKey('floating-back-circle'),
                                  color: colors.surface.withOpacity(.85),
                                  elevation: 4,
                                  shape: CircleBorder(
                                      side: BorderSide(
                                          color:
                                              colors.outline.withOpacity(.3))),
                                  child: SizedBox(
                                      width: size,
                                      height: size,
                                      child: Icon(Icons.arrow_back,
                                          color: colors.onSurface,
                                          size: math.min(32, size * .5))),
                                ))),
                          ),
                        ),
                      ),
                    ))
              ]);
            });
          }));
}
