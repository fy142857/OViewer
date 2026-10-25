import 'package:flutter/material.dart';
import 'scoped_network_image.dart';
import '../core/network/eh_image_cache_manager.dart';
import '../core/parser/gallery_detail_parser.dart';
import 'sprite_thumbnail.dart';
import 'adaptive_thumbnail_grid.dart';

class ThumbnailGrid extends StatelessWidget {
  final List<ThumbnailInfo> thumbnails;
  final void Function(int index)? onThumbnailTap;

  const ThumbnailGrid({
    super.key,
    required this.thumbnails,
    this.onThumbnailTap,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptiveThumbnailGrid(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: thumbnails.length,
      itemBuilder: (context, index) {
        final thumb = thumbnails[index];
        return GestureDetector(
          onTap: () => onThumbnailTap?.call(index),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: thumb.isSprite
                ? _buildSpriteThumbnail(context, thumb)
                : scopedNetworkImage(
                    imageUrl: thumb.thumbUrl,
                    fit: BoxFit.cover,
                    cacheManager: EhImageCacheManager.instance,
                    placeholder: (_, __) => Container(
                      color: Theme.of(context).colorScheme.surfaceVariant,
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      child: const Icon(Icons.broken_image, size: 20),
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildSpriteThumbnail(BuildContext context, ThumbnailInfo thumb) {
    return SpriteThumbnail(
      thumbnail: thumb,
      image: scopedNetworkImageProvider(thumb.thumbUrl,
          cacheManager: EhImageCacheManager.instance),
      placeholder: (_) =>
          ColoredBox(color: Theme.of(context).colorScheme.surfaceVariant),
      errorBuilder: (_, __, ___) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceVariant,
        child: const Center(child: Icon(Icons.broken_image, size: 20)),
      ),
    );
  }
}
