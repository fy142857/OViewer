import 'dart:async';
import '../constants/app_constants.dart';
import '../parser/gallery_detail_parser.dart';
import '../../models/reader_index_page.dart';
import '../../repositories/gallery_repository.dart';
import 'reader_request_controller.dart';

class ReaderIndexDiscarded implements Exception {}

/// At most two index requests, with one slot reserved for the current page.
/// Only this reader owns queued/in-flight work; the repository shares results.
class ReaderIndexSession {
  final GalleryRepository repository;
  final ReaderRequestController requests;
  final int gid;
  final String token;
  final String _site;
  final int _generation;
  final _jobs = <int, _IndexJob>{};
  final _queue = <_IndexJob>[];
  final thumbnails = <int, ThumbnailInfo>{};
  ReaderIndexPage? _metadata;
  int _active = 0;
  int _focus = 0;

  ReaderIndexSession(this.repository, this.requests, this.gid, this.token)
      : _site = AppConstants.baseUrl,
        _generation = repository.readerIndexCache.generation {
    requests.onCancel(_discardQueued);
  }

  int get totalPages => _metadata?.totalPages ?? 0;
  bool get isActive =>
      !requests.isCancelled &&
      _site == AppConstants.baseUrl &&
      _generation == repository.readerIndexCache.generation;

  Future<void> bootstrap() async {
    await _page(0);
  }

  void prioritize(int index) {
    _focus = index;
    final size = _metadata?.pageSize;
    if (size != null) {
      final min =
          (index - AppConstants.preloadPageCount).clamp(0, totalPages - 1) ~/
              size;
      final max =
          (index + AppConstants.preloadPageCount).clamp(0, totalPages - 1) ~/
              size;
      for (final job in List<_IndexJob>.of(_queue)) {
        if (job.page < min || job.page > max) {
          _queue.remove(job);
          _jobs.remove(job.page);
          job.done.completeError(ReaderIndexDiscarded());
        }
      }
    }
    _pump();
  }

  Future<ThumbnailInfo> ensureImage(int index, {bool refresh = false}) async {
    if (!isActive) throw ReaderIndexDiscarded();
    if (_metadata == null) await bootstrap();
    if (index < 0 || index >= totalPages) {
      throw RangeError.index(index, thumbnails);
    }
    if (!refresh && thumbnails[index] != null) return thumbnails[index]!;
    var part = index ~/ _metadata!.pageSize;
    try {
      await _page(part, refresh: refresh);
      if (thumbnails[index] != null) return thumbnails[index]!;
    } on FormatException {
      // Server preferences or a stale pagination layout may have changed.
    }
    // Exactly one correction, never a scan of all preceding index pages.
    thumbnails.clear();
    await _page(0, refresh: true);
    if (index >= totalPages) throw RangeError.index(index, thumbnails);
    part = index ~/ _metadata!.pageSize;
    if (part != 0) await _page(part, refresh: true);
    final result = thumbnails[index];
    if (result == null) {
      throw const FormatException(
          'Requested page is absent from the gallery index.');
    }
    return result;
  }

  Future<ReaderIndexPage> _page(int page, {bool refresh = false}) {
    if (!isActive) return Future.error(ReaderIndexDiscarded());
    final existing = _jobs[page];
    if (existing != null) return existing.done.future;
    if (refresh) {
      repository.invalidateReaderIndex(gid, token, page);
      final size = _metadata?.pageSize;
      if (size != null) thumbnails.removeWhere((i, _) => i ~/ size == page);
    } else {
      final cached = repository.cachedReaderIndex(gid, token, page: page);
      if (cached != null) {
        _accept(cached);
        return Future.value(cached);
      }
    }
    final job = _IndexJob(page);
    _jobs[page] = job;
    _queue.add(job);
    _pump();
    return job.done.future;
  }

  void _pump() {
    if (!isActive) {
      _discardQueued();
      return;
    }
    while (_queue.isNotEmpty && _active < 2) {
      final focusPart = _focus ~/ (_metadata?.pageSize ?? 1);
      final urgent = _queue.indexWhere((job) => job.page == focusPart);
      if (urgent < 0 && _active >= 1) return;
      final job = _queue.removeAt(urgent < 0 ? 0 : urgent);
      _active++;
      _run(job);
    }
  }

  Future<void> _run(_IndexJob job) async {
    try {
      final page = await repository.fetchReaderIndexPage(gid, token,
          page: job.page, cancelToken: requests.cancelToken);
      if (!isActive) throw ReaderIndexDiscarded();
      _accept(page);
      job.done.complete(page);
    } catch (error, stack) {
      job.done.completeError(error, stack);
    } finally {
      _active--;
      _jobs.remove(job.page);
      _pump();
    }
  }

  void _accept(ReaderIndexPage page) {
    if (_metadata != null &&
        (_metadata!.pageSize != page.pageSize ||
            _metadata!.totalPages != page.totalPages)) {
      thumbnails.clear();
    }
    _metadata = page;
    thumbnails.addAll(page.thumbnails);
  }

  void _discardQueued() {
    for (final job in _queue) {
      _jobs.remove(job.page);
      job.done.completeError(ReaderIndexDiscarded());
    }
    _queue.clear();
  }
}

class _IndexJob {
  final int page;
  final done = Completer<ReaderIndexPage>();
  _IndexJob(this.page);
}
