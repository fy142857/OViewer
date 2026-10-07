import 'dart:async';
import '../../core/storage/reader_reentry_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/history_repository.dart';
import '../../repositories/settings_repository.dart';
import '../../core/constants/app_constants.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/reader_index_session.dart';
import '../../core/network/reader_request_controller.dart';
import '../../models/gallery_image.dart';
import 'reader_event.dart';
import 'reader_state.dart';
import '../../core/parser/gallery_content_warning.dart';

class ReaderBloc extends Bloc<ReaderEvent, ReaderState> {
  final GalleryRepository _galleryRepo;
  final HistoryRepository _historyRepo;
  final SettingsRepository _settingsRepo;
  final ReaderRequestController _requests;
  ReaderIndexSession? _index;
  final ReaderReentryCache _reentry;
  final String _site = AppConstants.baseUrl;
  int? _cacheGeneration;
  bool _restored = false;
  bool _starting = false;
  ReaderGalleryKey get galleryKey => (_site, state.gid, state.token);

  static ReaderState _initial(SettingsRepository settings,
      ReaderReentryCache cache, LoadReaderImages? request) {
    final snapshot = request == null
        ? null
        : cache.get((AppConstants.baseUrl, request.gid, request.token));
    if (snapshot == null) {
      return ReaderState(readingMode: settings.getReadingMode());
    }
    final page = (request!.initialPage ?? snapshot.currentPage)
        .clamp(0, snapshot.metadata.totalPages - 1);
    return ReaderState(
        status: ReaderStatus.ready,
        gid: request.gid,
        token: request.token,
        readingMode: settings.getReadingMode(),
        currentPage: page,
        totalPages: snapshot.metadata.totalPages,
        loadedImages: snapshot.pages.map((i, p) => MapEntry(i, p.image)),
        thumbnails: Map.of(snapshot.thumbnails),
        cacheOnlyPages: snapshot.pages.keys.toSet());
  }

  ReaderCacheTicket? cacheTicket(int page) {
    if (_cacheGeneration != _reentry.generation) return null;
    return _reentry.ticket(galleryKey, page);
  }

  void _prepareCache() {
    final metadata = _index?.metadata;
    if (metadata == null || _cacheGeneration != _reentry.generation) return;
    _reentry.prepare(
        galleryKey, metadata, _index!.thumbnails, state.currentPage);
  }

  int _requestedStart = 0;

  ReaderBloc(this._galleryRepo, this._historyRepo, this._settingsRepo,
      {ReaderRequestController? requestController,
      ReaderReentryCache? reentryCache,
      LoadReaderImages? initialRequest})
      : _requests = requestController ?? ReaderRequestController(),
        _reentry = reentryCache ?? ReaderReentryCache.shared,
        super(_initial(_settingsRepo, reentryCache ?? ReaderReentryCache.shared,
            initialRequest)) {
    _cacheGeneration = _reentry.generation;
    if (state.status == ReaderStatus.ready) {
      final snapshot = _reentry.get(galleryKey)!;
      _index =
          ReaderIndexSession(_galleryRepo, _requests, state.gid, state.token)
            ..seed(snapshot.metadata, snapshot.thumbnails);
      _restored = true;
      _requestedStart = state.currentPage;
    }
    on<ReaderCachedImageMissing>((event, emit) async {
      if (!_active ||
          !state.cacheOnlyPages.contains(event.index) ||
          (state.imageAttempts[event.index] ?? 0) != event.attempt) return;
      _reentry.invalidatePage(galleryKey, event.index);
      emit(state.copyWith(
          cacheOnlyPages: {...state.cacheOnlyPages}..remove(event.index),
          loadedImages: {...state.loadedImages}..remove(event.index),
          imageAttempts: {
            ...state.imageAttempts,
            event.index: event.attempt + 1
          }));
      await _loadImage(event.index, emit);
    });
    on<LoadReaderImages>(_onLoadImages);
    on<LoadImageAtIndex>(_onLoadImageAtIndex);
    on<LoadThumbnailAtIndex>(_onLoadThumbnail);
    on<RetryImageAtIndex>(_onRetryImageAtIndex);
    on<PageChanged>(_onPageChanged);
    on<AcceptReaderContentWarning>((event, emit) async {
      if (!_active || state.status != ReaderStatus.contentWarning) return;
      try {
        await _galleryRepo.acceptGalleryWarning(state.gid, state.token);
      } catch (error) {
        if (_active) {
          emit(state.copyWith(
              status: ReaderStatus.error, errorMessage: error.toString()));
        }
        return;
      }
      if (!_active) return;
      add(LoadReaderImages(
          gid: state.gid, token: state.token, initialPage: _requestedStart));
    });
    on<ReaderImageReady>((event, emit) {
      if (_active &&
          (state.imageAttempts[event.index] ?? 0) == event.attempt &&
          state.loadedImages.containsKey(event.index) &&
          !state.loadingIndices.contains(event.index)) {
        emit(state.copyWith(readyResources: {
          ...state.readyResources,
          event.index: event.resource
        }));
      } else {
        event.resource.releaseMemory();
      }
    });
    on<ReaderImageFailed>((event, emit) {
      if (_active && (state.imageAttempts[event.index] ?? 0) == event.attempt) {
        state.readyResources[event.index]?.releaseMemory();
        emit(state.copyWith(
            readyResources: {...state.readyResources}..remove(event.index)));
      }
    });
    on<ToggleReaderUI>((event, emit) {
      if (!_requests.isCancelled) emit(state.copyWith(showUI: !state.showUI));
    });
    on<ChangeReadingMode>((event, emit) async {
      await _settingsRepo.setReadingMode(event.mode);
      if (!_requests.isCancelled) emit(state.copyWith(readingMode: event.mode));
    });
  }

