import 'dart:math' as math;
import 'dart:ui';

const readerSpreadGap = 4.0;

/// Equal-width pages scaled as a group, capped by the available viewport.
/// The tallest page reaches viewport height unless width is the limiting axis.
List<Size> heightFittedPages(List<double> ratios, Size viewport) {
  if (ratios.isEmpty) return [];
  final width = math.min(viewport.height * ratios.reduce(math.min),
      (viewport.width - readerSpreadGap * (ratios.length - 1)) / ratios.length);
  return [for (final ratio in ratios) Size(width, width / ratio)];
}

/// Fit each page completely, then pack its actual image bounds toward the gutter.
List<Size> compactHorizontalPages(List<double> ratios, Size viewport) {
  final maxWidth =
      (viewport.width - readerSpreadGap * (ratios.length - 1)) / ratios.length;
  return [
    for (final ratio in ratios)
      Size(math.min(maxWidth, viewport.height * ratio),
          math.min(viewport.height, maxWidth / ratio)),
  ];
}
