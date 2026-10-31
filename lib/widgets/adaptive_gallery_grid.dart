import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Cards follow source order across rows, even when their heights differ.
class AdaptiveGalleryGrid extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController? controller;
  final ScrollPhysics physics;
  final EdgeInsetsGeometry contentPadding;
  final Widget? footer;

  const AdaptiveGalleryGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.physics = const AlwaysScrollableScrollPhysics(),
    this.contentPadding = const EdgeInsets.all(8),
    this.footer,
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
      return CustomScrollView(
        controller: controller,
        physics: physics,
        semanticChildCount: itemCount,
        slivers: [
          SliverPadding(
            padding: contentPadding,
            // The aligned-grid delegate expects at least one row.
            sliver: itemCount == 0
                ? const SliverToBoxAdapter(child: SizedBox.shrink())
                : SliverAlignedGrid.count(
                    crossAxisCount: columns,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    itemCount: itemCount,
                    itemBuilder: itemBuilder,
                  ),
          ),
          // Loading/retry UI must not take a card slot or shift page boundaries.
          if (footer != null) SliverToBoxAdapter(child: footer),
        ],
      );
    });
  }
}
