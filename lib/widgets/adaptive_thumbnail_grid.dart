import 'package:flutter/material.dart';
import 'adaptive_gallery_grid.dart';

/// Detail and full-preview grids share the card grid's width-based sizing rule.
class AdaptiveThumbnailGrid extends StatelessWidget {
  const AdaptiveThumbnailGrid(
      {super.key,
      required this.itemCount,
      required this.itemBuilder,
      this.shrinkWrap = false,
      this.padding = const EdgeInsets.all(8),
      this.physics = const AlwaysScrollableScrollPhysics()});

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final bool shrinkWrap;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics? physics;
  static const maxThumbnailWidth = 100.0;
  static const spacing = 4.0;
  static const aspectRatio = 0.7;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final columns = AdaptiveGalleryGrid.columnCount(
          constraints.maxWidth,
          MediaQuery.textScaleFactorOf(context),
          maxItemWidth: maxThumbnailWidth,
          horizontalPadding:
              padding.resolve(Directionality.of(context)).horizontal,
          itemSpacing: spacing,
        );
        return GridView.builder(
          shrinkWrap: shrinkWrap,
          primary: shrinkWrap ? false : null,
          physics: physics,
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: aspectRatio,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      });
}
