import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../blocs/auth/auth_bloc.dart';
import '../../blocs/auth/auth_state.dart';
import '../../blocs/gallery_detail/gallery_detail_bloc.dart';
import '../../blocs/gallery_detail/gallery_detail_event.dart';
import '../../blocs/gallery_detail/gallery_detail_state.dart';
import '../../blocs/download/download_bloc.dart';
import '../../blocs/download/download_event.dart';
import '../../blocs/history/history_bloc.dart';
import '../../blocs/history/history_event.dart';
import '../../core/l10n/s.dart';
import '../../models/gallery_detail.dart';
import '../../models/gallery_preview.dart';
import '../../models/gallery_tag.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/favorites_repository.dart';
import '../../models/reading_progress.dart';
import '../../repositories/history_repository.dart';
import '../../core/constants/app_constants.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../core/utils/eh_url_parser.dart';
import '../../core/utils/title_extractor.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/error_widget.dart';
import '../../widgets/rating_bar.dart';
import '../../widgets/tag_chip.dart';
import '../../widgets/thumbnail_grid.dart';
import '../comments/comments_screen.dart';

class GalleryDetailScreen extends StatelessWidget {
  final int gid;
  final String token;

  const GalleryDetailScreen({
    super.key,
    required this.gid,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => GalleryDetailBloc(
            GetIt.I<GalleryRepository>(),
            GetIt.I<FavoritesRepository>(),
          )..add(FetchGalleryDetail(gid: gid, token: token)),
      child: _GalleryDetailView(gid: gid, token: token),
    );
  }
}

class _GalleryDetailView extends StatefulWidget {
  final int gid;
  final String token;

  const _GalleryDetailView({required this.gid, required this.token});

  @override
  State<_GalleryDetailView> createState() => _GalleryDetailViewState();
}

class _GalleryDetailViewState extends State<_GalleryDetailView> {
  ReadingProgress? _readingProgress;

  @override
  void initState() {
    super.initState();
    // Record history visit
    _recordHistory();
    _loadReadingProgress();
  }

  void _loadReadingProgress() async {
    final progress =
        await GetIt.I<HistoryRepository>().getProgress(widget.gid);
    if (mounted) {
      setState(() => _readingProgress = progress);
    }
  }

