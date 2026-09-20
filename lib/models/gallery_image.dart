import 'package:equatable/equatable.dart';

class GalleryImage extends Equatable {
  final int index;
  final String pageUrl;
  final String imageUrl;
  final String? thumbUrl;
  final int width;
  final int height;

  /// Network location key for server failover (from onerror nl('key')).
  /// Append ?nl=key to the image page URL to get an alternate server.
  final String? nlKey;

  const GalleryImage({
    required this.index,
    required this.pageUrl,
    required this.imageUrl,
    this.thumbUrl,
    this.width = 0,
    this.height = 0,
    this.nlKey,
  });

  @override
  List<Object?> get props =>
      [index, pageUrl, imageUrl, thumbUrl, width, height, nlKey];
}
