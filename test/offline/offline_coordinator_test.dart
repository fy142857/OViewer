import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:oviewer/core/network/offline_download_network.dart';
import 'package:oviewer/core/network/api_exception.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/offline_files.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'offline_storage_test.dart' show sqliteForTests;

class ControlledOfflineNetwork extends OfflineDownloadNetwork {
  @override
  int session = 0;
  @override
  GallerySource source = GallerySource.eh;
  final Uint8List png;
  bool hold = false;
  bool invalid = false;
  bool stallStream = false;
  Completer<void>? indexGate;
  Completer<void>? cancelGate;
  int imageCalls = 0;
  final invalidTokens = <String>{};
  int total = 3;
  int active = 0;
  int peak = 0;
  final Map<String, int> calls = {};
  final Map<String, int> statuses = {};
  final gates = <Completer<void>>[];
  final indexed = <int>[];
  final controllers = <ReaderRequestController>[];
  ControlledOfflineNetwork(this.png);
  @override
  ReaderRequestController requests() {
    final value = ReaderRequestController();
    controllers.add(value);
    return value;
  }

  @override
  Future<ReaderIndexPage> index(
      OfflineKey key, int page, ReaderRequestController requests) async {
    indexed.add(key.gid);
    final gate = indexGate;
    if (gate != null) {
      requests.onCancel(() {
        if (!gate.isCompleted) gate.complete();
      });
      await gate.future;
      if (requests.isCancelled) throw const OfflineFailure('cancelled');
    }
    return ReaderIndexPage(
        totalPages: total,
        indexPage: 0,
        indexPageCount: 1,
        pageSize: total,
        thumbnails: {
          for (var i = 0; i < total; i++)
            i: ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')
        });
  }

  @override
  Future<GalleryImage> image(
      OfflineKey key, String token, int page, ReaderRequestController requests,
      {String? alternate}) async {
    imageCalls++;
    if (invalidTokens.contains(token)) throw ApiException.server(404);
    return GalleryImage(index: page, pageUrl: '', imageUrl: '${key.gid}/$page');
  }

  @override
  Future<FileServiceResponse> bytes(
      String url, ReaderRequestController requests) async {
    calls[url] = (calls[url] ?? 0) + 1;
    if (stallStream) {
      final stream = StreamController<List<int>>(onListen: () {
        active++;
        if (active > peak) peak = active;
      }, onCancel: () async {
        await cancelGate?.future;
        active--;
      });
      return HttpGetResponse(
          http.StreamedResponse(stream.stream, statuses[url] ?? 200));
    }
    final gate = Completer<void>();
    gates.add(gate);
    if (!hold) gate.complete();
    requests.onCancel(() {
      if (!gate.isCompleted) gate.complete();
    });
    final data = invalid ? Uint8List.fromList([1, 2, 3]) : png;
    Stream<List<int>> content() async* {
      active++;
      if (active > peak) peak = active;
      try {
        await gate.future;
        if (requests.isCancelled) throw const OfflineFailure('cancelled');
        yield data;
      } finally {
        active--;
      }
    }

    return HttpGetResponse(http.StreamedResponse(
        content(), statuses[url] ?? 200,
        contentLength: data.length));
  }

