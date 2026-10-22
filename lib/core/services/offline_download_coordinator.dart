import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import '../../models/offline_book.dart';
import '../../models/gallery_source.dart';
import '../../repositories/offline_repository.dart';
import '../network/api_exception.dart';
import '../network/offline_download_network.dart';
import '../network/reader_request_controller.dart';
import '../parser/gallery_detail_parser.dart';
import '../storage/database.dart';
import '../storage/offline_files.dart';

/// All UI and platform actions share this single queue and permit owner.
class OfflineDownloadCoordinator {
  final OfflineRepository repository;
  final OfflineDownloadNetwork network;
  final Future<void> Function() startBackground;
  final Future<void> Function() stopBackground;
  final Future<void> Function(Duration) delay;
  final _jobs = <String, _OfflineJob>{};
  final _pendingStarts = <String, Future<void>>{};
  final _pendingPauses = <String, Future<void>>{};
  final _revisions = <String, int>{};
  final _resumeContexts = <String, _ResumeContext>{};
  final _deleting = <String>{};
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<void>? _subscription;
  Timer? _notification;
  int galleryLimit;
  int pageLimit;
  int _metadata = 0;
  int _pages = 0;
  int _cursor = 0;
  bool _pumping = false;
  bool _pumpAgain = false;
  bool _closed = false;
  int _epoch = 0;
  bool _background = false;
  Future<void>? _startingBackground;
  Future<void>? _stoppingBackground;
  final Set<String> _iosSuspended = {};
  OfflineDownloadCoordinator(this.repository, this.network,
      {this.galleryLimit = 2,
      this.pageLimit = 4,
      Future<void> Function()? startBackground,
      Future<void> Function()? stopBackground,
      Future<void> Function(Duration)? delay})
      : startBackground = startBackground ?? (() async {}),
        stopBackground = stopBackground ?? (() async {}),
        delay = delay ?? Future<void>.delayed {
    _subscription = repository.changes.listen((_) => _notify());
  }
  Stream<void> get changes => _changes.stream;
  Set<String> get resumingIds => Set.unmodifiable(_pendingStarts.keys);
  bool get running => _jobs.values.any((j) => j.wanted || j.inFlight > 0);
  int get activePages => _pages;
  int get activeGalleries =>
      _jobs.values.where((j) => j.wanted && j.admitted).length;

  Future<void> initialize() => repository.initialize();

  Future<String> enqueue(OfflineKey key, String title, int totalPages) async {
    await initialize();
    if (key.source != network.source)
      throw const OfflineFailure('source_changed');
    final book = await repository.create(key, title, totalPages);
    await resume(book.id);
    return book.id;
  }

  Future<void> confirmLegacy(String id, GallerySource source) async {
    if (source != network.source) throw const OfflineFailure('source_changed');
    final book = await repository.stageLegacy(id, source);
    await resume(book.id);
  }

  Future<void> _ensureBackground() async {
    await _stoppingBackground;
    if (_background) return;
    await (_startingBackground ??= (() async {
      await startBackground();
      _background = true;
    })()
        .whenComplete(() => _startingBackground = null));
  }

  Future<void> resume(String id) {
    if (_closed || _deleting.contains(id)) return Future.value();
    final pending = _pendingStarts[id];
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _resume(id).whenComplete(() {
      if (identical(_pendingStarts[id], operation)) _pendingStarts.remove(id);
      _notify(immediate: true);
      _pump();
    });
    _pendingStarts[id] = operation;
    _notify(immediate: true);
    return operation;
  }

  Future<void> _resume(String id) async {
    final epoch = _epoch;
    final revision = _revisions[id] ?? 0;
    bool current() =>
        !_closed &&
        !_deleting.contains(id) &&
        epoch == _epoch &&
        revision == (_revisions[id] ?? 0);
    await _pendingPauses[id];
    await initialize();
    if (!current()) return;
    final previous = _jobs[id];
    if (previous?.wanted == true) return;
    if (previous != null) await previous.drained.future;
    if (!current()) return;
    final book = await repository.get(id);
    if (!current()) return;
    if (book == null || book.status == OfflineStatus.deleting) return;
    if (book.key == null) throw const OfflineFailure('source_required');
    if (book.source != network.source)
      throw const OfflineFailure('source_changed');
    if (book.complete) return;
    try {
      await _ensureBackground();
    } catch (_) {
      if (!current()) return;
      await repository.setStatus(id, OfflineStatus.paused,
          reason: 'background_unavailable');
      throw const OfflineFailure('background_unavailable');
    }
    if (!current()) {
      await _stopIfIdle();
      return;
    }
    final job = _OfflineJob(book, network.session);
    _jobs[id] = job;
    await repository.setStatus(id, OfflineStatus.queued);
    _notify(immediate: true);
    _pump();
  }

