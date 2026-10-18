import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/constants/app_constants.dart';
import '../core/network/eh_image_cache_manager.dart';
import '../models/gallery_preview.dart';
import 'gallery_status_icons.dart';

class GalleryCard extends StatelessWidget {
  final GalleryPreview gallery;
  final VoidCallback? onTap;

  const GalleryCard({super.key, required this.gallery, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lang = gallery.language;
    final date = '${gallery.postedAt.year}-'
        '${gallery.postedAt.month.toString().padLeft(2, '0')}-'
        '${gallery.postedAt.day.toString().padLeft(2, '0')}';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Thumbnail
              SizedBox(
                width: 100,
                height: 140,
                child: Hero(
                  tag: 'gallery_thumb_${gallery.gid}',
                  child: CachedNetworkImage(
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
                ),
              ),
              // Info
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Category tag
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Color(
                            AppConstants.categoryColors[gallery.category] ??
                                0xFF607D8B,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          gallery.category,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Title
                      Text(
                        gallery.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      // Rating & page count
                      Row(
                        children: [
                          Icon(Icons.star, size: 14, color: Colors.amber[700]),
                          const SizedBox(width: 2),
                          Text(
                            gallery.rating.toStringAsFixed(1),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(width: 12),
                          Icon(Icons.photo,
                              size: 14, color: theme.colorScheme.outline),
                          const SizedBox(width: 2),
                          Text(
                            '${gallery.fileCount}P',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const Spacer(),
                      // Language & date (bottom-right)
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (lang != null)
                                  Padding(
                                    padding: EdgeInsets.only(right: 4),
                                    child: Text(
                                      lang,
                                      style:
                                          theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.outline,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                GalleryStatusIcons(gallery: gallery),
                              ],
                            ),
                            Text(
                              date,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
