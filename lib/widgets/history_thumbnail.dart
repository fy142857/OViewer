import 'package:flutter/material.dart';
import 'scoped_network_image.dart';
import 'package:get_it/get_it.dart';
import '../core/network/eh_image_cache_manager.dart';
import '../core/network/offline_image_provider.dart';
import '../models/gallery_source.dart';
import '../models/offline_book.dart';
import '../repositories/offline_repository.dart';

class HistoryThumbnail extends StatelessWidget {
  final int gid;
  final String token;
  final String? source;
  final String thumbUrl;
  const HistoryThumbnail(
      {super.key,
      required this.gid,
      required this.token,
      required this.source,
      required this.thumbUrl});
  Widget _placeholder(BuildContext context) => ColoredBox(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: const Icon(Icons.menu_book, size: 20));
  Widget _online(BuildContext context) => thumbUrl.isEmpty
      ? _placeholder(context)
      : scopedNetworkImage(
          imageUrl: thumbUrl,
          fit: BoxFit.cover,
          cacheManager: EhImageCacheManager.instance,
          errorWidget: (_, __, ___) => _placeholder(context));
  Future<List<OfflineBook>> _local(OfflineRepository repository) async {
    await repository.initialize();
    return repository.matching(gid, token, source: GallerySource.parse(source));
  }

  @override
  Widget build(BuildContext context) {
    if (!GetIt.I.isRegistered<OfflineRepository>()) return _online(context);
    final repository = GetIt.I<OfflineRepository>();
    return FutureBuilder<List<OfflineBook>>(
        future: _local(repository),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return _placeholder(context);
          final books = snapshot.data!;
          if (books.isEmpty) return _online(context);
          // Unknown legacy history must not silently choose one of two origins.
          if (books.length != 1) return _placeholder(context);
          final pages = books.single.pages
              .where((p) => p.status == 'completed' && p.relativePath != null);
          if (pages.isEmpty) return _placeholder(context);
          return Image(
              image: OfflineImageProvider(repository.files, pages.first),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder(context));
        });
  }
}