  void _recordHistory() async {
    // We'll record after detail loads via BlocListener
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocConsumer<GalleryDetailBloc, GalleryDetailState>(
      listener: (context, state) {
        if (state.status == GalleryDetailStatus.loaded &&
            state.detail != null) {
          // Auto-record to history
          final d = state.detail!;
          final preview = GalleryPreview(
            gid: d.gid,
            token: d.token,
            title: d.title,
            thumbUrl: d.thumbUrl,
            category: d.category,
            rating: d.rating,
            uploader: d.uploader,
            fileCount: d.fileCount,
            postedAt: d.postedAt,
          );
          GetIt.I<HistoryRepository>().recordVisit(preview);
          // Refresh history BLoC
          context.read<HistoryBloc>().add(LoadHistory());
        }
      },
      builder: (context, state) {
        if (state.status == GalleryDetailStatus.loading) {
          return Scaffold(
            body: LoadingIndicator(message: s.loadingDetails),
          );
        }
        if (state.status == GalleryDetailStatus.error) {
          return Scaffold(
            appBar: AppBar(),
            body: AppErrorWidget(
              message: state.errorMessage ?? s.failedToLoad,
              onRetry: () => context.read<GalleryDetailBloc>().add(
                    FetchGalleryDetail(
                        gid: widget.gid, token: widget.token),
                  ),
            ),
          );
        }

        final detail = state.detail;
        if (detail == null) {
          return Scaffold(appBar: AppBar());
        }

        return Scaffold(
          body: CustomScrollView(
            slivers: [
              // App bar with cover image
              _buildSliverAppBar(context, detail),
              // Content
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTitleSection(context, detail),
                      const SizedBox(height: 16),
                      _buildMetaSection(context, detail),
                      const SizedBox(height: 16),
                      _buildActionButtons(context, detail),
                      const SizedBox(height: 20),
                      _buildSimilarGalleriesButton(context, detail),
                      const SizedBox(height: 20),
                      _buildTagSection(context, detail),
                      const SizedBox(height: 20),
                      _buildThumbnailSection(context, detail),
                      const SizedBox(height: 20),
                      _buildCommentSection(context, detail),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSliverAppBar(BuildContext context, GalleryDetail detail) {
    return SliverAppBar(
      expandedHeight: 250,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: 'gallery_thumb_${detail.gid}',
              child: CachedNetworkImage(
                imageUrl: detail.thumbUrl,
                fit: BoxFit.cover,
                cacheManager: EhImageCacheManager.instance,
                errorWidget: (_, __, ___) => Container(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                ),
              ),
            ),
            // Gradient overlay
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: const [],
    );
  }

  Widget _buildTitleSection(BuildContext context, GalleryDetail detail) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Color(
              AppConstants.categoryColors[detail.category] ?? 0xFF607D8B,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            detail.category,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Title
        SelectableText(detail.title, style: theme.textTheme.titleLarge),
        if (detail.titleJpn != null && detail.titleJpn != detail.title) ...[
          const SizedBox(height: 4),
          SelectableText(
            detail.titleJpn!,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMetaSection(BuildContext context, GalleryDetail detail) {
    final theme = Theme.of(context);
    final s = S.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Rating row
            Row(
              children: [
                GestureDetector(
                  onTap: () => _showRatingDialog(context, detail),
                  child: RatingBar(rating: detail.rating),
                ),
                const SizedBox(width: 8),
                Text(
                  detail.rating.toStringAsFixed(2),
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(width: 4),
                Text(
                  '(${detail.ratingCount})',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                Icon(Icons.favorite,
                    size: 16, color: theme.colorScheme.outline),
                const SizedBox(width: 4),
                Text('${detail.favoriteCount}'),
              ],
            ),
            const Divider(height: 16),
            // Info rows
            _metaRow(Icons.person, s.uploader, detail.uploader),
            _metaRow(Icons.language, s.languageLabel, detail.language),
            _metaRow(Icons.photo_library, s.pages,
                s.pagesCount(detail.fileCount)),
            _metaRow(Icons.access_time, s.posted,
                _formatDate(detail.postedAt)),
            if (detail.fileSize > 0)
              _metaRow(Icons.storage, s.size,
                  _formatFileSize(detail.fileSize)),
          ],
        ),
      ),
    );
  }

  Widget _metaRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, GalleryDetail detail) {
    final s = S.of(context);
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () async {
              await Navigator.pushNamed(context, '/reader', arguments: {
                'gid': widget.gid,
                'token': widget.token,
              });
              _loadReadingProgress();
            },
            icon: const Icon(Icons.auto_stories),
            label: Text(_readingProgress != null &&
                    _readingProgress!.lastReadPage > 0
                ? 'P.${_readingProgress!.lastReadPage + 1} / ${_readingProgress!.totalPages}'
                : s.read),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          onPressed: () => _toggleFavorite(context, detail),
          icon: Icon(
            detail.isFavorited ? Icons.favorite : Icons.favorite_border,
            size: 20,
            color: detail.isFavorited ? Colors.red : null,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(s.startDownloadConfirm),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(s.cancel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(s.download),
                  ),
                ],
              ),
            );
            if (confirmed != true || !context.mounted) return;
            context.read<DownloadBloc>().add(StartDownload(
                  gid: detail.gid,
                  token: detail.token,
                  title: detail.title,
                  thumbUrl: detail.thumbUrl,
                  totalPages: detail.fileCount,
                ));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(s.downloadStarted)),
            );
          },
          icon: const Icon(Icons.download, size: 20),
          tooltip: s.download,
        ),
      ],
    );
  }

  Widget _buildTagSection(BuildContext context, GalleryDetail detail) {
    if (detail.tags.isEmpty) return const SizedBox.shrink();

    final s = S.of(context);

    // Group tags by namespace
    final grouped = <String, List<GalleryTag>>{};
    for (final tag in detail.tags) {
      grouped.putIfAbsent(tag.namespace, () => []).add(tag);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.tags, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...grouped.entries.map((entry) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      '${entry.key}:',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                  ),
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: entry.value
                          .map((tag) => TagChip(
                                tag: tag,
                                onTap: () {
                                  Navigator.pushNamed(
                                    context,
                                    '/search',
                                    arguments:
                                        '${tag.namespace}:"${tag.key}\$"',
                                  );
                                },
                              ))
                          .toList(),
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }

  Widget _buildThumbnailSection(
      BuildContext context, GalleryDetail detail) {
    final displayThumbs = detail.thumbnails.length > 20
        ? detail.thumbnails.sublist(0, 20)
        : detail.thumbnails;

    final s = S.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            Navigator.pushNamed(context, '/thumbnail_preview', arguments: {
              'gid': widget.gid,
              'token': widget.token,
              'fileCount': detail.fileCount,
            });
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(s.preview,
                  style: Theme.of(context).textTheme.titleMedium),
              Row(
                children: [
                  Text(
                    s.pagesCount(detail.fileCount),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (displayThumbs.isNotEmpty) ...[
          const SizedBox(height: 8),
          ThumbnailGrid(
            thumbnails: displayThumbs,
            onThumbnailTap: (index) async {
              await Navigator.pushNamed(context, '/reader', arguments: {
                'gid': widget.gid,
                'token': widget.token,
                'initialPage': detail.thumbnails[index].pageIndex,
              });
              _loadReadingProgress();
            },
          ),
        ],
      ],
    );
  }

  Widget _buildSimilarGalleriesButton(
      BuildContext context, GalleryDetail detail) {
    final s = S.of(context);
    return ListTile(
      leading: const Icon(Icons.find_in_page),
      title: Text(s.similarGalleries),
      trailing: const Icon(Icons.chevron_right),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      onTap: () {
        final coreTitle = TitleExtractor.extractCoreTitle(detail.title);
        Navigator.pushNamed(context, '/search', arguments: {
          'keyword': coreTitle,
          'saveHistory': false,
        });
      },
    );
  }

  Widget _buildCommentSection(
      BuildContext context, GalleryDetail detail) {
    if (detail.comments.isEmpty) return const SizedBox.shrink();

    final s = S.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.comments(detail.comments.length),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...detail.comments.take(5).map((comment) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          comment.author,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: comment.isUploader
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                    : null,
                              ),
                        ),
                        if (comment.isUploader) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              s.uploaderBadge,
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (comment.score != 0)
                          Text(
                            comment.score > 0
                                ? '+${comment.score}'
                                : '${comment.score}',
                            style: TextStyle(
                              fontSize: 12,
                              color: comment.score > 0
                                  ? Colors.green
                                  : Colors.red,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Render comment with clickable gallery links
                    _buildCommentContent(context, comment.content),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          _formatDate(comment.postedAt),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () {
                            context.read<GalleryDetailBloc>().add(VoteComment(
                                  gid: detail.gid,
                                  token: detail.token,
                                  commentId: comment.id,
                                  isUpvote: true,
                                ));
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(Icons.thumb_up_outlined,
                                size: 14,
                                color: Theme.of(context).colorScheme.outline),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () {
                            context.read<GalleryDetailBloc>().add(VoteComment(
                                  gid: detail.gid,
                                  token: detail.token,
                                  commentId: comment.id,
                                  isUpvote: false,
                                ));
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(Icons.thumb_down_outlined,
                                size: 14,
                                color: Theme.of(context).colorScheme.outline),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )),
        if (detail.comments.length > 5)
          Center(
            child: TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BlocProvider.value(
                      value: context.read<GalleryDetailBloc>(),
                      child: CommentsScreen(
                        gid: detail.gid,
                        token: detail.token,
                        comments: detail.comments,
                      ),
                    ),
                  ),
                );
              },
              child: Text(
                  s.viewAllComments(detail.comments.length)),
            ),
          ),
      ],
    );
  }

  void _toggleFavorite(BuildContext context, GalleryDetail detail) {
    final authStatus = context.read<AuthBloc>().state.status;
    if (authStatus == AuthStatus.unauthenticated) {
      final s = S.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.loginToFavorite)),
      );
      return;
    }
    context.read<GalleryDetailBloc>().add(
          ToggleFavorite(gid: detail.gid, token: detail.token),
        );
  }

  /// Build comment content with clickable E-Hentai/ExHentai gallery links.
  Widget _buildCommentContent(BuildContext context, String html) {
    final plainText = _stripHtml(html);
    final style = Theme.of(context).textTheme.bodyMedium!;
    final linkStyle = style.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );

    // Match gallery URLs in the plain text
    final urlRegex = RegExp(
      r'https?://(?:e-hentai|exhentai)\.org/g/\d+/[a-f0-9]+/?',
    );

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in urlRegex.allMatches(plainText)) {
      // Text before this link
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: plainText.substring(lastEnd, match.start)));
      }
      // The link itself
      final url = match.group(0)!;
      final parsed = EhUrlParser.parseGalleryUrl(url);
      spans.add(TextSpan(
        text: url,
        style: linkStyle,
        recognizer: parsed != null
            ? (TapGestureRecognizer()
              ..onTap = () {
                Navigator.pushNamed(context, '/gallery', arguments: {
                  'gid': parsed.$1,
                  'token': parsed.$2,
                });
              })
            : null,
      ));
      lastEnd = match.end;
    }

    // Remaining text after last link
    if (lastEnd < plainText.length) {
      spans.add(TextSpan(text: plainText.substring(lastEnd)));
    }

    if (spans.isEmpty) {
      return Text(plainText, style: style, maxLines: 6, overflow: TextOverflow.ellipsis);
    }

    return RichText(
      text: TextSpan(style: style, children: spans),
      maxLines: 6,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _stripHtml(String html) {
    // Preserve href URLs from <a> tags: replace <a href="URL">text</a> with "text (URL)"
    // but only for E-Hentai/ExHentai gallery links where text != URL
    final withLinks = html.replaceAllMapped(
      RegExp(r'<a\s[^>]*href="(https?://(?:e-hentai|exhentai)\.org/g/[^"]+)"[^>]*>(.*?)</a>', caseSensitive: false),
      (m) {
        final href = m.group(1)!;
        final text = m.group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        // If link text already contains the URL, don't duplicate
        if (text.contains('e-hentai.org/g/') || text.contains('exhentai.org/g/')) {
          return text;
        }
        return '$text $href';
      },
    );
    return withLinks
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatFileSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  void _showRatingDialog(BuildContext context, GalleryDetail detail) {
    final s = S.of(context);
    double selectedRating = detail.rating;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(s.rateGallery),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  final starVal = (i + 1).toDouble();
                  return GestureDetector(
                    onTap: () =>
                        setDialogState(() => selectedRating = starVal),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        selectedRating >= starVal
                            ? Icons.star
                            : (selectedRating >= starVal - 0.5
                                ? Icons.star_half
                                : Icons.star_border),
                        size: 36,
                        color: Colors.amber,
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 8),
              Text('${selectedRating.toStringAsFixed(1)} / 5.0'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () {
                context.read<GalleryDetailBloc>().add(RateGallery(
                      gid: detail.gid,
                      token: detail.token,
                      rating: selectedRating,
                    ));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(
                          s.rated(selectedRating.toStringAsFixed(1)))),
                );
              },
              child: Text(s.submit),
            ),
          ],
        ),
      ),
    );
  }
}
