import 'package:flutter/material.dart';

/// A download progress event is not a decoded frame. Keep a visible placeholder
/// while reading cached bytes, waiting for headers, or decoding the first frame.
class ReaderPageImage extends StatefulWidget {
  final ImageProvider image;
  final ImageErrorWidgetBuilder errorBuilder;
  final double? loadingHeight;
  final BoxFit fit;
  final ValueChanged<Size>? onDecodedSize;

  const ReaderPageImage(
      {super.key,
      required this.image,
      required this.errorBuilder,
      this.loadingHeight,
      this.fit = BoxFit.fitWidth,
      this.onDecodedSize});

  @override
  State<ReaderPageImage> createState() => _ReaderPageImageState();
}

class _ReaderPageImageState extends State<ReaderPageImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _reported;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(ReaderPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        (oldWidget.onDecodedSize == null) != (widget.onDecodedSize == null))
      _listen();
  }

  void _listen() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _listener = null;
    _stream = null;
    _reported = null;
    final generation = ++_generation;
    if (widget.onDecodedSize == null) return;
    _stream = widget.image.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener((info, _) {
      final size =
          Size(info.image.width.toDouble(), info.image.height.toDouble());
      info.dispose();
      if (_reported == size) return;
      _reported = size;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _generation)
          widget.onDecodedSize?.call(size);
      });
    }, onError: (Object _, StackTrace? __) {});
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    ++_generation;
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(
        key: ValueKey(widget.image),
        image: widget.image,
        fit: widget.fit,
        frameBuilder: (context, child, frame, synchronouslyLoaded) =>
            synchronouslyLoaded || frame != null
                ? child
                : SizedBox(
                    height: widget.loadingHeight,
                    child: const Center(
                        child: CircularProgressIndicator(color: Colors.white))),
        errorBuilder: widget.errorBuilder,
      );
}