  void release() {
    hold = false;
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

Future<void> until(FutureOr<bool> Function() predicate) async {
  for (var i = 0; i < 400; i++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition not reached');
}

class CountingFiles extends OfflineFiles {
  int hashes = 0;
  int verificationResults = 0;
  bool shortTimeout = false;
  Completer<void>? verificationGate;
  Completer<void>? afterVerificationGate;
  @override
  Future<OfflineFileStamp?> verifyForResume(
      String relative, int size, String digest,
      {OfflineFileStamp? previous}) async {
    await verificationGate?.future;
    final result =
        await super.verifyForResume(relative, size, digest, previous: previous);
    verificationResults++;
    await afterVerificationGate?.future;
    return result;
  }

  @override
  Future<OfflineFileInfo> write(
          String bookId, int page, Stream<List<int>> source,
          {required bool Function() current, int? expectedBytes}) =>
      super.write(
          bookId,
          page,
          shortTimeout
              ? source.timeout(const Duration(milliseconds: 15))
              : source,
          current: current,
          expectedBytes: expectedBytes);
  CountingFiles(Future<Directory> Function() root) : super(root: root);
  @override
  Future<String> digestOf(File file) {
    hashes++;
    return super.digestOf(file);
  }
}

class FullDiskFiles extends OfflineFiles {
  FullDiskFiles(Future<Directory> Function() root) : super(root: root);
  @override
  Future<OfflineFileInfo> write(
      String bookId, int page, Stream<List<int>> source,
      {required bool Function() current, int? expectedBytes}) {
    if (page == 1)
      return Future.error(const FileSystemException(
          'No space left', '', OSError('No space left', 28)));
    return super.write(bookId, page, source,
        current: current, expectedBytes: expectedBytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqliteForTests);
  late Directory directory;
  late AppDatabase db;
  late OfflineRepository repo;
  late CountingFiles files;
  late ControlledOfflineNetwork network;
  late OfflineDownloadCoordinator coordinator;
  var starts = 0;
  var stops = 0;
  setUp(() async {
    starts = 0;
    stops = 0;
    directory = await Directory.systemTemp.createTemp('oviewer-queue-');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    files = CountingFiles(() async => Directory('${directory.path}/offline'));
    repo = OfflineRepository(db, files,
        legacyRoot: () async => Directory('${directory.path}/legacy'));
    final fixtures = jsonDecode(
        await File('test/fixtures/page_image_formats.json').readAsString());
    network = ControlledOfflineNetwork(base64Decode(fixtures['png']));
    coordinator = OfflineDownloadCoordinator(repo, network, delay: (_) async {},
        startBackground: () async {
      starts++;
    }, stopBackground: () async {
      stops++;
    });
    await coordinator.initialize();
  });
  tearDown(() async {
    network.release();
    await coordinator.dispose();
    await repo.dispose();
    await db.close();
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
  });
  const key = OfflineKey(GallerySource.eh, 42, 'abc');
  test(
      'complete means every page is decoded and durable; duplicate starts share one worker',
      () async {
    network.hold = true;
    final id = await coordinator.enqueue(key, 'Book', 3);
    await Future.wait([coordinator.resume(id), coordinator.resume(id)]);
    await until(() => network.calls.length == 3);
    expect(network.calls.values, everyElement(1));
    expect(starts, 1);
    network.release();
    await until(() async => (await repo.get(id))!.complete);
    await until(() => stops == 1);
    expect((await repo.get(id))!.completedPages, 3);
    expect(coordinator.activePages, 0);
  });
  test('zero valid pages never becomes completed and retries are bounded',
      () async {
    network.invalid = true;
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(
        () async => (await repo.get(id))!.status == OfflineStatus.failed);
    expect((await repo.get(id))!.completedPages, 0);
    expect(network.calls.values, everyElement(3));
    expect(await repo.files.size(), 0);
  });
  for (final limit in [1, 6]) {
    test('3 books share global $limit page permits', () async {
      coordinator.configure(galleries: 3, pages: limit);
      network.hold = true;
      for (var i = 1; i <= 3; i++) {
        await coordinator.enqueue(
            OfflineKey(GallerySource.eh, i, 'abc'), 'Book $i', 3);
      }
      await until(() => network.active == limit);
      expect(network.peak, limit);
      expect(coordinator.activeGalleries, lessThanOrEqualTo(3));
      network.release();
      await until(() async => (await repo.all()).every((b) => b.complete));
      expect(network.peak, lessThanOrEqualTo(limit));
      expect(network.calls.length, 9);
    });
  }
  test('lower limits drain existing transfers without starting extra work',
      () async {
    coordinator.configure(galleries: 3, pages: 6);
    network.total = 5;
    network.hold = true;
    for (var i = 1; i <= 3; i++) {
      await coordinator.enqueue(
          OfflineKey(GallerySource.eh, i, 'abc'), 'Book $i', 5);
    }
    await until(() => network.active == 6);
    coordinator.configure(galleries: 1, pages: 1);
    final before = network.calls.length;
    network.gates.first.complete();
    await until(() => coordinator.activePages == 5);
    expect(network.calls.length, before);
    network.release();
    await until(() async => (await repo.all()).every((b) => b.complete));
    expect(network.calls.values, everyElement(1));
  });
  test('pause cancels in-flight requests; resume keeps already committed pages',
      () async {
    coordinator.configure(galleries: 1, pages: 1);
    network.hold = true;
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.active == 1);
    network.gates.first.complete();
    await until(() => network.calls.containsKey('42/1'));
    await coordinator.pause(id);
    await until(() => coordinator.activePages == 0);
    expect((await repo.get(id))!.completedPages, 1);
    network.release();
    await coordinator.resume(id);
    await until(() async => (await repo.get(id))!.complete);
    expect(network.calls['42/0'], 1);
  });
  Future<String> pauseAfterOne() async {
    coordinator.configure(galleries: 1, pages: 1);
    network.hold = true;
    final id = await coordinator.enqueue(key, 'Book', network.total);
    await until(() => network.active == 1);
    network.gates.first.complete();
    await until(() => network.calls.containsKey('42/1'));
    await coordinator.pause(id);
    await until(() => coordinator.activePages == 0);
    return id;
  }

  test('warm resume reuses full index and verified files without hashing',
      () async {
    final id = await pauseAfterOne();
    final hashes = files.hashes;
    await coordinator.resume(id);
    await until(() => network.calls['42/1'] == 2);
    expect(network.indexed, [42]);
    expect(files.hashes, hashes);
    expect(network.calls['42/0'], 1);
    network.release();
    await until(() async => (await repo.get(id))!.complete);
  });

  test('warm downloads start before checks finish but cannot complete early',
      () async {
    final id = await pauseAfterOne();
    files.verificationGate = Completer<void>();
    network.release();
    await coordinator.resume(id);
    await until(() async => (await repo.get(id))!.completedPages == 3);
    expect((await repo.get(id))!.status, OfflineStatus.downloading);
    final page = (await repo.pages(id)).first;
    await (await files.file(page.relativePath!)).delete();
    files.verificationGate!.complete();
    await until(() async => (await repo.get(id))!.complete);
    expect(network.calls['42/0'], 2);
    expect(network.calls['42/2'], 1);
  });

  for (final damage in ['missing', 'length', 'same_length', 'mtime_only']) {
    test('warm resume rechecks a $damage completed file', () async {
      final id = await pauseAfterOne();
      final page = (await repo.pages(id)).first;
      final file = await files.file(page.relativePath!);
      if (damage == 'missing') {
        await file.delete();
      } else if (damage != 'mtime_only') {
        await file
            .writeAsBytes(List.filled(damage == 'length' ? 1 : page.bytes, 0));
      }
      if (damage != 'missing') await file.setLastModified(DateTime(2020));
      final hashes = files.hashes;
      network.release();
      await coordinator.resume(id);
      await until(() async => (await repo.get(id))!.complete);
      expect(network.calls['42/0'], damage == 'mtime_only' ? 1 : 2);
      expect(files.hashes - hashes,
          ['mtime_only', 'same_length'].contains(damage) ? 1 : 0);
    });
  }

  test('pause during index fetch never creates a reusable partial index',
      () async {
    network.indexGate = Completer<void>();
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.indexed.isNotEmpty);
    await coordinator.pause(id);
    network.indexGate = null;
    await coordinator.resume(id);
    await until(() async => (await repo.get(id))!.complete);
    expect(network.indexed, [42, 42]);
  });

  for (final reason in ['source_changed', 'session_changed']) {
    test('$reason invalidates even an already paused warm task', () async {
      final id = await pauseAfterOne();
      await coordinator.pauseAll(reason: reason);
      final hashes = files.hashes;
      network.release();
      await coordinator.resume(id);
      await until(() async => (await repo.get(id))!.complete);
      expect(network.indexed, [42, 42]);
      expect(files.hashes, hashes);
    });
  }

  test('cold resume reuses persisted directory and verification', () async {
    final id = await pauseAfterOne();
    await coordinator.dispose();
    await repo.dispose();
    repo = OfflineRepository(db, files,
        legacyRoot: () async => Directory('${directory.path}/legacy'));
    coordinator = OfflineDownloadCoordinator(repo, network);
    final hashes = files.hashes;
    network.release();
    await coordinator.resume(id);
    await until(() async => (await repo.get(id))!.complete);
    expect(network.indexed, [42]);
    expect(files.hashes, hashes);
  });

  test('a failed page refreshes the directory on the next retry', () async {
    final id = await pauseAfterOne();
    network.statuses['42/1'] = 404;
    network.release();
    await coordinator.resume(id);
    await until(
        () async => (await repo.get(id))!.status == OfflineStatus.failed);
    network.statuses.clear();
    await coordinator.resume(id);
    await until(() async => (await repo.get(id))!.complete);
    expect(network.indexed, [42, 42]);
    expect(network.calls['42/0'], 1);
  });

  test('stalled stream cancels immediately without waiting for read timeout',
      () async {
    network.stallStream = true;
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.active == 3);
    await coordinator.pause(id);
    await until(() => coordinator.activePages == 0);
    expect(network.active, 0);
    expect(await files.size(), 0);
    network.stallStream = false;
    await coordinator.resume(id);
    await until(() async => (await repo.get(id))!.complete);
    expect(network.indexed, [42]);
  });

  test('read timeout cancels stalled streams and retries stay bounded',
      () async {
    network.total = 1;
    network.stallStream = true;
    files.shortTimeout = true;
    final id = await coordinator.enqueue(key, 'Book', 1);
    await until(() async => (await repo.get(id))!.record.reason == 'network');
    await until(() => coordinator.activePages == 0);
    expect(network.calls['42/0'], 3);
    expect(network.active, 0);
    expect(await files.size(), 0);
  });

  test('error response discards its stalled body without draining it',
      () async {
    network.total = 1;
    network.stallStream = true;
    network.statuses['42/0'] = 403;
    final id = await coordinator.enqueue(key, 'Book', 1);
    await until(
        () async => (await repo.get(id))!.record.reason == 'authentication');
    await until(() => coordinator.activePages == 0);
    expect(network.calls['42/0'], 1);
    expect(network.active, 0);
  });

  test('failed background startup clears resume state and permits retry',
      () async {
    await coordinator.dispose();
    var fail = true;
    coordinator =
        OfflineDownloadCoordinator(repo, network, startBackground: () async {
      if (fail) throw StateError('service unavailable');
    });
    await repo.create(key, 'Book', 3);
    await expectLater(
        coordinator.resume(key.id),
        throwsA(isA<OfflineFailure>()
            .having((e) => e.code, 'code', 'background_unavailable')));
    expect(coordinator.resumingIds, isEmpty);
    expect((await repo.get(key.id))!.status, OfflineStatus.paused);
    fail = false;
    await coordinator.resume(key.id);
    await until(() async => (await repo.get(key.id))!.complete);
  });

  test('pause all also cancels resumes waiting for background service startup',
      () async {
    await coordinator.dispose();
    final gate = Completer<void>();
    coordinator = OfflineDownloadCoordinator(repo, network,
        startBackground: () => gate.future);
    await repo.create(key, 'Book', 3);
    final starting = coordinator.resume(key.id);
    await until(() => coordinator.resumingIds.contains(key.id));
    await coordinator.pauseAll(reason: 'source_changed');
    gate.complete();
    await starting;
    expect(coordinator.resumingIds, isEmpty);
    expect(network.indexed, isEmpty);
    expect((await repo.get(key.id))!.status, OfflineStatus.paused);
  });

  test('latest resume wins while cancelled writers are still cleaning up',
      () async {
    network.stallStream = true;
    network.cancelGate = Completer<void>();
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.active == 3);
    await coordinator.pause(id);
    final first = coordinator.resume(id);
    expect(coordinator.resumingIds, contains(id));
    await coordinator.pause(id);
    final latest = coordinator.resume(id);
    expect(identical(first, latest), isFalse);
    expect(identical(latest, coordinator.resume(id)), isTrue);
    expect(network.imageCalls, 3);
    network.stallStream = false;
    network.cancelGate!.complete();
    await Future.wait([first, latest]);
    await until(() async => (await repo.get(id))!.complete);
    expect(network.calls.values, everyElement(2));
    expect(network.peak, lessThanOrEqualTo(coordinator.pageLimit));
    expect(coordinator.resumingIds, isEmpty);
  });