  bool get _active => !_requests.isCancelled && !isClosed;

  Future<void> _onLoadImages(
      LoadReaderImages event, Emitter<ReaderState> emit) async {
    if (!_active || _starting) return;
    if (_restored && event.gid == state.gid && event.token == state.token) {
      _restored = false;
      _reentry.focus(galleryKey, state.currentPage);
      _saveProgress(state.currentPage);
      if (!state.loadedImages.containsKey(state.currentPage)) {
        add(LoadImageAtIndex(state.currentPage));
      }
      return;
    }
    _starting = true;
    final watch = Stopwatch()..start();
    emit(ReaderState(
        status: ReaderStatus.loading,
        gid: event.gid,
        token: event.token,
        readingMode: state.readingMode));
    try {
      // Null means resume. An explicit zero really means the first page.
      final start = event.initialPage ??
          (await _historyRepo.getProgress(event.gid))?.lastReadPage ??
          0;
      if (!_active) return;
      _requestedStart = start;
      final index =
          ReaderIndexSession(_galleryRepo, _requests, event.gid, event.token);
      _index = index;
      await index.bootstrap();
      if (!_active || !index.isActive) return;
      final current = start.clamp(0, index.totalPages - 1);
      index.prioritize(current);
      emit(state.copyWith(
          status: ReaderStatus.ready,
          currentPage: current,
          totalPages: index.totalPages,
          thumbnails: Map.of(index.thumbnails)));
      if (kDebugMode) {
        debugPrint(
            '[reader] interface ready in ${watch.elapsedMilliseconds}ms');
      }
      _prepareCache();
      _saveProgress(current);
      add(LoadImageAtIndex(current));
      // Neighbours are queued only after the current page URL is available.
    } on GalleryContentWarning catch (warning) {
      if (_active) {
        emit(state.copyWith(
            status: ReaderStatus.contentWarning,
            errorMessage: warning.message));
      }
    } catch (error) {
      if (_active) {
        emit(state.copyWith(
            status: ReaderStatus.error, errorMessage: error.toString()));
      }
    } finally {
      _starting = false;
    }
  }

  Future<void> _onLoadImageAtIndex(
      LoadImageAtIndex event, Emitter<ReaderState> emit) async {
    if (state.loadedImages.containsKey(event.index) ||
        state.failedIndices.contains(event.index)) return;
    await _loadImage(event.index, emit);
  }

  Future<void> _onRetryImageAtIndex(
          RetryImageAtIndex event, Emitter<ReaderState> emit) =>
      _loadImage(event.index, emit, retry: true);

  void _publishIndex(Emitter<ReaderState> emit) {
    final index = _index!;
    _prepareCache();
    final snapshot = _reentry.get(galleryKey);
    final stale = state.cacheOnlyPages
        .where((p) => snapshot?.pages.containsKey(p) != true)
        .toSet();
    emit(state.copyWith(
        loadedImages: {...state.loadedImages}
          ..removeWhere((p, _) => stale.contains(p)),
        cacheOnlyPages: {...state.cacheOnlyPages}..removeAll(stale),
        thumbnails: Map.of(index.thumbnails),
        totalPages: index.totalPages,
        currentPage: state.currentPage.clamp(0, index.totalPages - 1)));
  }

