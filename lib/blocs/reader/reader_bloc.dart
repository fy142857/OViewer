import 'dart:async';
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

class ReaderBloc extends Bloc<ReaderEvent, ReaderState> {
  final GalleryRepository _galleryRepo;
  final HistoryRepository _historyRepo;
  final SettingsRepository _settingsRepo;
  final ReaderRequestController _requests;
  ReaderIndexSession? _index;
  bool _starting = false;

  ReaderBloc(this._galleryRepo, this._historyRepo, this._settingsRepo,
      {ReaderRequestController? requestController})
      : _requests = requestController ?? ReaderRequestController(),
        super(ReaderState(readingMode: _settingsRepo.getReadingMode())) {
    on<LoadReaderImages>(_onLoadImages);
    on<LoadImageAtIndex>(_onLoadImageAtIndex);
    on<LoadThumbnailAtIndex>(_onLoadThumbnail);
    on<RetryImageAtIndex>(_onRetryImageAtIndex);
    on<PageChanged>(_onPageChanged);
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
      _saveProgress(current);
      add(LoadImageAtIndex(current));
      // Neighbours are queued only after the current page URL is available.
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
    emit(state.copyWith(
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
        state.loadingIndices.contains(page)) return;
    final previous = state.loadedImages[page];
    emit(state.copyWith(
        loadingIndices: {...state.loadingIndices, page},
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
        if (!_active || !index.isActive) return;
        _publishIndex(emit);
        try {
          final nl = previous?.nlKey;
          final image = retry && refresh == 0 && nl != null && nl.isNotEmpty
              ? await _galleryRepo.fetchImageWithNl(
                  thumb.pageToken, state.gid, page, nl,
                  cancelToken: _requests.cancelToken)
              : await _galleryRepo.fetchImage(thumb.pageToken, state.gid, page,
                  cancelToken: _requests.cancelToken);
          if (!_active || !index.isActive) return;
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
      if (_active && identical(index, _index) && index.isActive) {
        emit(state.copyWith(failedIndices: {...state.failedIndices, page}));
      }
    } finally {
      if (_active && identical(index, _index) && index.isActive) {
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
