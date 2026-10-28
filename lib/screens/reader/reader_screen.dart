import '../../widgets/reader_image_layout.dart';
import '../../widgets/reader_scroll_physics.dart';
import '../../models/reader_page_layout.dart';
import '../../blocs/settings/settings_bloc.dart';
import '../../blocs/settings/settings_state.dart';
import '../../widgets/reader_settings_menu.dart';
import '../../widgets/reader_preload_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../blocs/reader/reader_bloc.dart';
import '../../blocs/reader/reader_event.dart';
import '../../blocs/reader/reader_state.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../core/network/reader_request_controller.dart';
import '../../core/network/reader_image_provider.dart';
import '../../core/network/reader_preload_controller.dart';
import '../../core/storage/reader_reentry_cache.dart';
import '../../core/network/cookie_manager.dart' as app;
import '../../core/router/route_observer.dart';
import '../../core/parser/gallery_detail_parser.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/history_repository.dart';
import '../../repositories/settings_repository.dart';
import '../../core/l10n/s.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/error_widget.dart';
import '../../widgets/sprite_thumbnail.dart';
import '../../widgets/reader_page_image.dart';
import '../../core/services/page_image_exporter.dart';
import '../../models/reader_page_resource.dart';
import '../../widgets/reader_page_menu.dart';
import '../../widgets/gallery_warning_view.dart';
import '../../core/network/offline_image_provider.dart';
import '../../core/services/offline_download_coordinator.dart';
import '../../models/offline_book.dart';
import '../../core/services/reader_entry_diagnostics.dart';
import '../../core/storage/offline_entry_read.dart';
import '../../widgets/reader_presentation.dart';
import 'dart:async';
import '../../repositories/offline_repository.dart';

class ReaderScreen extends StatefulWidget {
  final int gid;
  final String token;
  final int? initialPage;
  final OfflineBook? offlineBook;
  final OfflineEntryRead? initialRead;
  final ReaderEntryDiagnostics? diagnostics;

