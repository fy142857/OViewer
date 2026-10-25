import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Cards retain their portrait cover ratio as the available width changes.
class AdaptiveGalleryGrid extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final ScrollPhysics physics;
  final EdgeInsetsGeometry contentPadding;

  const AdaptiveGalleryGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.physics = const AlwaysScrollableScrollPhysics(),
    this.contentPadding = const EdgeInsets.all(8),
  });

  static const spacing = 8.0;
  static const padding = 8.0;

  static int columnCount(double availableWidth, double textScale,
      {double maxItemWidth = 220,
      double horizontalPadding = padding * 2,
      double itemSpacing = spacing}) {
    final maxCardWidth = maxItemWidth * textScale.clamp(1, 2);
    return math.max(
        1,
        ((availableWidth - horizontalPadding + itemSpacing) /
                (maxCardWidth + itemSpacing))
            .ceil());
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final columns = columnCount(
          constraints.maxWidth, MediaQuery.textScaleFactorOf(context));
      return MasonryGridView.count(
        controller: controller,
        physics: physics,
        padding: contentPadding,
        crossAxisCount: columns,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      );
    });
  }
}
