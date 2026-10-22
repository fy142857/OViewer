import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'offline_storage_test.dart' show sqliteForTests;
import 'offline_coordinator_test.dart'
    show CountingFiles, ControlledOfflineNetwork, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqliteForTests);
  late Directory root;
  late File databaseFile;
  late CountingFiles files;
  late AppDatabase db;
  late OfflineRepository repo;
  late ControlledOfflineNetwork network;
  late OfflineDownloadCoordinator coordinator;
  const key = OfflineKey(GallerySource.eh, 42, 'abc');

  void open() {
    files = CountingFiles(() async => Directory('${root.path}/files'));
    db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    repo = OfflineRepository(db, files,
        legacyRoot: () async => Directory('${root.path}/legacy'));
    coordinator =
        OfflineDownloadCoordinator(repo, network, delay: (_) async {});
  }

  Future<void> close() async {
    await coordinator.dispose();
    await repo.dispose();
    await db.close();
  }

  Future<void> restart() async {
    await close();
    open();
  }

  Future<void> seed({bool complete = false}) async {
    await repo.initialize();
    await repo.create(key, 'Book', 3);
    await repo.putIndex(
        key.id,
        3,
        List.generate(3,
            (i) => ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')),
        current: () => true);
    for (var i = 0; i < (complete ? 3 : 1); i++) {
      final file = await files.write(key.id, i, Stream.value(network.png),
          current: () => true);
      await repo.savePage(key.id, i, file, current: () => true);
    }
    if (complete) await repo.setStatus(key.id, OfflineStatus.completed);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oviewer-restart-');
    databaseFile = File('${root.path}/offline.sqlite');
    final data = jsonDecode(
        await File('test/fixtures/page_image_formats.json').readAsString());
    network = ControlledOfflineNetwork(base64Decode(data['png']));
    open();
  });
  tearDown(() async {
    network.release();
    await close();
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    await root.delete(recursive: true);
  });

  test(
      'closed SQLite and new objects restore index and verification with no hashing',
      () async {
    await seed();
    final original = (await repo.pages(key.id)).first;
    expect(original.verificationVersion, 1);
    expect(original.verifiedModifiedMicros, isNotNull);
    await restart();
    await coordinator.initialize();
    expect(network.indexed, isEmpty);
    expect(network.calls, isEmpty);
    expect(files.hashes, 0);
    await coordinator.resume(key.id);
    await until(() async => (await repo.get(key.id))!.complete);
    expect(network.indexed, isEmpty);
    expect(network.calls.keys, unorderedEquals(['42/1', '42/2']));
    expect(files.hashes, 0);
    expect(
        (await repo.pages(key.id)).first.relativePath, original.relativePath);
  });

  for (final mutation in ['missing', 'length', 'same_length', 'mtime_only']) {
    test('restart detects $mutation and reuses only valid completed pages',
        () async {
      await seed();
      final page = (await repo.pages(key.id)).first;
      final file = await files.file(page.relativePath!);
      if (mutation == 'missing') {
        await file.delete();
      } else {
        if (mutation != 'mtime_only')
          await file.writeAsBytes(
              List.filled(mutation == 'length' ? 1 : page.bytes, 0));
        await file.setLastModified(DateTime(2020));
      }
      await restart();
      await coordinator.initialize();
      expect(files.hashes,
          ['same_length', 'mtime_only'].contains(mutation) ? 1 : 0);
      final afterStartup = files.hashes;
      await coordinator.resume(key.id);
      await until(() async => (await repo.get(key.id))!.complete);
      expect(network.indexed, isEmpty);
      expect(network.calls['42/0'], mutation == 'mtime_only' ? isNull : 1);
      expect(files.hashes, afterStartup);
      await restart();
      await coordinator.initialize();
      expect(files.hashes, 0);
    });
  }

  test('older or unsupported verification evidence is hashed once and upgraded',
      () async {
    await seed();
    await (db.update(db.offlinePages)..where((t) => t.bookId.equals(key.id)))
        .write(const OfflinePagesCompanion(verificationVersion: Value(99)));
    await restart();
    await coordinator.initialize();
    expect(files.hashes, 1);
    expect((await repo.pages(key.id)).first.verificationVersion, 1);
    await restart();
    await coordinator.initialize();
    expect(files.hashes, 0);
  });

  test(
      'reader validates actual bytes even when durable metadata appears unchanged',
      () async {
    await seed();
    final page = (await repo.pages(key.id)).first;
    final file = await files.file(page.relativePath!);
    await file.writeAsBytes(List.filled(page.bytes, 0));
    await expectLater(
        files.read(page.relativePath!, page.bytes, page.sha256!),
        throwsA(isA<OfflineFailure>()
            .having((e) => e.code, 'code', 'damaged_file')));
  });

  for (final invalid in ['missing_page', 'empty_token', 'refresh_flag']) {
    test('restart refreshes $invalid index', () async {
      await seed();
      if (invalid == 'refresh_flag') {
        await repo.requireFreshIndex(key.id);
      } else if (invalid == 'missing_page') {
        await (db.delete(db.offlinePages)..where((t) => t.pageIndex.equals(2)))
            .go();
      } else {
        await (db.update(db.offlinePages)..where((t) => t.pageIndex.equals(2)))
            .write(const OfflinePagesCompanion(pageToken: Value('')));
      }
      await restart();
      await coordinator.resume(key.id);
      await until(() async => (await repo.get(key.id))!.complete);
      expect(network.indexed, [42]);
      expect((await repo.get(key.id))!.record.indexNeedsRefresh, isFalse);
    });
  }

  for (final persistent in [false, true]) {
    test(
        'expired persisted page token refreshes once (still invalid=$persistent)',
        () async {
      await seed();
      await (db.update(db.offlinePages)..where((t) => t.pageIndex.equals(2)))
          .write(const OfflinePagesCompanion(pageToken: Value('expired')));
      network.invalidTokens.add('expired');
      if (persistent) network.invalidTokens.add('p2');
      await restart();
      await coordinator.resume(key.id);
      await until(() async {
        final book = (await repo.get(key.id))!;
        return book.complete || book.status == OfflineStatus.failed;
      });
      expect(network.indexed, [42]);
      expect((await repo.get(key.id))!.complete, !persistent);
      expect(network.calls['42/0'], isNull);
      if (persistent)
        expect((await repo.get(key.id))!.record.indexNeedsRefresh, isTrue);
    });
  }

  test('failed page persists refresh requirement across a restart', () async {
    await seed();
    network.statuses['42/1'] = 404;
    await coordinator.resume(key.id);
    await until(
        () async => (await repo.get(key.id))!.status == OfflineStatus.failed);
    expect((await repo.get(key.id))!.record.indexNeedsRefresh, isTrue);
    await restart();
    network.statuses.clear();
    await coordinator.resume(key.id);
    await until(() async => (await repo.get(key.id))!.complete);
    expect(network.indexed, [42]);
    expect(network.calls['42/0'], isNull);
  });

  test('late verification cannot overwrite a replacement page after restart',
      () async {
    await seed();
    var old = (await repo.pages(key.id)).first;
    await (db.update(db.offlinePages)..where((t) => t.pageIndex.equals(0)))
        .write(const OfflinePagesCompanion(verificationVersion: Value(0)));
    old = (await repo.pages(key.id)).first;
    files.afterVerificationGate = Completer<void>();
    final verifying = repo.verifyForResume(old, current: () => true);
    await until(() => files.verificationResults == 1);
    final replacement = await files.write(key.id, 0, Stream.value(network.png),
        current: () => true);
    await repo.savePage(key.id, 0, replacement, current: () => true);
    files.afterVerificationGate!.complete();
    await verifying;
    await restart();
    await coordinator.initialize();
    final page = (await repo.pages(key.id)).first;
    expect(page.relativePath, replacement.relativePath);
    expect(page.verifiedModifiedMicros,
        replacement.verification!.modified.microsecondsSinceEpoch);
    expect(files.hashes, 0);
  });

  test('cancelled verification cannot publish a durable success record',
      () async {
    await seed();
    await (db.update(db.offlinePages)..where((t) => t.pageIndex.equals(0)))
        .write(const OfflinePagesCompanion(verificationVersion: Value(0)));
    final page = (await repo.pages(key.id)).first;
    files.afterVerificationGate = Completer<void>();
    var current = true;
    final verifying = repo.verifyForResume(page, current: () => current);
    await until(() => files.verificationResults == 1);
    current = false;
    final assertion = expectLater(
        verifying,
        throwsA(
            isA<OfflineFailure>().having((e) => e.code, 'code', 'cancelled')));
    files.afterVerificationGate!.complete();
    await assertion;
    expect((await repo.pages(key.id)).first.verificationVersion, 0);
  });

  test('persisted EH index cannot be resumed through EX', () async {
    await seed();
    await restart();
    network.source = GallerySource.ex;
    await expectLater(
        coordinator.resume(key.id),
        throwsA(isA<OfflineFailure>()
            .having((e) => e.code, 'code', 'source_changed')));
    expect(network.indexed, isEmpty);
    expect(network.imageCalls, 0);
    expect((await repo.get(key.id))!.completedPages, 1);
  });

  test('repair clears durable verification and deletion leaves no task records',
      () async {
    await seed();
    await repo.failPage(key.id, 0, 'repair');
    final page = (await repo.pages(key.id)).first;
    expect(page.verificationVersion, 0);
    expect(page.verifiedModifiedMicros, isNull);
    await restart();
    await coordinator.resume(key.id);
    await until(() async => (await repo.get(key.id))!.complete);
    expect(network.calls['42/0'], 1);
    await coordinator.delete(key.id);
    await restart();
    await coordinator.initialize();
    expect(await repo.get(key.id), isNull);
    expect(await repo.pages(key.id), isEmpty);
    expect(await files.size(), 0);
  });

  test(
      'v3 database migration preserves files and progress and verifies legacy evidence once',
      () async {
    await close();
    final legacy = sqlite.sqlite3.open(databaseFile.path);
    legacy.execute("""
CREATE TABLE download_tasks (gid INTEGER PRIMARY KEY, token TEXT NOT NULL, title TEXT NOT NULL,
 thumb_url TEXT NOT NULL, total_pages INTEGER NOT NULL, downloaded_pages INTEGER NOT NULL DEFAULT 0,
 status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
CREATE TABLE offline_galleries (id TEXT PRIMARY KEY, source TEXT, gid INTEGER NOT NULL, token TEXT NOT NULL,
 title TEXT NOT NULL, total_pages INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'paused', reason TEXT,
 created_at INTEGER NOT NULL, last_read_page INTEGER NOT NULL DEFAULT 0, index_ready INTEGER NOT NULL DEFAULT 0,
 ever_completed INTEGER NOT NULL DEFAULT 0, legacy_gid INTEGER);
CREATE TABLE offline_pages (book_id TEXT NOT NULL REFERENCES offline_galleries(id), page_index INTEGER NOT NULL,
 page_token TEXT NOT NULL, relative_path TEXT, format TEXT, bytes INTEGER NOT NULL DEFAULT 0,
 sha256 TEXT, status TEXT NOT NULL DEFAULT 'pending', error TEXT, PRIMARY KEY (book_id, page_index));
PRAGMA user_version = 3;
""");
    final saved = await files.write(key.id, 0, Stream.value(network.png),
        current: () => true);
    legacy.execute(
        'INSERT INTO offline_galleries(id,source,gid,token,title,total_pages,status,created_at,last_read_page,index_ready) VALUES(?,?,?,?,?,?,?,?,?,?)',
        [key.id, 'eh', 42, 'abc', 'Old book', 3, 'paused', 1700000000, 1, 1]);
    for (var i = 0; i < 3; i++) {
      legacy.execute(
          'INSERT INTO offline_pages(book_id,page_index,page_token,relative_path,format,bytes,sha256,status) VALUES(?,?,?,?,?,?,?,?)',
          [
            key.id,
            i,
            'p$i',
            i == 0 ? saved.relativePath : null,
            i == 0 ? saved.format : null,
            i == 0 ? saved.bytes : 0,
            i == 0 ? saved.digest : null,
            i == 0 ? 'completed' : 'pending'
          ]);
    }
    legacy.dispose();
    open();
    await coordinator.initialize();
    expect(files.hashes, 1);
    expect((await repo.get(key.id))!.record.lastReadPage, 1);
    expect((await repo.get(key.id))!.record.title, 'Old book');
    expect((await repo.pages(key.id)).first.relativePath, saved.relativePath);
    expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        4);
    await restart();
    await coordinator.resume(key.id);
    await until(() async => (await repo.get(key.id))!.complete);
    expect(files.hashes, 0);
    expect(network.indexed, isEmpty);
    expect(network.calls['42/0'], isNull);
  });
}