  void configure({required int galleries, required int pages}) {
    if (galleries < 1 || galleries > 3 || pages < 1 || pages > 6)
      throw ArgumentError('parallel limits');
    galleryLimit = galleries;
    pageLimit = pages;
    _pump();
  }

  bool _current(_OfflineJob job) =>
      !_closed &&
      job.wanted &&
      identical(_jobs[job.book.id], job) &&
      network.session == job.session &&
      network.source == job.book.source;

  void _pump() {
    if (_closed) return;
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumping = true;
    unawaited(_schedule().catchError((Object error, StackTrace stack) async {
      await pauseAll(reason: _reason(error));
    }).whenComplete(() {
      _pumping = false;
      if (_pumpAgain) {
        _pumpAgain = false;
        _pump();
      }
    }));
  }

  Future<void> _schedule() async {
    for (final job in List<_OfflineJob>.of(_jobs.values)) {
      if (job.wanted && !_current(job))
        await pause(job.book.id, reason: 'session_changed');
    }
    final candidates = _jobs.values.where((j) => j.wanted).toList()
      ..sort(
          (a, b) => a.book.record.createdAt.compareTo(b.book.record.createdAt));
    final selected = candidates.take(galleryLimit).toSet();
    for (final job in candidates) {
      if (!selected.contains(job)) {
        if (job.inFlight == 0 && !job.preparing && job.admitted) {
          job.admitted = false;
          await repository.setStatus(job.book.id, OfflineStatus.queued);
        }
      } else {
        // Existing over-limit work must drain before another book is admitted.
        final draining = candidates
            .where(
                (j) => !selected.contains(j) && (j.inFlight > 0 || j.preparing))
            .length;
        if (!job.admitted &&
            candidates.where((j) => j.admitted).length >=
                galleryLimit - draining) continue;
        job.admitted = true;
      }
    }
    if (_metadata == 0) {
      final waiting = candidates.where((j) =>
          selected.contains(j) && j.admitted && !j.prepared && !j.preparing);
      if (waiting.isNotEmpty) {
        final job = waiting.first;
        _metadata++;
        job.preparing = true;
        unawaited(_prepare(job).whenComplete(() {
          _metadata--;
          job.preparing = false;
          _drain(job);
          _pump();
        }));
      }
    }
    final ready = candidates
        .where((j) => selected.contains(j) && j.admitted && j.prepared)
        .toList();
    while (_pages < pageLimit && ready.isNotEmpty) {
      _OfflineJob? chosen;
      for (var i = 0; i < ready.length; i++) {
        final job = ready[_cursor++ % ready.length];
        if (_current(job) && job.pending.isNotEmpty) {
          chosen = job;
          break;
        }
      }
      if (chosen == null) break;
      final job = chosen;
      final page = job.pending.removeAt(0);
      final request = network.requests();
      job.requests.add(request);
      job.inFlight++;
      _pages++;
      unawaited(_download(job, page, request).whenComplete(() {
        request.cancel();
        job.requests.remove(request);
        job.inFlight--;
        _pages--;
        _drain(job);
        _notify();
        _pump();
      }));
    }
    for (final job in ready) {
      if (_current(job) &&
          !job.preparing &&
          job.pending.isEmpty &&
          job.inFlight == 0) {
        final latest = await repository.get(job.book.id);
        if (!_current(job)) continue;
        final complete = latest != null &&
            latest.record.indexReady &&
            latest.record.totalPages > 0 &&
            latest.completedPages == latest.record.totalPages;
        await repository.setStatus(job.book.id,
            complete ? OfflineStatus.completed : OfflineStatus.failed,
            reason: complete ? null : 'pages_failed');
        _resumeContexts.remove(job.book.id);
        job.wanted = false;
        _drain(job);
        _notify(immediate: true);
        _pumpAgain = true;
      }
    }
    await _stopIfIdle();
  }

