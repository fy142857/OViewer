import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Keeps Material drawer gestures, focus and local history while running only
/// its settling animation at twice the normal speed. Drag tracking is unchanged.
class FastDrawerController extends DrawerController {
  const FastDrawerController({
    super.key,
    required super.child,
    super.drawerCallback,
    super.isDrawerOpen,
  }) : super(alignment: DrawerAlignment.start);

  @override
  DrawerControllerState createState() => _FastDrawerControllerState();
}

class _FastDrawerControllerState extends DrawerControllerState {
  @override
  Ticker createTicker(TickerCallback onTick) =>
      super.createTicker((elapsed) => onTick(elapsed * 2));
}
