import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/parser/gallery_detail_parser.dart';
import '../core/storage/database.dart';
import '../core/storage/offline_files.dart';
import '../models/gallery_source.dart';
import '../models/offline_book.dart';

class OfflineRepository {
  final AppDatabase db;
  final OfflineFiles files;
  final Future<Directory> Function() legacyRoot;
  final _changes = StreamController<void>.broadcast();
  Future<void> _tail = Future.value();
  Future<void>? _initializing;
  OfflineRepository(this.db, this.files,
      {Future<Directory> Function()? legacyRoot})
      : legacyRoot = legacyRoot ??
            (() async => Directory(p.join(
                (await getApplicationDocumentsDirectory()).path, 'downloads')));
  Stream<void> get changes => _changes.stream;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final future = _tail.then((_) => operation());
    _tail = future.then<void>((_) {
      if (!_changes.isClosed) _changes.add(null);
    }, onError: (Object _, StackTrace __) {});
    return future;
  }

  Future<void> initialize() => _initializing ??= _serial(() async {
        await files.cleanPartials();
        for (final old in await db.getAllDownloads()) {
          final id = sha256
              .convert(utf8.encode('legacy:${old.gid}:${old.token}'))
              .toString();
          await db.into(db.offlineGalleries).insert(
              OfflineGalleriesCompanion.insert(
                  id: id,
                  gid: old.gid,
                  token: old.token,
                  title: old.title,
                  totalPages: old.totalPages,
                  createdAt: old.createdAt,
                  status: const Value('sourceRequired'),
                  legacyGid: Value(old.gid)),
              mode: InsertMode.insertOrIgnore);
        }
        for (final record in await db.select(db.offlineGalleries).get()) {
          if (record.status == 'sourceRequired' || record.status == 'deleting')
            continue;
          var damaged = false;
          for (final page in await pages(record.id)) {
            if (page.status == 'completed' && !await valid(page)) {
              await _invalidate(record.id, page.pageIndex, 'missing_file');
              damaged = true;
            }
          }
          final complete = record.status == 'completed' &&
              !damaged &&
              (await pages(record.id))
                      .where((p) => p.status == 'completed')
                      .length ==
                  record.totalPages;
          if (!complete) {
            await _status(record.id, OfflineStatus.paused,
                damaged ? 'missing_file' : 'interrupted');
          }
        }
        // Only this version writes the offline tree. Preserve referenced files,
        // discard complete files left by a crash between rename and registration.
        final referenced = (await db.select(db.offlinePages).get())
            .map((v) => v.relativePath)
            .whereType<String>()
            .toSet();
        final root = await files.root;
        await for (final entity
            in root.list(recursive: true, followLinks: false)) {
          if (entity is File &&
              !referenced.contains(p
                  .relative(entity.path, from: root.path)
                  .replaceAll('\\', '/'))) {
            await entity.delete();
          }
        }
      }).catchError((Object e, StackTrace st) {
        _initializing = null;
        Error.throwWithStackTrace(e, st);
      });

  Future<List<OfflinePage>> pages(String id) => (db.select(db.offlinePages)
        ..where((t) => t.bookId.equals(id))
        ..orderBy([(t) => OrderingTerm.asc(t.pageIndex)]))
      .get();
  Future<OfflineBook?> get(String id) async {
    final record = await (db.select(db.offlineGalleries)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return record == null ? null : OfflineBook(record, await pages(id));
  }

  Future<List<OfflineBook>> all() async {
    final records = await (db.select(db.offlineGalleries)
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id)
          ]))
        .get();
    return Future.wait(
        records.map((r) async => OfflineBook(r, await pages(r.id))));
  }

  Future<List<OfflineBook>> matching(int gid, String token,
      {GallerySource? source}) async {
    final query = db.select(db.offlineGalleries)
      ..where((t) =>
          t.gid.equals(gid) &
          t.token.equals(token) &
          t.everCompleted.equals(true) &
          t.indexReady.equals(true) &
          t.status.equals('deleting').not());
    if (source != null) query.where((t) => t.source.equals(source.name));
    return Future.wait((await query.get())
        .map((r) async => OfflineBook(r, await pages(r.id))));
  }

  Future<OfflineBook> create(OfflineKey key, String title, int totalPages) =>
      _serial(() async {
        if (key.gid <= 0 || key.token.isEmpty || totalPages <= 0)
          throw const OfflineFailure('invalid_index');
        await db.into(db.offlineGalleries).insert(
            OfflineGalleriesCompanion.insert(
                id: key.id,
                source: Value(key.source.name),
                gid: key.gid,
                token: key.token,
                title: title,
                totalPages: totalPages,
                createdAt: DateTime.now(),
                status: const Value('paused')),
            mode: InsertMode.insertOrIgnore);
        return (await get(key.id))!;
      });

  Future<void> _status(String id, OfflineStatus status, String? reason) =>
      (db.update(db.offlineGalleries)..where((t) => t.id.equals(id))).write(
          OfflineGalleriesCompanion(
              everCompleted: status == OfflineStatus.completed
                  ? const Value(true)
                  : const Value.absent(),
              status: Value(status.name),
              reason: Value(reason)));
  Future<void> setStatus(String id, OfflineStatus status, {String? reason}) =>
      _serial(() => _status(id, status, reason));

  /// The complete index must be known before any page can be declared complete.
  Future<void> putIndex(String id, int total, List<ThumbnailInfo> thumbnails,
          {required bool Function() current}) =>
      _serial(() async {
        if (!current()) throw const OfflineFailure('cancelled');
        final indexed = <int, ThumbnailInfo>{};
        for (final thumb in thumbnails) {
          final previous = indexed[thumb.pageIndex];
          if (thumb.pageIndex < 0 ||
              thumb.pageIndex >= total ||
              thumb.pageToken.isEmpty ||
              (previous != null && previous.pageToken != thumb.pageToken)) {
            throw const OfflineFailure('invalid_index');
          }
          indexed[thumb.pageIndex] = thumb;
        }
        if (total <= 0 || indexed.length != total)
          throw const OfflineFailure('invalid_index');
        final oldPages = {
          for (final page in await pages(id)) page.pageIndex: page
        };
        final obsolete = <String>[];
        await db.transaction(() async {
          for (final old in oldPages.values) {
            if (indexed[old.pageIndex]?.pageToken != old.pageToken &&
                old.relativePath != null) {
              obsolete.add(old.relativePath!);
            }
          }
          await (db.delete(db.offlinePages)..where((t) => t.bookId.equals(id)))
              .go();
          for (final entry in indexed.entries) {
            final old = oldPages[entry.key];
            final unchanged =
                old != null && old.pageToken == entry.value.pageToken;
            await db.into(db.offlinePages).insert(unchanged
                ? old
                : OfflinePagesCompanion.insert(
                    bookId: id,
                    pageIndex: entry.key,
                    pageToken: entry.value.pageToken));
          }
          await (db.update(db.offlineGalleries)..where((t) => t.id.equals(id)))
              .write(OfflineGalleriesCompanion(
                  totalPages: Value(total), indexReady: const Value(true)));
        });
        for (final path in obsolete) {
          await files.remove(path);
        }
      });

  Future<bool> valid(OfflinePage page) async =>
      page.relativePath != null &&
      page.sha256 != null &&
      page.bytes > 0 &&
      await files.verify(page.relativePath!, page.bytes, page.sha256!);

  Future<void> savePage(String id, int index, OfflineFileInfo file,
          {required bool Function() current}) =>
      _serial(() async {
        if (!current()) {
          await files.remove(file.relativePath);
          throw const OfflineFailure('cancelled');
        }
        final page = await (db.select(db.offlinePages)
              ..where((t) => t.bookId.equals(id) & t.pageIndex.equals(index)))
            .getSingleOrNull();
        if (page == null) {
          await files.remove(file.relativePath);
          throw const OfflineFailure('cancelled');
        }
        await (db.update(db.offlinePages)
              ..where((t) => t.bookId.equals(id) & t.pageIndex.equals(index)))
            .write(OfflinePagesCompanion(
                relativePath: Value(file.relativePath),
                format: Value(file.format),
                bytes: Value(file.bytes),
                sha256: Value(file.digest),
                status: const Value('completed'),
                error: const Value(null)));
        if (page.relativePath != null && page.relativePath != file.relativePath)
          await files.remove(page.relativePath!);
      });

  Future<void> _invalidate(String id, int index, String reason) =>
      (db.update(db.offlinePages)
            ..where((t) => t.bookId.equals(id) & t.pageIndex.equals(index)))
          .write(OfflinePagesCompanion(
              status: const Value('failed'), error: Value(reason)));
  Future<void> failPage(String id, int index, String reason) =>
      _serial(() => _invalidate(id, index, reason));
  Future<void> saveProgress(String id, int index) => _serial(() async {
        await (db.update(db.offlineGalleries)..where((t) => t.id.equals(id)))
            .write(OfflineGalleriesCompanion(lastReadPage: Value(index)));
      });

  Future<void> delete(String id) => _serial(() async {
        final book = await get(id);
        if (book == null) return;
        await _status(id, OfflineStatus.deleting, null);
        try {
          await files.removeBook(id);
          if (book.record.legacyGid != null) {
            final root = await legacyRoot();
            final folder =
                Directory(p.join(root.path, book.record.legacyGid.toString()));
            if (!p.isWithin(p.absolute(root.path), p.absolute(folder.path)))
              throw const OfflineFailure('invalid_path');
            if (await folder.exists()) await folder.delete(recursive: true);
          }
          await db.transaction(() async {
            await (db.delete(db.offlinePages)
                  ..where((t) => t.bookId.equals(id)))
                .go();
            await (db.delete(db.offlineGalleries)
                  ..where((t) => t.id.equals(id)))
                .go();
            if (book.record.legacyGid != null)
              await db.deleteDownload(book.record.legacyGid!);
          });
        } catch (_) {
          await _status(id, OfflineStatus.deleting, 'delete_failed');
          if (!_changes.isClosed) _changes.add(null);
          rethrow;
        }
      });

  /// Call only after the user-selected origin and its complete index are verified.
  Future<OfflineBook> stageLegacy(String oldId, GallerySource source) async {
    final old = await get(oldId);
    if (old == null || old.source != null)
      throw const OfflineFailure('source_required');
    final book = await create(
        OfflineKey(source, old.record.gid, old.record.token),
        old.record.title,
        old.record.totalPages);
    await _serial(() async {
      await (db.update(db.offlineGalleries)..where((t) => t.id.equals(book.id)))
          .write(OfflineGalleriesCompanion(legacyGid: Value(old.record.gid)));
    });
    return (await get(book.id))!;
  }

  /// Call only after the user-selected origin and its complete index are verified.
  Future<OfflineBook> importLegacy(OfflineBook old, OfflineKey key, int total,
      List<ThumbnailInfo> thumbnails,
      {required bool Function() current}) async {
    final fresh = await create(key, old.record.title, total);
    if (fresh.complete) return fresh;
    await putIndex(fresh.id, total, thumbnails, current: current);
    final directory = await legacyRoot();
    for (final page in await pages(fresh.id)) {
      if (!current()) throw const OfflineFailure('cancelled');
      if (page.status == 'completed' && await valid(page)) continue;
      final legacy = File(p.join(directory.path, old.record.gid.toString(),
          '${page.pageIndex.toString().padLeft(4, '0')}.jpg'));
      if (!await legacy.exists()) continue;
      try {
        final info = await files.write(
            fresh.id, page.pageIndex, legacy.openRead(),
            current: current, expectedBytes: await legacy.length());
        await savePage(fresh.id, page.pageIndex, info, current: current);
      } on OfflineFailure catch (error) {
        if (error.code == 'cancelled') rethrow;
      }
    }
    if (!current()) throw const OfflineFailure('cancelled');
    await _serial(() async {
      if (!current()) throw const OfflineFailure('cancelled');
      await db.transaction(() async {
        await (db.delete(db.offlineGalleries)
              ..where((t) => t.id.equals(old.id)))
            .go();
        await db.deleteDownload(old.record.gid);
      });
    });
    // Old files remain owned by the new task's legacyGid until manual deletion.
    return (await get(fresh.id))!;
  }

  Future<int> size() async {
    var bytes = await files.size();
    final legacy = await legacyRoot();
    if (await legacy.exists()) {
      await for (final entity
          in legacy.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            bytes += await entity.length();
          } on FileSystemException {
            if (await entity.exists()) rethrow;
          }
        }
      }
    }
    return bytes;
  }

  Future<void> dispose() async {
    await _tail;
    await _changes.close();
  }
}
