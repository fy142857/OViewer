import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/offline_files.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/offline_repository.dart';

void sqliteForTests() {
  if (Platform.isWindows)
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqliteForTests);
  late Directory directory;
  late OfflineFiles files;
  late AppDatabase db;
  late OfflineRepository repository;
  late Map<String, dynamic> fixtures;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('oviewer-offline-');
    files =
        OfflineFiles(root: () async => Directory('${directory.path}/offline'));
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = OfflineRepository(db, files,
        legacyRoot: () async => Directory('${directory.path}/downloads'));
    fixtures = jsonDecode(
        await File('test/fixtures/page_image_formats.json').readAsString());
    fixtures['gif'] =
        'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7';
    await repository.initialize();
  });
  tearDown(() async {
    await repository.dispose();
    await db.close();
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
  });
  const key = OfflineKey(GallerySource.eh, 42, 'abc');
  for (final format in ['png', 'jpeg', 'gif', 'webp']) {
    test('$format keeps original binary bytes and validates before exposing',
        () async {
      final bytes = base64Decode(fixtures[format] as String);
      final result = await files.write(key.id, 0, Stream.value(bytes),
          current: () => true, expectedBytes: bytes.length);
      expect(await files.read(result.relativePath, result.bytes, result.digest),
          bytes);
      expect(result.digest, sha256.convert(bytes).toString());
      expect(await files.size(), bytes.length);
      expect(
          (await (await files.root).list(recursive: true).toList())
              .whereType<File>()
              .length,
          1);
    });
  }
  test('HTML and truncated bodies never survive as downloaded pages', () async {
    await expectLater(
        files.write(key.id, 0, Stream.value(utf8.encode('<html>login</html>')),
            current: () => true),
        throwsA(isA<OfflineFailure>()));
    final bytes = base64Decode(fixtures['png'] as String);
    await expectLater(
        files.write(key.id, 0, Stream.value(bytes),
            current: () => true, expectedBytes: bytes.length + 1),
        throwsA(isA<OfflineFailure>()));
    expect(await files.size(), 0);
  });
  test('cancellation after decode cannot leave a completed or partial file',
      () async {
    var current = true;
    final guarded = OfflineFiles(
        root: () async => Directory('${directory.path}/offline'),
        decode: (_) async {
          current = false;
        });
    await expectLater(
        guarded.write(key.id, 0, Stream.value(base64Decode(fixtures['png'])),
            current: () => current),
        throwsA(isA<OfflineFailure>()));
    expect(await files.size(), 0);
  });
  test('same gid on EH and EX is isolated and incomplete indices are refused',
      () async {
    final eh = await repository.create(key, 'EH', 2);
    final ex = await repository.create(
        const OfflineKey(GallerySource.ex, 42, 'abc'), 'EX', 2);
    expect(eh.id, isNot(ex.id));
    await expectLater(
        repository.putIndex(eh.id, 2,
            const [ThumbnailInfo(pageToken: 'p0', pageIndex: 0, thumbUrl: '')],
            current: () => true),
        throwsA(isA<OfflineFailure>()));
    expect((await repository.get(eh.id))!.record.indexReady, isFalse);
    expect((await repository.all()).length, 2);
  });
  test(
      'recovery keeps good files, rejects missing ones, and removes unregistered data',
      () async {
    final book = await repository.create(key, 'Book', 2);
    await repository.putIndex(
        book.id,
        2,
        const [
          ThumbnailInfo(pageToken: 'p0', pageIndex: 0, thumbUrl: ''),
          ThumbnailInfo(pageToken: 'p1', pageIndex: 1, thumbUrl: ''),
        ],
        current: () => true);
    final bytes = base64Decode(fixtures['png']);
    for (var page = 0; page < 2; page++) {
      final saved = await files.write(book.id, page, Stream.value(bytes),
          current: () => true);
      await repository.savePage(book.id, page, saved, current: () => true);
    }
    await repository.setStatus(book.id, OfflineStatus.completed);
    final pages = await repository.pages(book.id);
    await files.remove(pages.last.relativePath!);
    final orphan = await files.file('${book.id}/orphan.part');
    await orphan.writeAsString('partial');
    await repository.dispose();
    repository = OfflineRepository(db, files,
        legacyRoot: () async => Directory('${directory.path}/downloads'));
    await repository.initialize();
    final recovered = (await repository.get(book.id))!;
    expect(recovered.status, OfflineStatus.paused);
    expect(recovered.completedPages, 1);
    expect(
        await files.read(
            pages.first.relativePath!, pages.first.bytes, pages.first.sha256!),
        bytes);
    expect(await orphan.exists(), isFalse);
    expect(await repository.matching(42, 'abc', source: GallerySource.eh),
        hasLength(1));
    // A previously complete but damaged book stays local instead of silently
    // starting an online reader after cold-start reconciliation.
  });
  test(
      'legacy downloads keep unknown origin until verified and reuse only valid binary files',
      () async {
    await db.upsertDownload(DownloadTasksCompanion(
        gid: const Value(42),
        token: const Value('abc'),
        title: const Value('Legacy'),
        thumbUrl: const Value(''),
        totalPages: const Value(2),
        downloadedPages: const Value(2),
        status: const Value(3),
        createdAt: Value(DateTime(2026))));
    final legacy = Directory('${directory.path}/downloads/42');
    await legacy.create(recursive: true);
    await File('${legacy.path}/0000.jpg')
        .writeAsBytes(base64Decode(fixtures['png']));
    await File('${legacy.path}/0001.jpg')
        .writeAsString('<html>not an image</html>');
    await repository.dispose();
    repository = OfflineRepository(db, files,
        legacyRoot: () async => Directory('${directory.path}/downloads'));
    await repository.initialize();
    final old = (await repository.all()).single;
    expect(old.source, isNull);
    expect(old.complete, isFalse);
    expect(old.status, OfflineStatus.sourceRequired);
    final staged = await repository.stageLegacy(old.id, GallerySource.eh);
    expect(await repository.get(old.id), isNotNull);
    expect(staged.record.indexReady, isFalse);
    final migrated = await repository.importLegacy(
        old,
        key,
        2,
        const [
          ThumbnailInfo(pageToken: 'p0', pageIndex: 0, thumbUrl: ''),
          ThumbnailInfo(pageToken: 'p1', pageIndex: 1, thumbUrl: ''),
        ],
        current: () => true);
    expect(migrated.completedPages, 1);
    expect(migrated.complete, isFalse);
    expect(await legacy.exists(), isTrue);
    expect(await repository.get(old.id), isNull);
    await repository.delete(migrated.id);
    expect(await legacy.exists(), isFalse);
    expect(await repository.all(), isEmpty);
  });
  test('completed file cannot be registered after its task is cancelled',
      () async {
    final book = await repository.create(key, 'Book', 1);
    await repository.putIndex(book.id, 1,
        const [ThumbnailInfo(pageToken: 'p0', pageIndex: 0, thumbUrl: '')],
        current: () => true);
    final saved = await files.write(
        book.id, 0, Stream.value(base64Decode(fixtures['png'])),
        current: () => true);
    await expectLater(
        repository.savePage(book.id, 0, saved, current: () => false),
        throwsA(isA<OfflineFailure>()));
    expect((await repository.get(book.id))!.completedPages, 0);
    expect(await files.size(), 0);
  });
  test('offline file paths cannot escape the owned directory', () async {
    await expectLater(files.file('../outside'), throwsA(isA<OfflineFailure>()));
    await expectLater(
        files.file(directory.path), throwsA(isA<OfflineFailure>()));
  });
}