  Future<void> _loadImage(int page, Emitter<ReaderState> emit,
      {bool retry = false}) async {
    final index = _index;
    if (!_active ||
        index == null ||
        !index.isActive ||
        page < 0 ||
        page >= state.totalPages ||
        (!retry && state.loadingIndices.contains(page))) return;
    final previous = state.loadedImages[page];
    if (retry) _reentry.invalidatePage(galleryKey, page);
    final pageRequests =
        retry ? _requests.restartPage(page) : _requests.forPage(page);
    bool current() =>
        _active &&
        identical(index, _index) &&
        index.isActive &&
        !pageRequests.isCancelled;
    state.readyResources[page]?.releaseMemory();
    emit(state.copyWith(
        loadingIndices: {...state.loadingIndices, page},
        cacheOnlyPages: {...state.cacheOnlyPages}..remove(page),
        readyResources: {...state.readyResources}..remove(page),
        failedIndices: {...state.failedIndices}..remove(page),
        imageAttempts: retry
            ? {
                ...state.imageAttempts,
                page: (state.imageAttempts[page] ?? 0) + 1
              }
            : state.imageAttempts));
    try {
      for (var refresh = 0; refresh < 2; refresh++) {
        final thumb = await index.ensureImage(page, refresh: refresh > 0);
        if (!current()) return;
        _publishIndex(emit);
        try {
          final nl = previous?.nlKey;
          final image = retry && refresh == 0 && nl != null && nl.isNotEmpty
              ? await _galleryRepo.fetchImageWithNl(
                  thumb.pageToken, state.gid, page, nl,
                  cancelToken: pageRequests.cancelToken)
              : await _galleryRepo.fetchImage(thumb.pageToken, state.gid, page,
                  cancelToken: pageRequests.cancelToken);
          if (!current()) return;
          if (image.imageUrl.isEmpty) {
            throw const FormatException(
                'Image page no longer contains an image.');
          }
          emit(state.copyWith(loadedImages: {
            ...state.loadedImages,
            page: GalleryImage(
                index: image.index,
                pageUrl: image.pageUrl,
                imageUrl: image.imageUrl,
                thumbUrl: thumb.thumbUrl,
                width: image.width,
                height: image.height,
                nlKey: image.nlKey)
          }));
          if (page == state.currentPage) _preloadAdjacent(page);
          return;
        } catch (error) {
          // Refresh stale page tokens once. Network/login errors remain local
          // errors, avoiding a second wave of requests on a broken connection.
          if (refresh != 0 ||
              !(error is FormatException ||
                  error is ApiException && error.statusCode == 404)) rethrow;
        }
      }
    } on ReaderIndexDiscarded {
      // Obsolete queued work is not a failed page.
    } catch (_) {
      if (current()) {
        emit(state.copyWith(failedIndices: {...state.failedIndices, page}));
      }
    } finally {
      if (current()) {
        emit(state.copyWith(
            loadingIndices: {...state.loadingIndices}..remove(page)));
      }
    }
  }

  Future<void> _onLoadThumbnail(
      LoadThumbnailAtIndex event, Emitter<ReaderState> emit) async {
    final index = _index;
    final page = event.index;
    if (!_active ||
        index == null ||
        !index.isActive ||
        page < 0 ||
        page >= state.totalPages ||
        state.thumbnails.containsKey(page) ||
        state.loadingThumbnails.contains(page) ||
        (!event.retry && state.failedThumbnails.contains(page))) return;
    emit(state.copyWith(
        loadingThumbnails: {...state.loadingThumbnails, page},
        failedThumbnails: {...state.failedThumbnails}..remove(page)));
    try {
      await index.ensureImage(page, refresh: event.retry);
      if (_active && index.isActive) _publishIndex(emit);
    } on ReaderIndexDiscarded {
      // Superseded by a jump to another page.
    } catch (_) {
      if (_active && identical(index, _index) && index.isActive) {
        emit(state
            .copyWith(failedThumbnails: {...state.failedThumbnails, page}));
      }
    } finally {
      if (_active && identical(index, _index) && index.isActive) {
        emit(state.copyWith(
            loadingThumbnails: {...state.loadingThumbnails}..remove(page)));
      }
    }
  }

  void _preloadAdjacent(int page) {
    if (!_active) return;
    for (var distance = 1;
        distance <= AppConstants.preloadPageCount;
        distance++) {
      for (final neighbour in [page + distance, page - distance]) {
        if (neighbour >= 0 &&
            neighbour < state.totalPages &&
            !state.loadedImages.containsKey(neighbour) &&
            !state.loadingIndices.contains(neighbour) &&
            !state.failedIndices.contains(neighbour)) {
          add(LoadImageAtIndex(neighbour));
        }
      }
    }
  }

  void _onPageChanged(PageChanged event, Emitter<ReaderState> emit) {
    if (!_active || state.status != ReaderStatus.ready) return;
    final page = event.page.clamp(0, state.totalPages - 1);
    _index?.prioritize(page);
    emit(state.copyWith(currentPage: page));
    _reentry.focus(galleryKey, page);
    _saveProgress(page);
    if (state.loadedImages.containsKey(page)) {
      _preloadAdjacent(page);
    } else {
      add(LoadImageAtIndex(page));
    }
  }

  void _saveProgress(int page) {
    unawaited(_historyRepo
        .updateProgress(state.gid, page, state.totalPages)
        .catchError((Object _) {}));
  }

  @override
  Future<void> close() {
    _requests.cancel();
    return super.close();
  }
}
