import '../../models/gallery_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../widgets/scoped_network_image.dart';
import '../../blocs/thumbnail_preview/thumbnail_preview_bloc.dart';
import '../../blocs/thumbnail_preview/thumbnail_preview_event.dart';
import '../../blocs/thumbnail_preview/thumbnail_preview_state.dart';
import '../../repositories/gallery_repository.dart';
import '../../core/l10n/s.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../core/parser/gallery_detail_parser.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/error_widget.dart';
import '../../widgets/sprite_thumbnail.dart';
import '../../widgets/adaptive_thumbnail_grid.dart';

class ThumbnailPreviewScreen extends StatelessWidget {
  final int gid;
  final String token;
  final int fileCount;
  final GallerySource? source;

  const ThumbnailPreviewScreen({
    super.key,
    required this.gid,
    required this.token,
    required this.fileCount,
    this.source,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ThumbnailPreviewBloc(GetIt.I<GalleryRepository>())
        ..add(LoadThumbnailPreview(gid: gid, token: token)),
      child: _ThumbnailPreviewView(
        gid: gid,
        token: token,
        fileCount: fileCount,
        source: source ?? GallerySource.current,
      ),
    );
  }
}

class _ThumbnailPreviewView extends StatefulWidget {
  final int gid;
  final String token;
  final int fileCount;
  final GallerySource? source;

  const _ThumbnailPreviewView({
    required this.gid,
    required this.token,
    required this.fileCount,
    this.source,
  });

  @override
  State<_ThumbnailPreviewView> createState() => _ThumbnailPreviewViewState();
}

class _ThumbnailPreviewViewState extends State<_ThumbnailPreviewView> {
  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification &&
        notification is! OverscrollNotification) {
      return false;
    }
    _requestMore(notification.metrics);
    return false;
  }

  void _requestMore(ScrollMetrics metrics) {
    if (metrics.pixels >= metrics.maxScrollExtent - 300) {
      final bloc = context.read<ThumbnailPreviewBloc>();
      if (bloc.state.status != ThumbnailPreviewStatus.loaded ||
          bloc.state.isLoadingMore ||
          bloc.state.hasReachedEnd) return;
      bloc.add(const LoadMoreThumbnails());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.preview),
            Text(
              s.pagesCount(widget.fileCount),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.7),
                  ),
            ),
          ],
        ),
      ),
      body: BlocBuilder<ThumbnailPreviewBloc, ThumbnailPreviewState>(
        builder: (context, state) {
          if (state.status == ThumbnailPreviewStatus.initial ||
              state.status == ThumbnailPreviewStatus.loading) {
            return LoadingIndicator(message: s.loadingThumbnails);
          }
          if (state.status == ThumbnailPreviewStatus.error) {
            return AppErrorWidget(
              message: state.errorMessage ?? s.failedToLoadThumbnails,
              onRetry: () => context.read<ThumbnailPreviewBloc>().add(
                    LoadThumbnailPreview(
                      gid: widget.gid,
                      token: widget.token,
                    ),
                  ),
            );
          }

          final thumbCount = state.thumbnails.length;
          final hasMore = !state.hasReachedEnd;
          final itemCount = thumbCount + (hasMore ? 1 : 0);

          return NotificationListener<ScrollNotification>(
            onNotification: _handleScrollNotification,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (notification) {
                // A wider viewport may fit the whole batch and cannot scroll.
                if (notification.metrics.maxScrollExtent <= 0 &&
                    identical(
                        context.read<ThumbnailPreviewBloc>().state.thumbnails,
                        state.thumbnails)) {
                  _requestMore(notification.metrics);
                }
                return false;
              },
              child: AdaptiveThumbnailGrid(
                padding: const EdgeInsets.all(8),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  // Loading indicator as the last item
                  if (index >= thumbCount) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }

                  final thumb = state.thumbnails[index];
                  return GestureDetector(
                    onTap: () {
                      Navigator.pushNamed(context, '/reader', arguments: {
                        'gid': widget.gid,
                        'source': widget.source,
                        'token': widget.token,
                        'initialPage': thumb.pageIndex,
                      });
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: thumb.isSprite
                              ? _buildSpriteThumbnail(context, thumb)
                              : scopedNetworkImage(
                                  imageUrl: thumb.thumbUrl,
                                  fit: BoxFit.cover,
                                  cacheManager: EhImageCacheManager.instance,
                                  placeholder: (_, __) => Container(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceVariant,
                                  ),
                                  errorWidget: (_, __, ___) => Container(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceVariant,
                                    child: const Icon(Icons.broken_image,
                                        size: 20),
                                  ),
                                ),
                        ),
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '${thumb.pageIndex + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  /// Renders a single thumbnail from a CSS sprite sheet by clipping
  /// the correct region using the offset and size from [ThumbnailInfo].
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