  Future<void> _prepare(_OfflineJob job) async {
    final request = network.requests();
    job.requests.add(request);
    try {
      await repository.setStatus(job.book.id, OfflineStatus.preparing);
      if (!_current(job)) return;
      var context = _resumeContexts[job.book.id];
      final warm = context != null && context.matches(job.book, job.session);
      if (!warm) {
        _resumeContexts.remove(job.book.id);
        await _prepareIndex(job, request);
        if (!_current(job)) return;
        final indexed = await repository.get(job.book.id);
        if (!_current(job) || indexed == null) return;
        context = _ResumeContext(indexed, job.session);
      }
      final preparedContext = context;
      final pages = warm ? job.book.pages : await repository.pages(job.book.id);
      if (!_current(job)) return;
      job.resumeContext = preparedContext;
      if (warm) {
        // Known missing pages can start while existing files are checked.
        // Completion still waits for preparing to finish, including repairs.
        job.pending.addAll(pages.where((page) => page.status != 'completed'));
        job.prepared = true;
        await repository.setStatus(job.book.id, OfflineStatus.downloading);
        _pump();
      }
      // Bound filesystem concurrency without serially hashing an entire book.
      for (var offset = 0; offset < pages.length; offset += 8) {
        if (!_current(job)) return;
        final batch = pages.skip(offset).take(8).toList();
        final valid = await Future.wait(batch.map((page) async {
          if (page.status != 'completed' ||
              page.relativePath == null ||
              page.sha256 == null ||
              page.bytes <= 0) return false;
          final stamp = await repository.files.verifyForResume(
              page.relativePath!, page.bytes, page.sha256!,
              previous: preparedContext.verified[page.pageIndex]);
          if (stamp == null) {
            preparedContext.verified.remove(page.pageIndex);
            return false;
          }
          preparedContext.verified[page.pageIndex] = stamp;
          return true;
        }));
        if (!_current(job)) return;
        for (var i = 0; i < batch.length; i++) {
          final page = batch[i];
          if (valid[i] || (warm && page.status != 'completed')) continue;
          preparedContext.verified.remove(page.pageIndex);
          if (page.status == 'completed') {
            await repository.failPage(
                job.book.id, page.pageIndex, 'missing_file');
            if (!_current(job)) return;
          }
          if (!warm || page.status == 'completed') job.pending.add(page);
        }
      }
      if (!_current(job)) return;
      if (!warm) {
        _resumeContexts[job.book.id] = preparedContext;
        job.prepared = true;
        await repository.setStatus(job.book.id, OfflineStatus.downloading);
      }
    } catch (error) {
      if (_current(job)) await _failed(job, error);
    } finally {
      request.cancel();
      job.requests.remove(request);
    }
  }

  Future<void> _prepareIndex(
      _OfflineJob job, ReaderRequestController request) async {
    final first = await network.index(job.book.key!, 0, request);
    if (!_current(job)) return;
    final thumbs = List<ThumbnailInfo>.of(first.thumbnails.values);
    for (var page = 1; page < first.indexPageCount; page++) {
      final next = await network.index(job.book.key!, page, request);
      if (!_current(job)) return;
      if (next.totalPages != first.totalPages ||
          next.pageSize != first.pageSize) {
        throw const OfflineFailure('invalid_index');
      }
      thumbs.addAll(next.thumbnails.values);
    }
    await repository.putIndex(job.book.id, first.totalPages, thumbs,
        current: () => _current(job));
    if (job.book.record.legacyGid != null) {
      final old = (await repository.all()).where((b) =>
          b.source == null &&
          b.record.gid == job.book.record.legacyGid &&
          b.record.token == job.book.record.token);
      if (old.isNotEmpty)
        await repository.importLegacy(
            old.first, job.book.key!, first.totalPages, thumbs,
            current: () => _current(job));
    }
  }

  Stream<List<int>> _content(
      Stream<List<int>> source, ReaderRequestController request) {
    late final StreamController<List<int>> output;
    StreamSubscription<List<int>>? input;
    Future<void>? cancellation;
    Future<void> cancelInput() =>
        cancellation ??= (input?.cancel() ?? Future<void>.value())
            .catchError((Object error, StackTrace stack) {
          if (!request.isCancelled) Error.throwWithStackTrace(error, stack);
        });
    void cancelled() {
      if (!output.isClosed) {
        output.addError(const OfflineFailure('cancelled'));
        unawaited(output.close());
      }
    }

    output = StreamController<List<int>>(
      sync: true,
      onListen: () {
        input = source.listen(output.add, onError: output.addError, onDone: () {
          unawaited(output.close());
        });
        request.onCancel(() {
          // Await transport cleanup before the writer releases its permit.
          unawaited(cancelInput().then((_) => cancelled(),
              onError: (Object _, StackTrace __) => cancelled()));
        });
      },
      onPause: () => input?.pause(),
      onResume: () => input?.resume(),
      onCancel: cancelInput,
    );
    return output.stream;
  }

