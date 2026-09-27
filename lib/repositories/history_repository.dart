import 'package:drift/drift.dart';
import '../core/storage/database.dart';
import '../core/storage/reader_index_cache.dart';
import '../models/gallery_preview.dart';
import '../models/reading_progress.dart';

class HistoryRepository {
  final AppDatabase _db;

  HistoryRepository(this._db);

  /// Get all browsing history
  Future<List<HistoryEntry>> getAllHistory() => _db.getAllHistory();

  /// Record a gallery visit
  Future<void> recordVisit(GalleryPreview gallery) =>
      _db.upsertHistory(HistoryEntriesCompanion(
        gid: Value(gallery.gid),
        token: Value(gallery.token),
        title: Value(gallery.title),
        thumbUrl: Value(gallery.thumbUrl),
        category: Value(gallery.category),
        rating: Value(gallery.rating),
        fileCount: Value(gallery.fileCount),
        lastReadAt: Value(DateTime.now()),
      ));

  /// Update reading progress (only updates existing record)
  Future<void> updateProgress(int gid, int page, int totalPages) =>
      _db.updateHistoryEntry(
        gid,
        HistoryEntriesCompanion(
          lastReadPage: Value(page),
          totalPages: Value(totalPages),
          lastReadAt: Value(DateTime.now()),
        ),
      );

  /// Get reading progress for a gallery
  Future<ReadingProgress?> getProgress(int gid) async {
    final entry = await _db.getHistoryEntry(gid);
    if (entry == null) return null;
    return ReadingProgress(
      gid: entry.gid,
      lastReadPage: entry.lastReadPage,
      totalPages: entry.totalPages,
      lastReadAt: entry.lastReadAt,
    );
  }

  /// Delete a history entry
  Future<void> deleteHistory(int gid) async {
    await _db.deleteHistory(gid);
    ReaderIndexCache.shared.removeGallery(gid);
  }

  /// Clear all history
  Future<void> clearAllHistory() async {
    await _db.clearAllHistory();
    ReaderIndexCache.shared.clear();
  }
}
