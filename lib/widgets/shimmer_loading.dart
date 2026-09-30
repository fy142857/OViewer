import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import 'adaptive_gallery_grid.dart';

class ShimmerGalleryList extends StatelessWidget {
  final int itemCount;

  const ShimmerGalleryList({super.key, this.itemCount = 8});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark ? Colors.grey[800]! : Colors.grey[300]!,
      highlightColor: isDark ? Colors.grey[700]! : Colors.grey[100]!,
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(8),
        itemCount: itemCount,
        itemBuilder: (_, __) => _buildListItem(),
      ),
    );
  }

  Widget _buildListItem() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 100,
            height: 140,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 60,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  height: 14,
                  color: Colors.white,
                ),
                const SizedBox(height: 4),
                Container(
                  width: 200,
                  height: 14,
                  color: Colors.white,
                ),
                const SizedBox(height: 12),
                Container(
                  width: 120,
                  height: 12,
                  color: Colors.white,
                ),
                const SizedBox(height: 8),
                Container(
                  width: 80,
                  height: 12,
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ShimmerGalleryGrid extends StatelessWidget {
  final int? itemCount;

  const ShimmerGalleryGrid({super.key, this.itemCount});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark ? Colors.grey[800]! : Colors.grey[300]!,
      highlightColor: isDark ? Colors.grey[700]! : Colors.grey[100]!,
      child: LayoutBuilder(builder: (context, constraints) {
        final columns = AdaptiveGalleryGrid.columnCount(
            constraints.maxWidth, MediaQuery.textScaleFactorOf(context));
        return AdaptiveGalleryGrid(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: itemCount ?? columns * 3,
          itemBuilder: (_, __) => _buildGridItem(),
        );
      }),
    );
  }

  Widget _buildGridItem() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          height: 12,
          color: Colors.white,
        ),
        const SizedBox(height: 4),
        Container(
          width: 80,
          height: 12,
          color: Colors.white,
        ),
        const SizedBox(height: 4),
        Container(
          width: 50,
          height: 10,
          color: Colors.white,
        ),
      ],
    );
  }
}
