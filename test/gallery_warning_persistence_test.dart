import 'dart:ffi';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqlite3/open.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/parser/gallery_content_warning.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'core/network/comment_redirect_test.dart';
import 'gallery_warning_test.dart' show detail, warning;

void main() {
  setUpAll(() {
    registerFallbackValue(FakeDio());
    // Windows supplies SQLite as winsqlite3; Linux/macOS use libsqlite3.
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
  });
  late Directory directory;
  late File file;
  late AppDatabase db;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('oviewer-warning-test-');
    file = File('${directory.path}/app.db');
    db = AppDatabase.forTesting(NativeDatabase(file));
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
    ReaderIndexCache.shared.clear();
    AppConstants.useExHentai = false;
  });

  test('version 1 upgrade preserves history/progress and stores new choices',
      () async {
    await db.customStatement('''INSERT INTO history_entries
      (gid, token, title, thumb_url, last_read_at, last_read_page)
      VALUES (42, 'abc', 'Test', '', 100, 7)''');
    // The three original tables have the same schema in versions 1 and 2.
    await db.customStatement('DROP TABLE gallery_warning_acceptances');
    await db.customStatement('PRAGMA user_version = 1');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await db.getHistoryEntry(42))!.lastReadPage, 7);
    expect(await db.hasAcceptedGalleryWarning(42), isFalse);
    await db.acceptGalleryWarning(42, 'abc');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect(await db.hasAcceptedGalleryWarning(42, token: 'abc'), isTrue);
    expect(await db.hasAcceptedGalleryWarning(42, token: 'def'), isFalse);
    expect((await db.getHistoryEntry(42))!.title, 'Test');
  });

  test('restart and site switch keep confirmation; deleting history revokes it',
      () async {
    final adapter = RedirectAdapter((r, _) => ResponseBody.fromString(
        '${r.headers['cookie']}'.contains('nw=1')
            ? detail
            : warning(r.uri.origin),
        200));
    var dio = client(adapter, database: db);
    var repo = GalleryRepository(dio);
    await expectLater(repo.fetchGalleryDetail(42, 'abc'),
        throwsA(isA<GalleryContentWarning>()));
    await repo.acceptGalleryWarning(42, 'abc');
    expect((await repo.fetchGalleryDetail(42, 'abc')).fileCount, 2);
    await db.customStatement('''INSERT INTO history_entries
      (gid, token, title, thumb_url, last_read_at)
      VALUES (42, 'abc', 'Test', '', 100)''');
    expect(repo.cachedReaderIndex(42, 'abc'), isNotNull);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    dio = client(adapter, database: db);
    repo = GalleryRepository(dio);
    ReaderIndexCache.shared.clear();
    for (final ex in [false, true]) {
      AppConstants.useExHentai = ex;
      expect((await repo.fetchGalleryDetail(42, 'abc')).fileCount, 2);
      await dio.get('${AppConstants.baseUrl}/s/aaa/42-1');
      expect(adapter.requests.last.headers['cookie'], contains('nw=1'));
    }
    for (final url in [
      'https://exhentai.org/g/43/abc/',
      'https://exhentai.org/g/42/def/',
      'https://exhentai.org/uconfig.php',
      'https://example.test/g/42/abc/',
    ]) {
      await dio.get(url);
      expect('${adapter.requests.last.headers['cookie']}',
          isNot(contains('nw=1')));
    }
    await db.acceptGalleryWarning(43, 'def');
    await HistoryRepository(db).deleteHistory(42);
    expect(await db.getHistoryEntry(42), isNull);
    expect(repo.cachedReaderIndex(42, 'abc'), isNull);
    expect(await db.hasAcceptedGalleryWarning(43), isTrue);
    await expectLater(repo.fetchReaderIndexPage(42, 'abc'),
        throwsA(isA<GalleryContentWarning>()));
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect(await db.hasAcceptedGalleryWarning(42), isFalse);
  });

  test('clear history also clears confirmations made before a failed visit',
      () async {
    await db.acceptGalleryWarning(42, 'abc');
    await db.acceptGalleryWarning(43, 'def');
    await HistoryRepository(db).clearAllHistory();
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect(await db.hasAcceptedGalleryWarning(42), isFalse);
    expect(await db.hasAcceptedGalleryWarning(43), isFalse);
  });

  test('failed history deletion rolls back confirmation deletion', () async {
    await db.customStatement('''INSERT INTO history_entries
      (gid, token, title, thumb_url, last_read_at)
      VALUES (42, 'abc', 'Test', '', 100)''');
    await db.acceptGalleryWarning(42, 'abc');
    await db.customStatement('''CREATE TRIGGER fail_delete BEFORE DELETE ON
      history_entries BEGIN SELECT RAISE(ABORT, 'test failure'); END''');
    await expectLater(db.deleteHistory(42), throwsException);
    expect(await db.hasAcceptedGalleryWarning(42), isTrue);
    expect(await db.getHistoryEntry(42), isNotNull);
  });
}
