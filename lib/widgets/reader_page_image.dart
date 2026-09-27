import 'package:flutter/material.dart';

/// A download progress event is not a decoded frame. Keep a visible placeholder
/// while reading cached bytes, waiting for headers, or decoding the first frame.
class ReaderPageImage extends StatelessWidget {
  final ImageProvider image;
  final ImageErrorWidgetBuilder errorBuilder;

  const ReaderPageImage(
      {super.key, required this.image, required this.errorBuilder});

  @override
  Widget build(BuildContext context) => Image(
        key: ValueKey(image),
        image: image,
        fit: BoxFit.fitWidth,
        frameBuilder: (context, child, frame, synchronouslyLoaded) =>
            synchronouslyLoaded || frame != null
                ? child
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white)),
        errorBuilder: errorBuilder,
      );
}