  Future<void> _download(_OfflineJob job, OfflinePage page,
      ReaderRequestController request) async {
    String? alternate;
    for (var attempt = 0; attempt < 3 && _current(job); attempt++) {
      try {
        final image = await network.image(
            job.book.key!, page.pageToken, page.pageIndex, request,
            alternate: alternate);
        alternate = image.nlKey;
        if (!_current(job)) return;
        final response = await network.bytes(image.imageUrl, request);
        if (!_current(job)) {
          await response.content.listen((_) {}).cancel();
          return;
        }
        if (response.statusCode != 200) {
          await response.content.listen((_) {}).cancel();
          throw ApiException.server(response.statusCode);
        }
        final saved = await repository.files.write(
            job.book.id, page.pageIndex, _content(response.content, request),
            expectedBytes: response.contentLength,
            current: () => _current(job));
        await repository.savePage(job.book.id, page.pageIndex, saved,
            current: () => _current(job));
        if (_current(job) && saved.verification != null) {
          job.resumeContext?.verified[page.pageIndex] = saved.verification!;
        }
        return;
      } catch (error) {
        if (!_current(job)) return;
        final reason = _reason(error);
        if (const [
          'authentication',
          'quota',
          'content_warning',
          'storage',
          'source_changed',
          'session_changed'
        ].contains(reason)) {
          await _failed(job, error);
          return;
        }
        if (attempt == 2) {
          if (reason == 'network')
            await pauseAll(reason: reason);
          else {
            // A later retry must be able to refresh an obsolete page token.
            _resumeContexts.remove(job.book.id);
            await repository.failPage(job.book.id, page.pageIndex, reason);
          }
          return;
        }
        await Future.any([
          delay(Duration(milliseconds: 500 * (attempt + 1))),
          request.cancelToken.whenCancel
        ]);
      }
    }
  }

  String _reason(Object error) {
    if (error is OfflineFailure) return error.code;
    if (error is FileSystemException) return 'storage';
    if (error is FormatException) return 'invalid_index';
    if (error is ApiException) {
      if (error.statusCode == 401 || error.statusCode == 403)
        return 'authentication';
      if (error.statusCode == 429 || error.statusCode == 509) return 'quota';
      return error.statusCode == null ? 'network' : 'server';
    }
    if (error is DioException && CancelToken.isCancel(error))
      return 'cancelled';
    return 'network';
  }

  Future<void> _failed(_OfflineJob job, Object error) async {
    final reason = _reason(error);
    if (reason == 'storage' || reason == 'network') {
      await pauseAll(reason: reason);
      return;
    }
    if (const [
      'authentication',
      'quota',
      'content_warning',
      'session_changed',
      'source_changed'
    ].contains(reason)) {
      final ids = _jobs.values
          .where(
              (other) => other.wanted && other.book.source == job.book.source)
          .map((other) => other.book.id)
          .toList();
      await Future.wait(ids.map((id) => pause(id, reason: reason)));
      return;
    }
    job.wanted = false;
    for (final request in job.requests) {
      request.cancel();
    }
    await repository.setStatus(job.book.id, OfflineStatus.failed,
        reason: reason);
    _notify(immediate: true);
  }

  Future<void> pause(String id, {String reason = 'user'}) {
    late final Future<void> operation;
    operation = _pause(id, reason).whenComplete(() {
      if (identical(_pendingPauses[id], operation)) _pendingPauses.remove(id);
      _pump();
    });
    _pendingPauses[id] = operation;
    return operation;
  }

  Future<void> _pause(String id, String reason) async {
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    _pendingStarts.remove(id);
    if (reason == 'session_changed' || reason == 'source_changed') {
      _resumeContexts.remove(id);
    }
    final job = _jobs[id];
    if (job != null) {
      job.wanted = false;
      job.pending.clear();
      for (final request in job.requests) {
        request.cancel();
      }
      _drain(job);
    }
    final record = await repository.get(id);
    if (record != null &&
        !const [
          OfflineStatus.completed,
          OfflineStatus.deleting,
          OfflineStatus.sourceRequired
        ].contains(record.status)) {
      await repository.setStatus(id, OfflineStatus.paused, reason: reason);
    }
    if (reason != 'background') _iosSuspended.remove(id);
    _notify(immediate: true);
    _pump();
  }

