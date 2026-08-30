import 'package:drift/drift.dart';
import 'database_connection_io.dart';

part 'database.g.dart';

// --- Table Definitions ---

class HistoryEntries extends Table {
  IntColumn get gid => integer()();
  TextColumn get token => text()();
  TextColumn get title => text()();
  TextColumn get thumbUrl => text()();
  TextColumn get category => text().withDefault(const Constant('Misc'))();
  RealColumn get rating => real().withDefault(const Constant(0.0))();
  IntColumn get fileCount => integer().withDefault(const Constant(0))();
  IntColumn get lastReadPage => integer().withDefault(const Constant(0))();
  IntColumn get totalPages => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastReadAt => dateTime()();

  @override
  Set<Column> get primaryKey => {gid};
}

class LocalFavorites extends Table {
  IntColumn get gid => integer()();
  TextColumn get token => text()();
  TextColumn get title => text()();
  TextColumn get thumbUrl => text()();
  TextColumn get category => text().withDefault(const Constant('Misc'))();
  RealColumn get rating => real().withDefault(const Constant(0.0))();
  IntColumn get fileCount => integer().withDefault(const Constant(0))();
  IntColumn get slot => integer().withDefault(const Constant(0))();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {gid};
}

class DownloadTasks extends Table {
  IntColumn get gid => integer()();
  TextColumn get token => text()();
  TextColumn get title => text()();
  TextColumn get thumbUrl => text()();
  IntColumn get totalPages => integer()();
  IntColumn get downloadedPages => integer().withDefault(const Constant(0))();
  IntColumn get status => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {gid};
}

// --- Database ---

@DriftDatabase(tables: [HistoryEntries, LocalFavorites, DownloadTasks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(openConnection());

  @override
  int get schemaVersion => 1;

  // History operations
  Future<List<HistoryEntry>> getAllHistory() => (select(historyEntries)
        ..orderBy([(t) => OrderingTerm.desc(t.lastReadAt)]))
      .get();

  Future<HistoryEntry?> getHistoryEntry(int gid) =>
      (select(historyEntries)..where((t) => t.gid.equals(gid)))
          .getSingleOrNull();

  Future<void> upsertHistory(HistoryEntriesCompanion entry) =>
      into(historyEntries).insertOnConflictUpdate(entry);

  /// Update only specific columns of an existing history entry
  Future<void> updateHistoryEntry(int gid, HistoryEntriesCompanion entry) =>
      (update(historyEntries)..where((t) => t.gid.equals(gid))).write(entry);

  Future<void> deleteHistory(int gid) =>
      (delete(historyEntries)..where((t) => t.gid.equals(gid))).go();

  Future<void> clearAllHistory() => delete(historyEntries).go();

  // Local favorites operations
  Future<List<LocalFavorite>> getAllLocalFavorites() =>
      (select(localFavorites)..orderBy([(t) => OrderingTerm.desc(t.addedAt)]))
          .get();

  Future<LocalFavorite?> getLocalFavorite(int gid) =>
      (select(localFavorites)..where((t) => t.gid.equals(gid)))
          .getSingleOrNull();

  Future<void> addLocalFavorite(LocalFavoritesCompanion fav) =>
      into(localFavorites).insertOnConflictUpdate(fav);

  Future<void> removeLocalFavorite(int gid) =>
      (delete(localFavorites)..where((t) => t.gid.equals(gid))).go();

  Future<void> clearLocalFavorites() => delete(localFavorites).go();

  Future<bool> isLocalFavorited(int gid) async {
    final result = await getLocalFavorite(gid);
    return result != null;
  }

  Future<Set<int>> getLocalFavoriteGids() async {
    final rows = await (selectOnly(localFavorites)
          ..addColumns([localFavorites.gid]))
        .map((row) => row.read(localFavorites.gid)!)
        .get();
    return rows.toSet();
  }

  // Download operations
  Future<List<DownloadTask>> getAllDownloads() =>
      (select(downloadTasks)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<void> upsertDownload(DownloadTasksCompanion task) =>
      into(downloadTasks).insertOnConflictUpdate(task);

  Future<void> deleteDownload(int gid) =>
      (delete(downloadTasks)..where((t) => t.gid.equals(gid))).go();

  Future<void> updateDownloadProgress(int gid, int downloaded) =>
      (update(downloadTasks)..where((t) => t.gid.equals(gid))).write(
        DownloadTasksCompanion(downloadedPages: Value(downloaded)),
      );

  Future<void> updateDownloadStatus(int gid, int status) =>
      (update(downloadTasks)..where((t) => t.gid.equals(gid))).write(
        DownloadTasksCompanion(status: Value(status)),
      );
}
