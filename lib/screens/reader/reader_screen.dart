import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../blocs/reader/reader_bloc.dart';
import '../../blocs/reader/reader_event.dart';
import '../../blocs/reader/reader_state.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../core/network/reader_request_controller.dart';
import '../../core/parser/gallery_detail_parser.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/history_repository.dart';
import '../../repositories/settings_repository.dart';
import '../../core/l10n/s.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/error_widget.dart';

class ReaderScreen extends StatefulWidget {
  final int gid;
  final String token;
  final int initialPage;

  const ReaderScreen({
    super.key,
    required this.gid,
    required this.token,
    this.initialPage = 0,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  int? _resolvedPage;
  late final ReaderRequestController _requests;

  @override
  void initState() {
    super.initState();
    _requests = ReaderRequestController();
    _resolveStartPage();
  }

  @override
  void dispose() {
    _requests.cancel();
    super.dispose();
  }

  Future<void> _resolveStartPage() async {
    var page = widget.initialPage;
    if (page == 0) {
      final progress =
          await GetIt.I<HistoryRepository>().getProgress(widget.gid);
      if (progress != null && progress.lastReadPage > 0) {
        page = progress.lastReadPage;
      }
    }
    if (mounted) {
      setState(() => _resolvedPage = page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _resolvedPage;
    if (page == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: LoadingIndicator(message: S.of(context).loadingReader),
      );
    }
    return BlocProvider(
      create: (_) => ReaderBloc(
        GetIt.I<GalleryRepository>(),
        GetIt.I<HistoryRepository>(),
        GetIt.I<SettingsRepository>(),
        requestController: _requests,
      )..add(LoadReaderImages(
          gid: widget.gid,
          token: widget.token,
          initialPage: page,
        )),
      child: _ReaderView(initialPage: page, requests: _requests),
    );
  }
}

class _ReaderView extends StatefulWidget {
  final int initialPage;
  final ReaderRequestController requests;
  const _ReaderView({
    required this.initialPage,
    required this.requests,
  });

  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView> {
  late PageController _pageController;
  final ItemScrollController _verticalScrollController =
      ItemScrollController();
  final ItemPositionsListener _verticalPositionsListener =
      ItemPositionsListener.create();
  final ScrollController _thumbnailScrollController = ScrollController();
  final TransformationController _zoomController = TransformationController();
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialPage);
    // Immersive mode
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Listen for vertical scroll position changes
    _verticalPositionsListener.itemPositions.addListener(_onVerticalScroll);
    _zoomController.addListener(_onZoomChanged);
  }

  void _onZoomChanged() {
    final scale = _zoomController.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.01;
    if (zoomed != _isZoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _onVerticalScroll() {
    final positions = _verticalPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    // Find the item whose leading edge is closest to (but <= ) the top of the
    // viewport. This avoids jitter caused by two items having nearly equal
    // visible area — the page only advances once the next item's top edge
    // scrolls past the midpoint of the screen.
    final sorted = positions.toList()
      ..sort((a, b) => a.itemLeadingEdge.compareTo(b.itemLeadingEdge));
    // Pick the last item whose leading edge is at or above the 0.5 mark
    // (i.e. its top is in the upper half of the viewport).
    var current = sorted.first;
    for (final pos in sorted) {
      if (pos.itemLeadingEdge <= 0.5) {
        current = pos;
      }
    }
    final bloc = context.read<ReaderBloc>();
    if (current.index != bloc.state.currentPage) {
      bloc.add(PageChanged(current.index));
    }
  }

  @override
  void dispose() {
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _pageController.dispose();
    _thumbnailScrollController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // Each thumbnail is 40px wide + 2px margin on each side = 44px per item
  static const double _thumbItemWidth = 44.0;

  void _scrollThumbnailToCurrentPage(int currentPage, int totalPages) {
    if (!_thumbnailScrollController.hasClients || totalPages == 0) return;
    final maxScroll = _thumbnailScrollController.position.maxScrollExtent;
    // Center the current thumbnail in the visible area
    final viewportWidth = _thumbnailScrollController.position.viewportDimension;
    final targetOffset =
        (currentPage * _thumbItemWidth) - (viewportWidth / 2) + (_thumbItemWidth / 2) + 8; // +8 for horizontal padding
    final clampedOffset = targetOffset.clamp(0.0, maxScroll);
    _thumbnailScrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ReaderBloc, ReaderState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status ||
          prev.readingMode != curr.readingMode ||
          prev.currentPage != curr.currentPage ||
          prev.showUI != curr.showUI,
      listener: (context, state) {
        if (state.showUI) {
          // When UI is re-shown, wait for layout then scroll to current page
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollThumbnailToCurrentPage(state.currentPage, state.totalPages);
          });
        } else {
          _scrollThumbnailToCurrentPage(state.currentPage, state.totalPages);
        }
      },
      builder: (context, state) {
        if (state.status == ReaderStatus.loading) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: LoadingIndicator(message: S.of(context).loadingReader),
          );
        }
        if (state.status == ReaderStatus.error) {
          return Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            body: AppErrorWidget(
              message: state.errorMessage ?? S.of(context).failedToLoadReader,
            ),
          );
        }
        if (state.totalPages == 0) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: Text(S.of(context).noPagesAvailable,
                  style: const TextStyle(color: Colors.white)),
            ),
          );
        }

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // Main content
              GestureDetector(
                onTap: () =>
                    context.read<ReaderBloc>().add(ToggleReaderUI()),
                onDoubleTap: state.readingMode == 2 && _isZoomed
                    ? () => _zoomController.value = Matrix4.identity()
                    : null,
                child: state.readingMode == 2
                    ? _buildVerticalReader(state)
                    : _buildHorizontalReader(state),
              ),
              // Top bar overlay
              if (state.showUI) _buildTopBar(context, state),
              // Bottom slider overlay
              if (state.showUI && state.totalPages > 1)
                _buildBottomBar(context, state),
              // Page indicator (always visible when UI hidden)
              if (!state.showUI) _buildPageIndicator(context, state),
            ],
          ),
        );
      },
    );
  }

  // ---- Horizontal PageView Reader (LR / RL) ----
  Widget _buildHorizontalReader(ReaderState state) {
    return PhotoViewGallery.builder(
      pageController: _pageController,
      itemCount: state.totalPages,
      reverse: state.readingMode == 1, // RTL
      builder: (context, index) {
        final image = state.loadedImages[index];
        if (image == null) {
          // Trigger loading
          context.read<ReaderBloc>().add(LoadImageAtIndex(index));
          return PhotoViewGalleryPageOptions.customChild(
            child: const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          );
        }
        widget.requests.registerImageUrl(image.imageUrl);
        return PhotoViewGalleryPageOptions(
          imageProvider: CachedNetworkImageProvider(
            image.imageUrl,
            cacheManager: EhImageCacheManager.instance,
          ),
          filterQuality: FilterQuality.medium,
          initialScale: PhotoViewComputedScale.contained,
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 3,
          errorBuilder: (_, __, ___) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image,
                    color: Colors.white54, size: 48),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => context
                      .read<ReaderBloc>()
                      .add(RetryImageAtIndex(index)),
                  child: Text(S.of(context).retry,
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
        );
      },
      onPageChanged: (page) {
        context.read<ReaderBloc>().add(PageChanged(page));
      },
      loadingBuilder: (_, __) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  // ---- Vertical Continuous Scroll Reader ----
  Widget _buildVerticalReader(ReaderState state) {
    return InteractiveViewer(
      transformationController: _zoomController,
      minScale: 1.0,
      maxScale: 3.0,
      panEnabled: _isZoomed,
      scaleEnabled: true,
      child: ScrollablePositionedList.builder(
        itemCount: state.totalPages,
        itemScrollController: _verticalScrollController,
        itemPositionsListener: _verticalPositionsListener,
        initialScrollIndex: state.currentPage,
        itemBuilder: (context, index) {
          final image = state.loadedImages[index];
          if (image == null) {
            context.read<ReaderBloc>().add(LoadImageAtIndex(index));
            return SizedBox(
              height: MediaQuery.of(context).size.height * 0.8,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            );
          }

          // Calculate aspect ratio for proper height
          double aspectRatio = image.width > 0 && image.height > 0
              ? image.width / image.height
              : 0.7; // default portrait ratio
          final screenWidth = MediaQuery.of(context).size.width;
          final imageHeight = screenWidth / aspectRatio;
          widget.requests.registerImageUrl(image.imageUrl);

          return SizedBox(
            width: screenWidth,
            height: imageHeight.clamp(200.0, screenWidth * 3),
            child: CachedNetworkImage(
              imageUrl: image.imageUrl,
              fit: BoxFit.fitWidth,
              cacheManager: EhImageCacheManager.instance,
              placeholder: (_, __) => SizedBox(
                height: imageHeight,
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
              errorWidget: (_, __, ___) => SizedBox(
                height: 300,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.broken_image,
                          color: Colors.white54, size: 48),
                      TextButton(
                        onPressed: () => context
                            .read<ReaderBloc>()
                            .add(RetryImageAtIndex(index)),
                        child: Text(S.of(context).retry,
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---- Overlays ----
  Widget _buildTopBar(BuildContext context, ReaderState state) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top,
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                '${state.currentPage + 1} / ${state.totalPages}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            PopupMenuButton<int>(
              icon:
                  const Icon(Icons.auto_stories, color: Colors.white),
              tooltip: S.of(context).readingMode,
              onSelected: (mode) {
                context
                    .read<ReaderBloc>()
                    .add(ChangeReadingMode(mode));
              },
              itemBuilder: (_) {
                final s = S.of(context);
                return [
                  _modeMenuItem(0, s.leftToRight, Icons.arrow_forward,
                      state.readingMode),
                  _modeMenuItem(1, s.rightToLeft, Icons.arrow_back,
                      state.readingMode),
                  _modeMenuItem(2, s.verticalScroll,
                      Icons.swap_vert, state.readingMode),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<int> _modeMenuItem(
      int value, String label, IconData icon, int current) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Text(label),
          if (current == value) ...[
            const Spacer(),
            const Icon(Icons.check, size: 18, color: Colors.blue),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context, ReaderState state) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Thumbnail strip
            if (state.thumbnails.isNotEmpty)
              SizedBox(
                height: 56,
                child: ListView.builder(
                  controller: _thumbnailScrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: state.thumbnails.length,
                  itemBuilder: (_, index) {
                    final thumb = state.thumbnails[index];
                    final isCurrent = index == state.currentPage;
                    return GestureDetector(
                      onTap: () {
                        if (state.readingMode == 2) {
                          _verticalScrollController.jumpTo(index: index);
                        } else {
                          _pageController.jumpToPage(index);
                        }
                      },
                      child: Container(
                        width: 40,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isCurrent
                                ? Colors.blue
                                : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: _buildStripThumbnail(thumb, index),
                        ),
                      ),
                    );
                  },
                ),
              ),
            // Slider row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    '${state.currentPage + 1}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  Expanded(
                    child: Slider(
                      value: state.currentPage
                          .toDouble()
                          .clamp(0, (state.totalPages - 1).toDouble()),
                      min: 0,
                      max: (state.totalPages - 1).toDouble(),
                      divisions:
                          state.totalPages > 1 ? state.totalPages - 1 : 1,
                      onChanged: (value) {
                        final page = value.round();
                        if (state.readingMode == 2) {
                          _verticalScrollController.jumpTo(index: page);
                        } else {
                          _pageController.jumpToPage(page);
                        }
                      },
                    ),
                  ),
                  Text(
                    '${state.totalPages}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageIndicator(BuildContext context, ReaderState state) {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 8,
      right: 16,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '${state.currentPage + 1} / ${state.totalPages}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildStripThumbnail(ThumbnailInfo thumb, int index) {
    if (thumb.thumbUrl.isEmpty) {
      return Container(
        color: Colors.grey[800],
        child: Center(
          child: Text(
            '${index + 1}',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ),
      );
    }
    widget.requests.registerImageUrl(thumb.thumbUrl);

    if (thumb.isSprite) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final cellW = constraints.maxWidth;
          final cellH = constraints.maxHeight;
          final scaleX = cellW / thumb.spriteWidth;
          final scaleY = cellH / thumb.spriteHeight;
          final scale = scaleX > scaleY ? scaleX : scaleY;

          return ClipRect(
            child: SizedBox(
              width: cellW,
              height: cellH,
              child: OverflowBox(
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                alignment: Alignment.topLeft,
                child: Transform.translate(
                  offset: Offset(
                    -thumb.spriteOffsetX * scale,
                    -thumb.spriteOffsetY * scale,
                  ),
                  child: Transform.scale(
                    scale: scale,
                    alignment: Alignment.topLeft,
                    child: CachedNetworkImage(
                      imageUrl: thumb.thumbUrl,
                      cacheManager: EhImageCacheManager.instance,
                      placeholder: (_, __) => Container(
                        color: Colors.grey[800],
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[800],
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 10),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return CachedNetworkImage(
      imageUrl: thumb.thumbUrl,
      fit: BoxFit.cover,
      cacheManager: EhImageCacheManager.instance,
      errorWidget: (_, __, ___) => Container(
        color: Colors.grey[800],
        child: Center(
          child: Text(
            '${index + 1}',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ),
      ),
    );
  }
}