  Future<void> pauseAll({String reason = 'user'}) async {
    _epoch++;
    if (reason == 'session_changed' || reason == 'source_changed') {
      _resumeContexts.clear();
    }
    final ids = {
      ..._pendingStarts.keys,
      ..._jobs.values.where((j) => j.wanted).map((j) => j.book.id),
    };
    // Cancel every HTTP client before the first database await, particularly
    // when site/account changes could otherwise replace credentials mid-request.
    await Future.wait(ids.map((id) => pause(id, reason: reason)));
    await _stopIfIdle();
  }

  Future<void> suspendForIOS() async {
    _iosSuspended
        .addAll(_jobs.values.where((j) => j.wanted).map((j) => j.book.id));
    await pauseAll(reason: 'background');
  }

  Future<void> returnToForeground() async {
    final ids = _iosSuspended.toList();
    _iosSuspended.clear();
    for (final id in ids) {
      await resume(id);
    }
  }

  Future<void> delete(String id) async {
    if (!_deleting.add(id)) return;
    try {
      _resumeContexts.remove(id);
      await pause(id);
      final job = _jobs[id];
      if (job != null) await job.drained.future;
      await repository.setStatus(id, OfflineStatus.deleting);
      await repository.delete(id);
      _notify(immediate: true);
    } finally {
      _deleting.remove(id);
    }
  }

  Future<void> repair(String id, int page) async {
    final book = await repository.get(id);
    if (book == null) return;
    if (book.source == null) throw const OfflineFailure('source_required');
    if (book.source != network.source)
      throw const OfflineFailure('source_changed');
    final epoch = _epoch;
    final session = network.session;
    await pause(id);
    final job = _jobs[id];
    if (job != null) await job.drained.future;
    if (epoch != _epoch ||
        session != network.session ||
        book.source != network.source) {
      throw const OfflineFailure('session_changed');
    }
    _resumeContexts[id]?.verified.remove(page);
    await repository.failPage(id, page, 'repair');
    await repository.setStatus(id, OfflineStatus.paused);
    await resume(id);
  }

  void _drain(_OfflineJob job) {
    if (!job.wanted && job.inFlight == 0 && !job.preparing) {
      if (identical(_jobs[job.book.id], job)) _jobs.remove(job.book.id);
      if (!job.drained.isCompleted) job.drained.complete();
    }
  }

  Future<void> _stopIfIdle() async {
    if (running ||
        !_background ||
        _pendingStarts.isNotEmpty ||
        _pendingPauses.isNotEmpty) return;
    _background = false;
    await (_stoppingBackground ??=
        stopBackground().whenComplete(() => _stoppingBackground = null));
  }

  void _notify({bool immediate = false}) {
    if (_closed) return;
    if (immediate) {
      _notification?.cancel();
      _notification = null;
      _changes.add(null);
    } else {
      _notification ??= Timer(const Duration(milliseconds: 250), () {
        _notification = null;
        if (!_closed) _changes.add(null);
      });
    }
  }

  Future<void> dispose() async {
    await pauseAll(reason: 'interrupted');
    _closed = true;
    _resumeContexts.clear();
    await Future.wait(_jobs.values.map((j) => j.drained.future));
    _notification?.cancel();
    await _subscription?.cancel();
    if (_background) await stopBackground();
    await _changes.close();
  }
}

class _OfflineJob {
  final OfflineBook book;
  final Object? session;
  final drained = Completer<void>();
  final requests = <ReaderRequestController>{};
  final pending = <OfflinePage>[];
  bool wanted = true;
  bool admitted = false;
  bool preparing = false;
  bool prepared = false;
  int inFlight = 0;
  _ResumeContext? resumeContext;
  _OfflineJob(this.book, this.session);
}

class _ResumeContext {
  final GallerySource? source;
  final Object? session;
  final Map<int, String> tokens;
  final verified = <int, OfflineFileStamp>{};
  _ResumeContext(OfflineBook book, this.session)
      : source = book.source,
        tokens = {
          for (final page in book.pages) page.pageIndex: page.pageToken
        };

  bool matches(OfflineBook book, Object? session) =>
      source == book.source &&
      this.session == session &&
      book.record.indexReady &&
      book.record.totalPages == tokens.length &&
      book.pages.length == tokens.length &&
      book.pages.every((page) => tokens[page.pageIndex] == page.pageToken);
}
