import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/history_repository.dart';
import '../../repositories/settings_repository.dart';
import '../../core/constants/app_constants.dart';
import '../../core/network/reader_request_controller.dart';
import '../../core/parser/gallery_detail_parser.dart';
import '../../models/gallery_image.dart';
import 'reader_event.dart';
import 'reader_state.dart';

class ReaderBloc extends Bloc<ReaderEvent, ReaderState> {
  final GalleryRepository _galleryRepo;
  final HistoryRepository _historyRepo;
  final SettingsRepository _settingsRepo;
  final ReaderRequestController _requests;
  final Set<int> _loadingIndices = {};

  ReaderBloc(
    this._galleryRepo,
    this._historyRepo,
    this._settingsRepo, {
    ReaderRequestController? requestController,
  })  : _requests = requestController ?? ReaderRequestController(),
        super(ReaderState(readingMode: _settingsRepo.getReadingMode())) {
    on<LoadReaderImages>(_onLoadImages);
    on<LoadImageAtIndex>(_onLoadImageAtIndex);
    on<RetryImageAtIndex>(_onRetryImageAtIndex);
    on<PageChanged>(_onPageChanged);
    on<ToggleReaderUI>(_onToggleUI);
    on<ChangeReadingMode>(_onChangeReadingMode);
  }

