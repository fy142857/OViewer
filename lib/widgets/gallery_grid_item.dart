import 'package:flutter/material.dart';
import 'scoped_network_image.dart';
import '../core/constants/app_constants.dart';
import '../core/network/eh_image_cache_manager.dart';
import '../models/gallery_preview.dart';
import 'gallery_status_icons.dart';

class GalleryGridItem extends StatelessWidget {
  final GalleryPreview gallery;
  final VoidCallback? onTap;

  const GalleryGridItem({super.key, required this.gallery, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final language = gallery.language?.trim();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Portrait covers keep the same proportions on phones and tablets.
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  scopedNetworkImage(
                    imageUrl: gallery.thumbUrl,
                    fit: BoxFit.cover,
                    cacheManager: EhImageCacheManager.instance,
                    placeholder: (_, __) => Container(
                      color: theme.colorScheme.surfaceVariant,
                      child: const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: theme.colorScheme.surfaceVariant,
                      child: const Icon(Icons.broken_image),
                    ),
                  ),
                  // Category badge
                  Positioned(
                    top: 4,
                    left: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Color(
                          AppConstants.categoryColors[gallery.category] ??
                              0xFF607D8B,
                        ).withOpacity(0.9),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        gallery.category,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child:
                        GalleryStatusIcons(gallery: gallery, decorated: true),
                  ),
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _badge(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.photo,
                                  size: 10, color: Colors.white70),
                              const SizedBox(width: 2),
                              Text('${gallery.fileCount}'),
                            ],
                          ),
                        ),
                        if (language != null && language.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          _badge(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.language,
                                    size: 10, color: Colors.white70),
                                const SizedBox(width: 2),
                                Text(language),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Info
            Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    gallery.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.star, size: 12, color: Colors.amber[700]),
                      const SizedBox(width: 2),
                      Text(
                        gallery.rating.toStringAsFixed(1),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(3),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 10),
          child: child,
        ),
      );
}
