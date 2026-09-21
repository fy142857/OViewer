import 'package:flutter/material.dart';

import '../core/parser/gallery_detail_parser.dart';

/// Crop in the sprite's original coordinates before fitting the single tile.
/// The sheet must never inherit the destination cell's minimum dimensions:
/// landscape cells can be taller than the original sheet, shifting every crop.
class SpriteThumbnail extends StatelessWidget {
  final ThumbnailInfo thumbnail;
  final ImageProvider image;
  final WidgetBuilder? placeholder;
  final ImageErrorWidgetBuilder? errorBuilder;

  const SpriteThumbnail({
    super.key,
    required this.thumbnail,
    required this.image,
    this.placeholder,
    this.errorBuilder,
  });

  Widget _error(BuildContext context, Object error, StackTrace? stack) =>
      errorBuilder?.call(context, error, stack) ??
      const Center(child: Icon(Icons.broken_image, size: 20));

  @override
  Widget build(BuildContext context) {
    final width = thumbnail.spriteWidth;
    final height = thumbnail.spriteHeight;
    final x = thumbnail.spriteOffsetX;
    final y = thumbnail.spriteOffsetY;
    if (!width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0 ||
        !x.isFinite ||
        !y.isFinite ||
        x < 0 ||
        y < 0) {
      return _error(context, StateError('Invalid thumbnail crop'), null);
    }
    return Image(
      image: image,
      errorBuilder: _error,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame == null) {
          return placeholder?.call(context) ??
              ColoredBox(color: Theme.of(context).colorScheme.surfaceVariant);
        }
        return FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.topLeft,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRect(
              child: OverflowBox(
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                alignment: Alignment.topLeft,
                child: Transform.translate(
                  offset: Offset(-x, -y),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
