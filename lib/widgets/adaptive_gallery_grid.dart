import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Cards retain their portrait cover ratio as the available width changes.
class AdaptiveGalleryGrid extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;

  const AdaptiveGalleryGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const spacing = 8.0;
      const padding = 8.0;
      final maxCardWidth =
          220 * MediaQuery.textScaleFactorOf(context).clamp(1, 2);
      final columns = math.max(
          1,
          ((constraints.maxWidth - padding * 2 + spacing) /
                  (maxCardWidth + spacing))
              .ceil());
      return MasonryGridView.count(
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(padding),
        crossAxisCount: columns,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      );
    });
  }
}
