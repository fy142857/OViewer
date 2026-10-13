import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:oviewer/core/network/offline_download_network.dart';
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
  Future<GalleryImage> image(OfflineKey key, String token, int page,
          ReaderRequestController requests,
          {String? alternate}) async =>
      GalleryImage(index: page, pageUrl: '', imageUrl: '${key.gid}/$page');
  @override
  Future<FileServiceResponse> bytes(
      String url, ReaderRequestController requests) async {
    calls[url] = (calls[url] ?? 0) + 1;
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
  late ControlledOfflineNetwork network;
  late OfflineDownloadCoordinator coordinator;
  var starts = 0;
  var stops = 0;
  setUp(() async {
    starts = 0;
    stops = 0;
    directory = await Directory.systemTemp.createTemp('oviewer-queue-');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = OfflineRepository(db,
        OfflineFiles(root: () async => Directory('${directory.path}/offline')),
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