  const ReaderScreen({
    super.key,
    required this.gid,
    required this.token,
    this.initialPage,
    this.offlineBook,
    this.initialRead,
    this.diagnostics,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with RouteAware {
  final _startup = Stopwatch();
  late ReaderRequestController _requests;

  @override
  void initState() {
    super.initState();
    _requests = ReaderRequestController();
    _startup.start();
    widget.diagnostics?.mark('reader_created');
    if (const bool.fromEnvironment('READER_DIAGNOSTICS')) {
      debugPrint('[reader-metric] enter');
    }
  }

  @override
  void didUpdateWidget(ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gid != widget.gid ||
        oldWidget.token != widget.token ||
        oldWidget.initialPage != widget.initialPage) {
      // A new preview selection is a new reading session even when Flutter
      // reuses this route's widget. Old work must not restore its position.
      _requests.cancel();
      _requests = ReaderRequestController();
      _startup
        ..reset()
        ..start();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPop() {
    // Route disposal waits for the exit animation. Stop network work as soon
    // as the pop is accepted, including the system back and iOS swipe gesture.
    _requests.cancel();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _requests.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presentation = ReaderPresentation.maybeOf(context);
    if (presentation == null) {
      return ReaderPresentation(
          diagnostics: widget.diagnostics,
          child: Builder(builder: (context) => _buildReader(context)));
    }
    return _buildReader(context);
  }

  Widget _buildReader(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: BlocProvider(
        key: ObjectKey(_requests),
        create: (_) => ReaderBloc(
          GetIt.I<GalleryRepository>(),
          GetIt.I<HistoryRepository>(),
          GetIt.I<SettingsRepository>(),
          requestController: _requests,
          offlineBook: widget.offlineBook,
          offlineRepository:
              widget.offlineBook == null ? null : GetIt.I<OfflineRepository>(),
          initialRequest: LoadReaderImages(
              gid: widget.gid,
              token: widget.token,
              initialPage: widget.initialPage),
        )..add(LoadReaderImages(
            gid: widget.gid,
            token: widget.token,
            initialPage: widget.initialPage,
          )),
        child: BlocListener<SettingsBloc, SettingsState>(
          listenWhen: (previous, current) =>
              previous.readingMode != current.readingMode ||
              previous.preloadCount != current.preloadCount ||
              previous.pageLayout != current.pageLayout ||
              previous.spreadAlignment != current.spreadAlignment,
          listener: (context, settings) => context.read<ReaderBloc>().add(
              ChangeReaderPreferences(settings.readingMode, settings.pageLayout,
                  alignment: settings.spreadAlignment,
                  preloadCount: settings.preloadCount)),
          child: _ReaderView(
              startup: _startup,
              requests: _requests,
              diagnostics: widget.diagnostics,
              initialRead: widget.initialRead),
        ),
      ),
    );
  }
}

class _ReaderView extends StatefulWidget {
  final OfflineEntryRead? initialRead;
  final ReaderEntryDiagnostics? diagnostics;
  final Stopwatch startup;
  final ReaderRequestController requests;
  const _ReaderView({
    required this.startup,
    required this.requests,
    this.diagnostics,
    this.initialRead,
  });

  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView> {
  late PageController _pageController;
  final ItemScrollController _verticalScrollController = ItemScrollController();
  final ItemPositionsListener _verticalPositionsListener =
      ItemPositionsListener.create();
  final ScrollController _thumbnailScrollController = ScrollController();
  final TransformationController _zoomController = TransformationController();
  bool _isZoomed = false;
  late final FileService _imageFiles;
  final Map<String, int> _thumbnailAttempts = {};
  final Map<int, (ReaderRequestController, FileService)> _pageFiles = {};
  late final ReaderPreloadController _preload;
  bool _preloadRebuildQueued = false;
  bool _preloadSyncQueued = false;
  final _savingPages = ValueNotifier<Set<int>>({});
  bool _pageMenuOpen = false;
  ModalRoute<Object?>? _pageMenuRoute;
  final _offlineProviders = <OfflineImageProvider>{};
  final _entryImageReady = Completer<void>();
  late int _entryPage;
  void _releaseEntryPriority() {
    if (!_entryImageReady.isCompleted) _entryImageReady.complete();
  }

  bool _positionInitialized = false;
  bool _firstImageLogged = false;
  int? _lastReadingMode;
  ReaderPageLayout? _lastPageLayout;
  ReaderSpreadAlignment? _lastSpreadAlignment;
  final _pageAspectRatios = <(int, int), double>{};
  Size? _viewport;
  int? _sliderPage;
  int? _explicitPage;
  PageStorageBucket _scrollStorage = PageStorageBucket();

  @override
  void initState() {
    super.initState();
    final initial = context.read<ReaderBloc>().state;
    _preload = ReaderPreloadController(load: _preloadImage)
      ..addListener(_preloadChanged);
    widget.requests.onCancel(_preload.dispose);
    _entryPage = initial.currentPage;
    _explicitPage = initial.currentPage;
    widget.requests.onCancel(_releaseEntryPriority);
    _pageController = PageController(
        initialPage: initial.spreads.spreadOf(initial.currentPage),
        keepPage: false);
    if (initial.offlineBook != null) {
      _explicitPage = initial.currentPage;
      _positionInitialized = true;
      _lastReadingMode = initial.readingMode;
      _lastPageLayout = initial.pageLayout;
      _lastSpreadAlignment = initial.spreadAlignment;
    }
    _imageFiles = EhImageCacheManager.readerFileService(
      GetIt.I<app.CookieManager>(),
      widget.requests,
      imageScope: context.read<ReaderBloc>().imageScope,
    );
    // Listen for vertical scroll position changes
    _verticalPositionsListener.itemPositions.addListener(_onVerticalScroll);
    _zoomController.addListener(_onZoomChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewport = MediaQuery.sizeOf(context);
    if (_viewport != null && _viewport != viewport) {
      _explicitPage = context.read<ReaderBloc>().state.currentPage;
      _scrollStorage = PageStorageBucket();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _zoomController.value = Matrix4.identity();
      });
    }
    _viewport = viewport;
  }

  void _jumpToPage(int page) {
    final bloc = context.read<ReaderBloc>();
    _explicitPage = page;
    bloc.add(PageChanged(page));
    final spread = bloc.state.spreads.spreadOf(page);
    if (bloc.state.readingMode == 2) {
      _verticalScrollController.jumpTo(index: spread);
    } else {
      _pageController.jumpToPage(spread);
    }
  }

  Widget _spreadRow(ReaderState state, int spread,
      {required bool horizontal, required Size viewport}) {
    final pages = state.spreads
        .pages(spread, reverse: horizontal && state.readingMode == 1);
    final landscape = viewport.width > viewport.height;
    final fitHeight = !horizontal &&
        landscape &&
        state.spreadAlignment == ReaderSpreadAlignment.height;
    final compact = horizontal && landscape && pages.length == 2;
    if (fitHeight || compact) {
      double ratio(int page) {
        final decoded =
            _pageAspectRatios[(page, state.imageAttempts[page] ?? 0)];
        final metadata = state.loadedImages[page];
        return decoded ??
            (metadata != null && metadata.width > 0 && metadata.height > 0
                ? metadata.width / metadata.height
                : 0.7);
      }

      final ratios = pages.map(ratio).toList();
      final sizes = fitHeight
          ? heightFittedPages(ratios, viewport)
          : compactHorizontalPages(ratios, viewport);
      return SizedBox(
        height: viewport.height,
        child: Row(
          key: ValueKey('reader-spread-$spread'),
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < pages.length; i++) ...[
              if (i > 0) const SizedBox(width: readerSpreadGap),
              SizedBox.fromSize(
                  size: sizes[i],
                  child: _pageSurface(
                      pages[i],
                      SizedBox(
                          key: ValueKey('reader-page-${pages[i]}'),
                          child: _spreadImage(state, pages[i],
                              horizontal: horizontal,
                              alignedHeight: sizes[i].height)))),
            ]
          ],
        ),
      );
    }
    return Row(
      key: ValueKey('reader-spread-$spread'),
      crossAxisAlignment:
          horizontal ? CrossAxisAlignment.stretch : CrossAxisAlignment.center,
      children: [
        for (final page in pages)
          Expanded(
              child: _pageSurface(
                  page,
                  SizedBox(
                      key: ValueKey('reader-page-$page'),
                      child:
                          _spreadImage(state, page, horizontal: horizontal)))),
      ],
    );
  }

  Widget _spreadImage(ReaderState state, int page,
      {required bool horizontal, double? alignedHeight}) {
    ImageProvider? provider;
    Widget? placeholder;
    if (state.offlineBook != null) {
      provider = _offlineProvider(state, page);
      if (provider == null) placeholder = _offlineMissing(page);
    } else {
      final image = state.loadedImages[page];
      if (!_onlineAllowed(state, page) ||
          _preload.failed(page, state.imageAttempts[page] ?? 0) ||
          image == null ||
          state.loadingIndices.contains(page) ||
          state.failedIndices.contains(page)) {
        placeholder = _pendingImage(state, page);
      } else {
        provider = _imageProvider(image.imageUrl,
            page: page, attempt: state.imageAttempts[page] ?? 0);
      }
    }
    final metadata = state.loadedImages[page];
    final screen = MediaQuery.sizeOf(context);
    final loadingHeight = state.offlineBook != null
        ? screen.height * 0.6
        : metadata != null && metadata.width > 0 && metadata.height > 0
            ? screen.width /
                state.spreads.containing(page).length *
                metadata.height /
                metadata.width
            : screen.height;
    Widget bounded(Widget child) => horizontal || alignedHeight != null
        ? child
        : SizedBox(height: loadingHeight, child: child);
    if (placeholder != null) return bounded(placeholder);
    return ReaderPageImage(
      image: provider!,
      fit: horizontal || alignedHeight != null
          ? BoxFit.contain
          : BoxFit.fitWidth,
      onDecodedSize: (size) {
        if (!mounted || widget.requests.isCancelled || size.height <= 0) return;
        final key = (page, state.imageAttempts[page] ?? 0);
        final ratio = size.width / size.height;
        if (_pageAspectRatios[key] == ratio) return;
        setState(() {
          _pageAspectRatios.removeWhere((entry, _) => entry.$1 == page);
          _pageAspectRatios[key] = ratio;
        });
      },
      loadingHeight: horizontal || alignedHeight != null ? null : loadingHeight,
      errorBuilder: (_, error, ___) => bounded(state.offlineBook != null
          ? _offlineMissing(page, damaged: true)
          : error is ReaderLocalCacheMiss
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white))
              : _decodedImageError(state, page)),
    );
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
    final offlineState = context.read<ReaderBloc>().state;
    final visible = {
      for (final position in positions)
        if (position.itemLeadingEdge < 1 && position.itemTrailingEdge > 0)
          ...offlineState.spreads.pages(position.index)
    };
    if (_explicitPage == null || visible.contains(_explicitPage)) {
      _reportVisible(offlineState, visible);
    }
    if (_explicitPage != null) {
      final target = _explicitPage!.clamp(0, offlineState.totalPages - 1);
      _explicitPage = target;
      _releaseOffscreenResources();
      if (offlineState.currentPage != target)
        context.read<ReaderBloc>().add(PageChanged(target));
      return;
    }
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
    _releaseOffscreenResources();
    final bloc = context.read<ReaderBloc>();
    final page = bloc.state.spreads.pages(current.index).first;
    if (page != bloc.state.currentPage) {
      bloc.add(PageChanged(page));
    }
  }

  @override
  void dispose() {
    _preload.dispose();
    _verticalPositionsListener.itemPositions.removeListener(_onVerticalScroll);
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _pageController.dispose();
    _thumbnailScrollController.dispose();
    _savingPages.dispose();
    _releaseEntryPriority();
    super.dispose();
  }

  // Each thumbnail is 40px wide + 2px margin on each side = 44px per item
  static const double _thumbItemWidth = 44.0;

  void _scrollThumbnailToCurrentPage(int currentPage, int totalPages) {
    if (!_thumbnailScrollController.hasClients || totalPages == 0) return;
    final maxScroll = _thumbnailScrollController.position.maxScrollExtent;
    // Center the current thumbnail in the visible area
    final viewportWidth = _thumbnailScrollController.position.viewportDimension;
    final targetOffset = (currentPage * _thumbItemWidth) -
        (viewportWidth / 2) +
        (_thumbItemWidth / 2) +
        8; // +8 for horizontal padding
    final clampedOffset = targetOffset.clamp(0.0, maxScroll);
    _thumbnailScrollController.jumpTo(clampedOffset);
  }

  @override
  Widget build(BuildContext context) {
    final initial = context.read<ReaderBloc>().state;
    _schedulePreload();
    if (!_positionInitialized && initial.status == ReaderStatus.ready) {
      _pageController.dispose();
      _pageController = PageController(
          initialPage: initial.spreads.spreadOf(initial.currentPage),
          keepPage: false);
      _positionInitialized = true;
      _lastReadingMode = initial.readingMode;
      _lastPageLayout = initial.pageLayout;
      _lastSpreadAlignment = initial.spreadAlignment;
    }
    return BlocConsumer<ReaderBloc, ReaderState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status ||
          prev.preloadCount != curr.preloadCount ||
          prev.visiblePages != curr.visiblePages ||
          prev.imageAttempts != curr.imageAttempts ||
          prev.readingMode != curr.readingMode ||
          prev.pageLayout != curr.pageLayout ||
          prev.spreadAlignment != curr.spreadAlignment ||
          prev.currentPage != curr.currentPage ||
          prev.showUI != curr.showUI,
      listener: (context, state) {
        if (widget.requests.isCancelled) return;
        _syncPreload(state);
        if (state.status == ReaderStatus.deleted) {
          final navigator = Navigator.of(context);
          final readerRoute = ModalRoute.of(context);
          final menu = _pageMenuRoute;
          _pageMenuRoute = null;
          if (menu?.isActive == true) navigator.removeRoute(menu!);
          if (readerRoute?.isCurrent == true)
            navigator.pop();
          else if (readerRoute?.isActive == true)
            navigator.removeRoute(readerRoute!);
          return;
        }
        if (state.status == ReaderStatus.ready &&
            (!_positionInitialized ||
                _lastReadingMode != state.readingMode ||
                _lastPageLayout != state.pageLayout ||
                _lastSpreadAlignment != state.spreadAlignment)) {
          _explicitPage = state.currentPage;
          _zoomController.value = Matrix4.identity();
          _pageController.dispose();
          _pageController = PageController(
              initialPage: state.spreads.spreadOf(state.currentPage),
              keepPage: false);
          // ScrollablePositionedList restores PageStorage ahead of its
          // initialScrollIndex. Keep that storage private to this entry/mode.
          _scrollStorage = PageStorageBucket();
          _positionInitialized = true;
        }
        _lastReadingMode = state.readingMode;
        _lastPageLayout = state.pageLayout;
        _lastSpreadAlignment = state.spreadAlignment;
        ReaderPresentation.maybeOf(context)?.showControls(state.showUI ||
            state.status == ReaderStatus.error ||
            state.status == ReaderStatus.contentWarning);
        if (state.showUI) {
          // When UI is re-shown, wait for layout then scroll to current page
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || widget.requests.isCancelled) return;
            _scrollThumbnailToCurrentPage(state.currentPage, state.totalPages);
          });
        } else {
          _scrollThumbnailToCurrentPage(state.currentPage, state.totalPages);
        }
      },
      builder: (context, state) {
        if (state.offlineBook != null &&
            ReaderPresentation.maybeOf(context)?.ready != true) {
          return const Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                  child: CircularProgressIndicator(color: Colors.white)));
        }
        if (state.status == ReaderStatus.deleted)
          return const SizedBox.shrink();
        if (state.status == ReaderStatus.initial ||
            state.status == ReaderStatus.loading) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: LoadingIndicator(message: S.of(context).loadingReader),
          );
        }
        if (state.status == ReaderStatus.contentWarning) {
          return GalleryWarningView(
              message: state.errorMessage ?? '',
              onContinue: () =>
                  context.read<ReaderBloc>().add(AcceptReaderContentWarning()));
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
              onRetry: () => context.read<ReaderBloc>().add(LoadReaderImages(
                    gid: state.gid,
                    token: state.token,
                    initialPage: state.currentPage,
                  )),
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
                behavior: HitTestBehavior.opaque,
                onTap: state.readingMode == 2 ? _toggleUI : null,
                onLongPress: state.readingMode == 2 ||
                        state.pageLayout == ReaderPageLayout.doublePage
                    ? null
                    : () => _showPageMenu(state.currentPage),
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
  void _preloadChanged() {
    if (_preloadRebuildQueued || !mounted || widget.requests.isCancelled)
      return;
    _preloadRebuildQueued = true;
    scheduleMicrotask(() {
      _preloadRebuildQueued = false;
      if (mounted && !widget.requests.isCancelled) setState(() {});
    });
  }

  void _schedulePreload() {
    if (_preloadSyncQueued) return;
    _preloadSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadSyncQueued = false;
      if (mounted && !widget.requests.isCancelled) {
        _syncPreload(context.read<ReaderBloc>().state);
      }
    });
  }

  void _syncPreload(ReaderState state) {
    if (state.status == ReaderStatus.ready && state.offlineBook == null) {
      if (!context.read<ReaderBloc>().imageScope.isCurrent) {
        widget.requests.cancel();
        return;
      }
      _preload.update(state.preloadWindow, state.imageAttempts);
    }
  }

  void _reportVisible(ReaderState state, Set<int> pages) {
    if (state.offlineBook != null ||
        pages.isEmpty ||
        setEquals(pages, state.visiblePages) ||
        widget.requests.isCancelled) return;
    context
        .read<ReaderBloc>()
        .add(ReaderViewportChanged(pages, state.readingMode, state.pageLayout));
  }

  bool _onlineAllowed(ReaderState state, int page) =>
      state.preloadWindow.visible.contains(page) ||
      (state.preloadWindow.targets.contains(page) &&
          _preload.completed(page, state.imageAttempts[page] ?? 0));

  Future<bool?> _preloadImage(int page, int attempt) async {
    final bloc = context.read<ReaderBloc>();
    final available = await bloc.ensureImageAtIndex(page);
    if (!mounted ||
        !bloc.imageScope.isCurrent ||
        widget.requests.isCancelled ||
        (bloc.state.imageAttempts[page] ?? 0) != attempt) return null;
    if (!available)
      return bloc.state.failedIndices.contains(page) ? false : null;
    // Give the visible widgets their first resolve before background image IO.
    // Waiting for a frame never waits for the visible image's download itself.
    await Future.any([
      WidgetsBinding.instance.endOfFrame,
      widget.requests.cancelToken.whenCancel,
    ]);
    if (!mounted ||
        widget.requests.isCancelled ||
        !bloc.imageScope.isCurrent ||
        (bloc.state.imageAttempts[page] ?? 0) != attempt) return null;
    final image = bloc.state.loadedImages[page];
    if (image == null) return null;
    final done = Completer<bool?>();
    final requests = widget.requests.forPage(page);
    requests.onCancel(() {
      if (!done.isCompleted) done.complete(null);
    });
    final stream = _imageProvider(image.imageUrl, page: page, attempt: attempt)
        .resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      info.dispose();
      if (!done.isCompleted) done.complete(true);
    }, onError: (Object error, StackTrace? __) {
      if (!done.isCompleted) {
        done.complete(error is ReaderLocalCacheMiss ||
                requests.isCancelled ||
                !bloc.imageScope.isCurrent
            ? null
            : false);
      }
    });
    stream.addListener(listener);
    try {
      return await done.future;
    } finally {
      stream.removeListener(listener);
    }
  }

  void _toggleUI() => context.read<ReaderBloc>().add(ToggleReaderUI());

  OfflineImageProvider? _offlineProvider(ReaderState state, int index,
      {bool thumbnail = false}) {
    final matching = state.offlineBook!.pages.where((p) =>
        p.pageIndex == index &&
        p.status == 'completed' &&
        p.relativePath != null &&
        p.sha256 != null);
    if (matching.isEmpty) {
      if (index == _entryPage) _releaseEntryPriority();
      return null;
    }
    final provider = OfflineImageProvider(
        GetIt.I<OfflineRepository>().files, matching.first,
        session: widget.requests,
        prepared:
            !thumbnail && widget.initialRead?.matches(matching.first) == true
                ? widget.initialRead
                : null,
        isCurrent: () => mounted && !widget.requests.isCancelled,
        beforeLoad: (index == _entryPage && !thumbnail)
            ? null
            : () => _entryImageReady.future,
        onLoadError: index == _entryPage ? _releaseEntryPriority : null,
        onPhase: thumbnail ? null : (phase) => widget.diagnostics?.mark(phase),
        onImageReady: thumbnail
            ? null
            : () {
                if (index == _entryPage) {
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _releaseEntryPriority());
                }
                if (mounted &&
                    !widget.requests.isCancelled &&
                    index == context.read<ReaderBloc>().state.currentPage)
                  widget.diagnostics?.visible();
              },
        attempt: state.imageAttempts[index] ?? 0,
        onResource: thumbnail
            ? null
            : (resource) {
                if (!mounted || widget.requests.isCancelled) {
                  resource.releaseMemory();
                  return;
                }
                if (!_isResourceVisible(index)) resource.releaseMemory();
                context.read<ReaderBloc>().add(ReaderImageReady(
                    index, state.imageAttempts[index] ?? 0, resource));
              });
    if (_offlineProviders.add(provider)) {
      widget.requests
          .onCancel(() => PaintingBinding.instance.imageCache.evict(provider));
    }
    return provider;
  }

  Widget _offlineMissing(int index, {bool damaged = false}) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.offline_pin_outlined, color: Colors.white54, size: 40),
        const SizedBox(height: 8),
        Text(
            damaged
                ? S.of(context).offlineError('damaged_file')
                : S.of(context).offlineNotCached,
            style: const TextStyle(color: Colors.white70)),
        TextButton(
            onPressed: () => _showPageMenu(index),
            child: Text(S.of(context).offlinePageActions)),
      ]));

  ReaderImageProvider _imageProvider(String url, {int attempt = 0, int? page}) {
    final scope =
        page == null ? widget.requests : widget.requests.forPage(page);
    final bloc = context.read<ReaderBloc>();
    var files = _imageFiles;
    if (page != null) {
      if (!identical(_pageFiles[page]?.$1, scope)) {
        _pageFiles[page] = (
          scope,
          EhImageCacheManager.readerFileService(
              GetIt.I<app.CookieManager>(), scope,
              imageScope: bloc.imageScope)
        );
      }
      files = _pageFiles[page]!.$2;
    }
    return ReaderImageProvider(url,
        imageScope: bloc.imageScope,
        reentry: ReaderReentryCache.shared,
        ticket: page == null ? null : bloc.cacheTicket(page),
        galleryImage: page == null ? null : bloc.state.loadedImages[page],
        cacheOnly: page != null && bloc.state.cacheOnlyPages.contains(page),
        onCacheMiss: page == null
            ? null
            : () {
                if (mounted && !scope.isCancelled) {
                  bloc.add(ReaderCachedImageMissing(page, attempt));
                }
              },
        requests: scope,
        fileService: files,
        onResourceReady: page == null
            ? null
            : (resource) {
                if (mounted && !scope.isCancelled) {
                  if (!_isResourceVisible(page)) resource.releaseMemory();
                  context
                      .read<ReaderBloc>()
                      .add(ReaderImageReady(page, attempt, resource));
                } else {
                  resource.releaseMemory();
                }
              },
        cache: ReaderImageCache(EhImageCacheManager.instance,
            scope: bloc.imageScope),
        onImageReady: page == null
            ? null
            : () {
                if (!_firstImageLogged &&
                    mounted &&
                    page == context.read<ReaderBloc>().state.currentPage) {
                  _firstImageLogged = true;
                  widget.diagnostics?.visible();
                  if (const bool.fromEnvironment('READER_DIAGNOSTICS')) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && !scope.isCancelled) {
                        debugPrint(
                            '[reader-metric] visible_ms=${widget.startup.elapsedMilliseconds}');
                      }
                    });
                  }
                  assert(() {
                    debugPrint(
                        '[reader] first image visible in ${widget.startup.elapsedMilliseconds}ms');
                    return true;
                  }());
                }
              },
        attempt: attempt);
  }

  bool _isResourceVisible(int page, {int? horizontalPage}) {
    final state = context.read<ReaderBloc>().state;
    if (state.readingMode != 2) {
      return (state.spreads.spreadOf(page) -
                  state.spreads.spreadOf(horizontalPage ?? state.currentPage))
              .abs() <=
          1;
    }
    final positions = _verticalPositionsListener.itemPositions.value;
    if (positions.isEmpty)
      return state.spreads.containing(state.currentPage).contains(page);
    return positions.any((p) =>
        p.index == state.spreads.spreadOf(page) &&
        p.itemLeadingEdge < 1 &&
        p.itemTrailingEdge > 0);
  }

  void _releaseOffscreenResources({int? horizontalPage}) {
    for (final entry
        in context.read<ReaderBloc>().state.readyResources.entries) {
      if (!_isResourceVisible(entry.key, horizontalPage: horizontalPage)) {
        entry.value.releaseMemory();
      }
    }
  }

  Future<void> _showPageMenu(int page) async {
    if (_pageMenuOpen || widget.requests.isCancelled) return;
    _pageMenuOpen = true;
    final bloc = context.read<ReaderBloc>();
    final s = S.of(context);
    final result = await showDialog<Object>(
        context: context,
        builder: (dialogContext) {
          _pageMenuRoute = ModalRoute.of(dialogContext);
          return BlocProvider.value(
              value: bloc,
              child: ReaderPageMenu(page: page, savingPages: _savingPages));
        });
    _pageMenuOpen = false;
    _pageMenuRoute = null;
    if (!mounted || widget.requests.isCancelled) return;
    if (result == 'reload') {
      bloc.add(RetryImageAtIndex(page));
    } else if (result == 'repair' && bloc.state.offlineBook != null) {
      try {
        await GetIt.I<OfflineDownloadCoordinator>()
            .repair(bloc.state.offlineBook!.id, page);
      } catch (error) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(s.offlineError(
                  error is OfflineFailure ? error.code : 'network'))));
      }
    } else if (result is ReaderPageResource &&
        !_savingPages.value.contains(page)) {
      _savingPages.value = {..._savingPages.value, page};
      try {
        final converted = await PageImageExporter()
            .save(result, gid: bloc.state.gid, page: page);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(converted ? s.pageSavedAsPng : s.pageSaved)));
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(error is PlatformException &&
                      error.code == 'permission_denied'
                  ? s.photoPermissionDenied
                  : error is StateError &&
                          error.message == 'page_resource_unavailable'
                      ? s.pageResourceUnavailable
                      : s.pageSaveFailed)));
        }
      } finally {
        if (mounted) _savingPages.value = {..._savingPages.value}..remove(page);
      }
    }
  }

  Widget _pageSurface(int page, Widget child) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showPageMenu(page),
      child: child);

  Widget _decodedImageError(ReaderState state, int page) {
    if (!_preload.failed(page, state.imageAttempts[page] ?? 0)) {
      scheduleMicrotask(
          () => _preload.fail(page, state.imageAttempts[page] ?? 0));
    }
    if (state.readyResources.containsKey(page)) {
      context
          .read<ReaderBloc>()
          .add(ReaderImageFailed(page, state.imageAttempts[page] ?? 0));
    }
    return _imageError(page);
  }

  Widget _imageError(int index) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image, color: Colors.white54, size: 48),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () =>
                  context.read<ReaderBloc>().add(RetryImageAtIndex(index)),
              child: Text(S.of(context).retry,
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

  Widget _pendingImage(ReaderState state, int index) {
    if (state.failedIndices.contains(index) ||
        _preload.failed(index, state.imageAttempts[index] ?? 0))
      return _imageError(index);
    if (_onlineAllowed(state, index) && !state.loadingIndices.contains(index)) {
      context.read<ReaderBloc>().add(LoadImageAtIndex(index));
    }
    return const Center(child: CircularProgressIndicator(color: Colors.white));
  }

  Widget _buildHorizontalReader(ReaderState state) {
    return LayoutBuilder(builder: (context, constraints) {
      final viewport = constraints.biggest;
      return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            final metrics = notification.metrics;
            if (metrics is PageMetrics &&
                metrics.page != null &&
                notification.depth == 0) {
              final position = metrics.page!;
              _reportVisible(state, {
                for (final spread in {position.floor(), position.ceil()})
                  ...state.spreads.pages(spread),
              });
            }
            return false;
          },
          child: PhotoViewGallery.builder(
            key: state.pageLayout == ReaderPageLayout.doublePage
                ? ValueKey((_pageController, viewport))
                : ObjectKey(_pageController),
            pageController: _pageController,
            itemCount: state.spreads.count,
            scrollPhysics: const ReaderScrollPhysics(),
            reverse: state.readingMode == 1, // RTL
            builder: (context, index) {
              if (state.pageLayout == ReaderPageLayout.doublePage) {
                return PhotoViewGalleryPageOptions.customChild(
                  childSize: viewport,
                  child: SizedBox.fromSize(
                      size: viewport,
                      child: _spreadRow(state, index,
                          horizontal: true, viewport: viewport)),
                  onTapUp: (_, __, ___) => _toggleUI(),
                  initialScale: 1.0,
                  minScale: 1.0,
                  maxScale: 3.0,
                );
              }
              if (state.offlineBook != null) {
                final provider = _offlineProvider(state, index);
                if (provider == null)
                  return PhotoViewGalleryPageOptions.customChild(
                      disableGestures: true,
                      child: GestureDetector(
                          onTap: _toggleUI, child: _offlineMissing(index)));
                return PhotoViewGalleryPageOptions(
                    onTapUp: (_, __, ___) => _toggleUI(),
                    imageProvider: provider,
                    initialScale: PhotoViewComputedScale.contained,
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 3,
                    errorBuilder: (_, __, ___) =>
                        _offlineMissing(index, damaged: true));
              }
              final image = state.loadedImages[index];
              if (!_onlineAllowed(state, index) ||
                  _preload.failed(index, state.imageAttempts[index] ?? 0) ||
                  image == null ||
                  state.loadingIndices.contains(index) ||
                  state.failedIndices.contains(index)) {
                return PhotoViewGalleryPageOptions.customChild(
                  onTapUp: (_, __, ___) => _toggleUI(),
                  child: _pendingImage(state, index),
                );
              }
              return PhotoViewGalleryPageOptions(
                onTapUp: (_, __, ___) => _toggleUI(),
                imageProvider: _imageProvider(image.imageUrl,
                    page: index, attempt: state.imageAttempts[index] ?? 0),
                filterQuality: FilterQuality.medium,
                initialScale: PhotoViewComputedScale.contained,
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 3,
                errorBuilder: (_, error, ___) => error is ReaderLocalCacheMiss
                    ? const Center(
                        child: CircularProgressIndicator(color: Colors.white))
                    : _decodedImageError(state, index),
              );
            },
            onPageChanged: (spread) {
              final explicit = _explicitPage;
              final page =
                  explicit != null && state.spreads.spreadOf(explicit) == spread
                      ? explicit
                      : state.spreads.pages(spread).first;
              if (page != explicit) _explicitPage = null;
              _releaseOffscreenResources(horizontalPage: page);
              if (context.read<ReaderBloc>().state.currentPage != page) {
                context.read<ReaderBloc>().add(PageChanged(page));
              }
            },
            loadingBuilder: (_, __) => const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ));
    });
  }

  // ---- Vertical Continuous Scroll Reader ----
  Widget _buildVerticalReader(ReaderState state) {
    return LayoutBuilder(builder: (context, constraints) {
      final viewport = constraints.biggest;
      final fitHeight = viewport.width > viewport.height &&
          state.spreadAlignment == ReaderSpreadAlignment.height;
      return NotificationListener<ScrollStartNotification>(
        onNotification: (notification) {
          if (notification.dragDetails != null) _explicitPage = null;
          return false;
        },
        child: PageStorage(
          bucket: _scrollStorage,
          child: InteractiveViewer(
            transformationController: _zoomController,
            minScale: 1.0,
            maxScale: 3.0,
            panEnabled: _isZoomed,
            scaleEnabled: true,
            child: ScrollablePositionedList.builder(
              key: ObjectKey(_scrollStorage),
              itemCount: state.spreads.count,
              itemScrollController: _verticalScrollController,
              itemPositionsListener: _verticalPositionsListener,
              initialScrollIndex: state.spreads.spreadOf(state.currentPage),
              itemBuilder: (context, index) {
                if (state.pageLayout == ReaderPageLayout.doublePage ||
                    fitHeight) {
                  return _spreadRow(state, index,
                      horizontal: false, viewport: viewport);
                }
                if (state.offlineBook != null) {
                  final provider = _offlineProvider(state, index);
                  return _pageSurface(
                      index,
                      provider == null
                          ? SizedBox(height: 300, child: _offlineMissing(index))
                          : ReaderPageImage(
                              image: provider,
                              loadingHeight: MediaQuery.sizeOf(context).height,
                              errorBuilder: (_, __, ___) => SizedBox(
                                  height: 300,
                                  child:
                                      _offlineMissing(index, damaged: true))));
                }
                final image = state.loadedImages[index];
                if (!_onlineAllowed(state, index) ||
                    _preload.failed(index, state.imageAttempts[index] ?? 0) ||
                    image == null ||
                    state.loadingIndices.contains(index) ||
                    state.failedIndices.contains(index)) {
                  return _pageSurface(
                      index,
                      SizedBox(
                        height: image != null &&
                                image.width > 0 &&
                                image.height > 0
                            ? (MediaQuery.sizeOf(context).width *
                                    image.height /
                                    image.width)
                                .clamp(
                                    200.0, MediaQuery.sizeOf(context).width * 3)
                            : MediaQuery.sizeOf(context).height,
                        child: _pendingImage(state, index),
                      ));
                }

                // Calculate aspect ratio for proper height
                double aspectRatio = image.width > 0 && image.height > 0
                    ? image.width / image.height
                    : 0.7; // default portrait ratio
                final screenWidth = MediaQuery.of(context).size.width;
                final imageHeight = screenWidth / aspectRatio;

                return _pageSurface(
                    index,
                    SizedBox(
                      width: screenWidth,
                      height: imageHeight.clamp(200.0, screenWidth * 3),
                      child: ReaderPageImage(
                        image: _imageProvider(image.imageUrl,
                            page: index,
                            attempt: state.imageAttempts[index] ?? 0),
                        errorBuilder: (_, error, ___) =>
                            error is ReaderLocalCacheMiss
                                ? const Center(
                                    child: CircularProgressIndicator(
                                        color: Colors.white))
                                : _decodedImageError(state, index),
                      ),
                    ));
              },
            ),
          ),
        ),
      );
    });
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
          left: MediaQuery.of(context).padding.left,
          right: MediaQuery.of(context).padding.right,
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                '${state.offlineBook == null ? '' : '${state.offlineBook!.source?.shortName ?? ''} · '}${state.spreads.label(state.currentPage)} / ${state.totalPages}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const ReaderPreloadSetting(toolbar: true),
            const ReaderSettingsButton(),
          ],
        ),
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
          left: MediaQuery.of(context).padding.left,
          right: MediaQuery.of(context).padding.right,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Thumbnail strip
            if (state.totalPages > 0)
              SizedBox(
                height: 56,
                child: ListView.builder(
                  controller: _thumbnailScrollController,
                  scrollDirection: Axis.horizontal,
                  itemExtent: _thumbItemWidth,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: state.totalPages,
                  itemBuilder: (_, index) {
                    final thumb = state.thumbnails[index];
                    final isCurrent = state.spreads
                        .containing(state.currentPage)
                        .contains(index);
                    return GestureDetector(
                      onTap: () => _jumpToPage(index),
                      child: Container(
                        width: 40,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isCurrent ? Colors.blue : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: thumb == null
                              ? _pendingThumbnail(state, index)
                              : _buildStripThumbnail(thumb, index),
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
                    '${(_sliderPage ?? state.currentPage) + 1}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  Expanded(
                    child: Slider(
                      value: (_sliderPage ?? state.currentPage)
                          .toDouble()
                          .clamp(0, (state.totalPages - 1).toDouble()),
                      min: 0,
                      max: (state.totalPages - 1).toDouble(),
                      divisions:
                          state.totalPages > 1 ? state.totalPages - 1 : 1,
                      onChanged: (value) {
                        setState(() => _sliderPage = value.round());
                      },
                      onChangeEnd: (value) {
                        final page = value.round();
                        setState(() => _sliderPage = null);
                        _jumpToPage(page);
                      },
                    ),
                  ),
                  Text(
                    '${state.totalPages}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '${state.spreads.label(state.currentPage)} / ${state.totalPages}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildStripThumbnail(ThumbnailInfo thumb, int index) {
    final state = context.read<ReaderBloc>().state;
    if (state.offlineBook != null) {
      final provider = _offlineProvider(state, index, thumbnail: true);
      return provider == null
          ? Center(
              child: Text('${index + 1}',
                  style: const TextStyle(color: Colors.white54)))
          : Image(
              image: provider,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image, color: Colors.white54));
    }
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

    if (thumb.isSprite) {
      return SpriteThumbnail(
        thumbnail: thumb,
        image: _imageProvider(thumb.thumbUrl,
            attempt: _thumbnailAttempts[thumb.thumbUrl] ?? 0),
        placeholder: (_) => ColoredBox(color: Colors.grey[800]!),
        errorBuilder: (_, __, ___) => _thumbnailError(thumb.thumbUrl),
      );
    }
    return Image(
      image: _imageProvider(thumb.thumbUrl,
          attempt: _thumbnailAttempts[thumb.thumbUrl] ?? 0),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _thumbnailError(thumb.thumbUrl),
    );
  }

  Widget _pendingThumbnail(ReaderState state, int index) {
    if (state.failedThumbnails.contains(index)) {
      return IconButton(
          padding: EdgeInsets.zero,
          tooltip: S.of(context).retry,
          icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
          onPressed: () => context
              .read<ReaderBloc>()
              .add(LoadThumbnailAtIndex(index, retry: true)));
    }
    if (!state.loadingThumbnails.contains(index)) {
      context.read<ReaderBloc>().add(LoadThumbnailAtIndex(index));
    }
    return ColoredBox(
        color: Colors.black26,
        child: Center(
            child: Text('${index + 1}',
                style: const TextStyle(color: Colors.white54, fontSize: 10))));
  }

  Widget _thumbnailError(String url) => IconButton(
        padding: EdgeInsets.zero,
        tooltip: S.of(context).retry,
        icon: const Icon(Icons.refresh, color: Colors.white70, size: 20),
        onPressed: () => setState(() {
          _thumbnailAttempts[url] = (_thumbnailAttempts[url] ?? 0) + 1;
        }),
      );
}