  test('delete cancels a pending resume without resurrecting the book',
      () async {
    network.stallStream = true;
    network.cancelGate = Completer<void>();
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.active == 3);
    await coordinator.pause(id);
    final resuming = coordinator.resume(id);
    final deleting = coordinator.delete(id);
    await coordinator.resume(id);
    network.cancelGate!.complete();
    await Future.wait([resuming, deleting]);
    expect(await repo.get(id), isNull);
    expect(await files.size(), 0);
    expect(network.imageCalls, 3);
  });

  test('repair invalidates a warm completed page without refetching the index',
      () async {
    final id = await pauseAfterOne();
    network.release();
    await coordinator.repair(id, 0);
    await until(() async => (await repo.get(id))!.complete);
    expect(network.indexed, [42]);
    expect(network.calls['42/0'], 2);
  });

  test('delete waits for cancelled work and cannot resurrect files or records',
      () async {
    network.hold = true;
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.active > 0);
    await coordinator.delete(id);
    expect(await repo.get(id), isNull);
    expect(await repo.files.size(), 0);
    expect(coordinator.activePages, 0);
  });
  test(
      'global pause cancels every client synchronously before persistence awaits',
      () async {
    network.hold = true;
    await coordinator.enqueue(key, 'First', 3);
    await coordinator.enqueue(
        const OfflineKey(GallerySource.eh, 43, 'abc'), 'Second', 3);
    await until(() => network.active == 4);
    final stopping = coordinator.pauseAll(reason: 'session_changed');
    expect(network.controllers.every((c) => c.isCancelled), isTrue);
    await stopping;
    await until(() => coordinator.activePages == 0);
  });
  test('repair on the wrong site leaves a completed local book intact',
      () async {
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() async => (await repo.get(id))!.complete);
    final calls = Map<String, int>.of(network.calls);
    network.source = GallerySource.ex;
    await expectLater(
        coordinator.repair(id, 0),
        throwsA(isA<OfflineFailure>()
            .having((e) => e.code, 'code', 'source_changed')));
    expect((await repo.get(id))!.complete, isTrue);
    expect(network.calls, calls);
    expect(await repo.valid((await repo.pages(id)).first), isTrue);
  });
  test('source and session changes prevent stale writes', () async {
    network.hold = true;
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.active > 0);
    network.session++;
    await coordinator.pauseAll(reason: 'session_changed');
    network.release();
    await until(() => coordinator.activePages == 0);
    expect((await repo.get(id))!.completedPages, 0);
    network.source = GallerySource.ex;
    await expectLater(coordinator.resume(id), throwsA(isA<OfflineFailure>()));
    expect((await repo.get(id))!.source, GallerySource.eh);
  });
  test('iOS foreground restores background-paused jobs, not manual pauses',
      () async {
    network.hold = true;
    final first = await coordinator.enqueue(key, 'First', 3);
    final second = await coordinator.enqueue(
        const OfflineKey(GallerySource.eh, 43, 'abc'), 'Second', 3);
    await until(() => network.active > 0);
    await coordinator.pause(second);
    await coordinator.suspendForIOS();
    await until(() => coordinator.activePages == 0);
    expect((await repo.get(first))!.record.reason, 'background');
    expect((await repo.get(second))!.record.reason, 'user');
    network.release();
    await coordinator.returnToForeground();
    await until(() async => (await repo.get(first))!.complete);
    expect((await repo.get(second))!.status, OfflineStatus.paused);
  });
  test('cold restart pauses interrupted jobs and makes no network request',
      () async {
    network.hold = true;
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(() => network.active > 0);
    await coordinator.dispose();
    await repo.dispose();
    repo = OfflineRepository(db, repo.files,
        legacyRoot: () async => Directory('${directory.path}/legacy'));
    final previousCalls = Map<String, int>.of(network.calls);
    coordinator = OfflineDownloadCoordinator(repo, network);
    await coordinator.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect((await repo.get(id))!.status, OfflineStatus.paused);
    expect(network.calls, previousCalls);
    expect(coordinator.running, isFalse);
  });
  for (final status in [401, 509]) {
    test('access failure $status pauses the task and keeps completed pages',
        () async {
      coordinator.configure(galleries: 1, pages: 1);
      network.statuses['42/1'] = status;
      final id = await coordinator.enqueue(key, 'Book', 3);
      await until(
          () async => (await repo.get(id))!.status == OfflineStatus.paused);
      expect((await repo.get(id))!.completedPages, 1);
      expect((await repo.get(id))!.record.reason,
          status == 401 ? 'authentication' : 'quota');
      expect(network.calls['42/1'], 1);
      expect(network.calls.containsKey('42/2'), isFalse);
      expect(await repo.valid((await repo.pages(id)).first), isTrue);
    });
  }
  test('disk full pauses without losing the previously committed page',
      () async {
    await coordinator.dispose();
    await repo.dispose();
    repo = OfflineRepository(
        db, FullDiskFiles(() async => Directory('${directory.path}/offline')),
        legacyRoot: () async => Directory('${directory.path}/legacy'));
    coordinator = OfflineDownloadCoordinator(repo, network,
        galleryLimit: 1, pageLimit: 1);
    final id = await coordinator.enqueue(key, 'Book', 3);
    await until(
        () async => (await repo.get(id))!.status == OfflineStatus.paused);
    expect((await repo.get(id))!.record.reason, 'storage');
    expect((await repo.get(id))!.completedPages, 1);
    expect(await repo.valid((await repo.pages(id)).first), isTrue);
  });
}
