import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Flutter 3.13–3.16 fixes showMenu at 300 ms. Keep reader menus local to a
/// 150 ms popup route instead of changing the SDK or global animation timing.
Future<T?> showReaderMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  required BoxConstraints constraints,
  Color? color,
  Color? surfaceTintColor,
  ShapeBorder? shape,
  EdgeInsetsGeometry menuPadding = const EdgeInsets.symmetric(vertical: 8),
}) {
  assert(items.isNotEmpty);
  final navigator = Navigator.of(context);
  return navigator.push<T>(ReaderMenuRoute<T>(
    position: position,
    items: items,
    constraints: constraints,
    color: color,
    surfaceTintColor: surfaceTintColor,
    shape: shape,
    menuPadding: menuPadding,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierLabel: MaterialLocalizations.of(context).menuDismissLabel,
    semanticLabel: MaterialLocalizations.of(context).popupMenuLabel,
  ));
}

class ReaderMenuRoute<T> extends PopupRoute<T> {
  ReaderMenuRoute({
    required this.position,
    required this.items,
    required this.constraints,
    required this.themes,
    required this.barrierLabel,
    required this.semanticLabel,
    required this.menuPadding,
    this.color,
    this.surfaceTintColor,
    this.shape,
  })  : assert(items.isNotEmpty),
        super(traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);

  final RelativeRect position;
  final List<PopupMenuEntry<T>> items;
  final BoxConstraints constraints;
  final CapturedThemes themes;
  final String semanticLabel;
  final Color? color;
  final Color? surfaceTintColor;
  final ShapeBorder? shape;
  final EdgeInsetsGeometry menuPadding;
  CurvedAnimation? _menuAnimation;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);
  @override
  bool get barrierDismissible => true;
  @override
  Color? get barrierColor => null;
  @override
  final String barrierLabel;

  @override
  Animation<double> createAnimation() => _menuAnimation = CurvedAnimation(
      parent: super.createAnimation(),
      curve: Curves.linear,
      reverseCurve: const Interval(0, 2 / 3));

  @override
  void dispose() {
    _menuAnimation?.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final media = MediaQuery.of(context);
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: CustomSingleChildLayout(
        delegate: _ReaderMenuPosition(
            position,
            media.padding,
            Directionality.of(context),
            DisplayFeatureSubScreen.avoidBounds(media).toSet()),
        child: themes.wrap(Builder(builder: (context) {
          final theme = Theme.of(context);
          final popupTheme = PopupMenuTheme.of(context);
          final unit = 1 / (items.length + 1.5);
          Animation<double> interval(double from, double to) =>
              animation.drive(CurveTween(curve: Interval(from, to)));
          final content = ConstrainedBox(
            constraints: constraints,
            child: IntrinsicWidth(
              stepWidth: 56,
              child: Semantics(
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                label: semanticLabel,
                child: SingleChildScrollView(
                  padding: menuPadding,
                  child: ListBody(children: [
                    for (var i = 0; i < items.length; i++)
                      FadeTransition(
                          opacity: interval(
                              (i + 1) * unit, math.min(1.0, (i + 2.5) * unit)),
                          child: items[i]),
                  ]),
                ),
              ),
            ),
          );
          return AnimatedBuilder(
            animation: animation,
            child: content,
            builder: (context, child) => FadeTransition(
              opacity: interval(0, 1 / 3),
              child: Material(
                type: MaterialType.card,
                color: color ?? popupTheme.color ?? theme.colorScheme.surface,
                surfaceTintColor:
                    surfaceTintColor ?? popupTheme.surfaceTintColor,
                shadowColor: popupTheme.shadowColor ?? theme.colorScheme.shadow,
                elevation: popupTheme.elevation ?? (theme.useMaterial3 ? 3 : 8),
                shape: shape ??
                    popupTheme.shape ??
                    const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(4))),
                child: Align(
                    alignment: AlignmentDirectional.topEnd,
                    widthFactor: (animation.value / unit).clamp(0.0, 1.0),
                    heightFactor: (animation.value / (unit * items.length))
                        .clamp(0.0, 1.0),
                    child: child),
              ),
            ),
          );
        })),
      ),
    );
  }
}

class _ReaderMenuPosition extends SingleChildLayoutDelegate {
  _ReaderMenuPosition(this.anchor, this.padding, this.direction, this.avoid);
  final RelativeRect anchor;
  final EdgeInsets padding;
  final TextDirection direction;
  final Set<Rect> avoid;

  Rect _screen(Size size) {
    final origin = anchor.toRect(Offset.zero & size).center;
    final screens =
        DisplayFeatureSubScreen.subScreensInBounds(Offset.zero & size, avoid)
            .toList()
          ..sort((a, b) => (a.center - origin)
              .distanceSquared
              .compareTo((b.center - origin).distanceSquared));
    final screen = screens.first;
    return Rect.fromLTWH(
        screen.left + padding.left + 8,
        screen.top + padding.top + 8,
        math.max(0, screen.width - padding.horizontal - 16),
        math.max(0, screen.height - padding.vertical - 16));
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final screen = _screen(constraints.biggest);
    return BoxConstraints(
        maxWidth: screen.width,
        maxHeight: screen.bottom - anchor.top.clamp(screen.top, screen.bottom));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final screen = _screen(size);
    final right = anchor.left > anchor.right ||
        (anchor.left == anchor.right && direction == TextDirection.rtl);
    final x = right ? size.width - anchor.right - childSize.width : anchor.left;
    return Offset(
        x.clamp(
            screen.left, math.max(screen.left, screen.right - childSize.width)),
        anchor.top.clamp(screen.top,
            math.max(screen.top, screen.bottom - childSize.height)));
  }

  @override
  bool shouldRelayout(_ReaderMenuPosition oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      direction != oldDelegate.direction ||
      avoid != oldDelegate.avoid;
}