  Future<void> _onLoadImages(
    LoadReaderImages event,
    Emitter<ReaderState> emit,
  ) async {
    if (_requests.isCancelled) return;
    // Resolve starting page: use explicit initialPage, or fall back to saved progress
    var startPage = event.initialPage;
    if (startPage == 0) {
      final progress = await _historyRepo.getProgress(event.gid);
      if (progress != null && progress.lastReadPage > 0) {
        startPage = progress.lastReadPage;
      }
    }
    if (_requests.isCancelled || isClosed) return;

    emit(state.copyWith(
      status: ReaderStatus.loading,
      gid: event.gid,
      token: event.token,
      currentPage: startPage,
    ));

    try {
      // Load ALL thumbnail pages to get all page tokens
      final allThumbnails = <ThumbnailInfo>[];

      // Fetch first page to get thumbnails and page count
      final detail =
          await _galleryRepo.fetchGalleryDetail(event.gid, event.token,
              cancelToken: _requests.cancelToken);
      final firstPageResult = await _galleryRepo.fetchThumbnails(
        event.gid,
        event.token,
        cancelToken: _requests.cancelToken,
      );
      if (_requests.isCancelled) return;
      allThumbnails.addAll(firstPageResult.thumbnails);

      // Calculate how many thumbnail pages we need
      final totalPages = detail.fileCount;
      final numThumbPages = firstPageResult.totalPages;
      if (numThumbPages > 1 && allThumbnails.length < totalPages) {
        // Fetch remaining thumbnail pages in parallel
        final futures = <Future<ThumbnailResult>>[];
        for (var p = 1; p < numThumbPages; p++) {
          futures.add(_galleryRepo.fetchThumbnails(
              event.gid, event.token,
              page: p,
              cancelToken: _requests.cancelToken));
        }
        final results = await Future.wait(futures);
        if (_requests.isCancelled) return;
        for (final result in results) {
          allThumbnails.addAll(result.thumbnails);
        }
      }

      // Sort by page index
      allThumbnails.sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
      if (_requests.isCancelled) return;

      // Clamp startPage to valid range
      final clampedStart = startPage.clamp(0, allThumbnails.length - 1);

      emit(state.copyWith(
        status: ReaderStatus.ready,
        thumbnails: allThumbnails,
        totalPages: allThumbnails.length,
        currentPage: clampedStart,
      ));

      // Immediately persist the starting page so progress is saved
      // even if the user exits without flipping pages
      _historyRepo.updateProgress(
          event.gid, clampedStart, allThumbnails.length);

      // Start preloading from current page
      if (!_requests.isCancelled && !isClosed) {
        add(LoadImageAtIndex(clampedStart));
      }
    } catch (e) {
      if (_requests.isCancelled) return;
      emit(state.copyWith(
        status: ReaderStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> _onLoadImageAtIndex(
    LoadImageAtIndex event,
    Emitter<ReaderState> emit,
  ) async {
    if (_requests.isCancelled) return;
    // Skip if already loaded or already loading
    if (state.loadedImages.containsKey(event.index)) return;
    if (event.index < 0 || event.index >= state.thumbnails.length) return;
    if (_loadingIndices.contains(event.index)) return;

    _loadingIndices.add(event.index);

    try {
      final thumb = state.thumbnails[event.index];
      final image = await _galleryRepo.fetchImage(
        thumb.pageToken,
        state.gid,
        event.index,
        cancelToken: _requests.cancelToken,
      );
      if (_requests.isCancelled) return;

      // Add thumb URL from thumbnail info
      final imageWithThumb = GalleryImage(
        index: image.index,
        pageUrl: image.pageUrl,
        imageUrl: image.imageUrl,
        thumbUrl: thumb.thumbUrl,
        width: image.width,
        height: image.height,
        nlKey: image.nlKey,
      );

      final updated =
          Map<int, GalleryImage>.from(state.loadedImages);
      updated[event.index] = imageWithThumb;
      emit(state.copyWith(
          loadedImages: Map<int, GalleryImage>.unmodifiable(updated)));

      // Preload adjacent pages
      _preloadAdjacent(event.index);
    } catch (_) {
      // Silently fail for preloaded images; user can retry
    } finally {
      _loadingIndices.remove(event.index);
    }
  }

  /// Retry loading an image using the nl key for server failover.
  /// If the image was previously loaded with an nlKey, re-fetch from
  /// an alternate server. Otherwise falls back to a normal reload.
  Future<void> _onRetryImageAtIndex(
    RetryImageAtIndex event,
    Emitter<ReaderState> emit,
  ) async {
    if (_requests.isCancelled) return;
    if (event.index < 0 || event.index >= state.thumbnails.length) return;
    if (_loadingIndices.contains(event.index)) return;

    _loadingIndices.add(event.index);

    try {
      final thumb = state.thumbnails[event.index];
      final previousImage = state.loadedImages[event.index];
      final nlKey = previousImage?.nlKey;

      GalleryImage image;
      if (nlKey != null && nlKey.isNotEmpty) {
        // Use nl key to request alternate server
        image = await _galleryRepo.fetchImageWithNl(
          thumb.pageToken,
          state.gid,
          event.index,
          nlKey,
          cancelToken: _requests.cancelToken,
        );
      } else {
        // Normal retry
        image = await _galleryRepo.fetchImage(
          thumb.pageToken,
          state.gid,
          event.index,
          cancelToken: _requests.cancelToken,
        );
      }
      if (_requests.isCancelled) return;

      final imageWithThumb = GalleryImage(
        index: image.index,
        pageUrl: image.pageUrl,
        imageUrl: image.imageUrl,
        thumbUrl: thumb.thumbUrl,
        width: image.width,
        height: image.height,
        nlKey: image.nlKey,
      );

      final updated =
          Map<int, GalleryImage>.from(state.loadedImages);
      updated[event.index] = imageWithThumb;
      emit(state.copyWith(
          loadedImages: Map<int, GalleryImage>.unmodifiable(updated)));
    } catch (_) {
      // Retry failed — user can try again
    } finally {
      _loadingIndices.remove(event.index);
    }
  }

  void _preloadAdjacent(int index) {
    if (_requests.isCancelled || isClosed) return;
    for (var i = 1; i <= AppConstants.preloadPageCount; i++) {
      if (index + i < state.totalPages &&
          !state.loadedImages.containsKey(index + i)) {
        add(LoadImageAtIndex(index + i));
      }
      if (index - i >= 0 &&
          !state.loadedImages.containsKey(index - i)) {
        add(LoadImageAtIndex(index - i));
      }
    }
  }

  Future<void> _onPageChanged(
    PageChanged event,
    Emitter<ReaderState> emit,
  ) async {
    if (_requests.isCancelled) return;
    emit(state.copyWith(currentPage: event.page));

    // Save reading progress
    await _historyRepo.updateProgress(
      state.gid,
      event.page,
      state.totalPages,
    );
    if (_requests.isCancelled || isClosed) return;

    // Load current page image if not loaded
    add(LoadImageAtIndex(event.page));
  }

  void _onToggleUI(ToggleReaderUI event, Emitter<ReaderState> emit) {
    emit(state.copyWith(showUI: !state.showUI));
  }

  Future<void> _onChangeReadingMode(
    ChangeReadingMode event,
    Emitter<ReaderState> emit,
  ) async {
    await _settingsRepo.setReadingMode(event.mode);
    emit(state.copyWith(readingMode: event.mode));
  }

  @override
  Future<void> close() {
    _requests.cancel();
    return super.close();
  }
}
