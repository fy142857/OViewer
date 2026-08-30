import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:logger/logger.dart';
import '../core/storage/database.dart';
import '../core/network/dio_client.dart';
import '../models/download_task.dart' as model;
import 'gallery_repository.dart';

class DownloadRepository {
  static final _log = Logger();
  final DioClient _dio;
  final AppDatabase _db;
  final GalleryRepository _galleryRepo;

  DownloadRepository(this._dio, this._db, this._galleryRepo);

  /// Get download storage directory
  Future<String> get _downloadDir async {
    final dir = await getApplicationDocumentsDirectory();
    final dlDir = Directory(p.join(dir.path, 'downloads'));
    if (!await dlDir.exists()) {
      await dlDir.create(recursive: true);
    }
    return dlDir.path;
  }

  /// Get all download tasks
  Future<List<model.DownloadTask>> getAllDownloads() async {
    final entries = await _db.getAllDownloads();
    return entries
        .map((e) => model.DownloadTask(
              gid: e.gid,
              token: e.token,
              title: e.title,
              thumbUrl: e.thumbUrl,
              totalPages: e.totalPages,
              downloadedPages: e.downloadedPages,
              status: model.DownloadStatus.values[e.status],
              createdAt: e.createdAt,
            ))
        .toList();
  }

  /// Create a new download task
  Future<void> createDownload({
    required int gid,
    required String token,
    required String title,
    required String thumbUrl,
    required int totalPages,
  }) async {
    await _db.upsertDownload(DownloadTasksCompanion(
      gid: Value(gid),
      token: Value(token),
      title: Value(title),
      thumbUrl: Value(thumbUrl),
      totalPages: Value(totalPages),
      downloadedPages: const Value(0),
      status: Value(model.DownloadStatus.pending.index),
      createdAt: Value(DateTime.now()),
    ));

    // Create gallery directory
    final dir = await _downloadDir;
    final galleryDir = Directory(p.join(dir, gid.toString()));
    if (!await galleryDir.exists()) {
      await galleryDir.create(recursive: true);
    }
  }

  /// Download a single gallery image to disk
  Future<bool> downloadImage(int gid, String pageToken, int pageIndex) async {
    try {
      final image = await _galleryRepo.fetchImage(pageToken, gid, pageIndex);
      final dir = await _downloadDir;
      final filePath = p.join(
          dir, gid.toString(), '${pageIndex.toString().padLeft(4, '0')}.jpg');

      // Download file
      final response = await _dio.get(image.imageUrl);
      final file = File(filePath);
      await file.writeAsString(response);

      return true;
    } catch (e) {
      _log.w('Failed to download image $pageIndex for gallery $gid: $e');
      return false;
    }
  }

  /// Get local file path for a downloaded image
  Future<String?> getLocalImagePath(int gid, int pageIndex) async {
    final dir = await _downloadDir;
    final filePath = p.join(
        dir, gid.toString(), '${pageIndex.toString().padLeft(4, '0')}.jpg');
    final file = File(filePath);
    if (await file.exists()) return filePath;
    return null;
  }

  /// Check if gallery is fully downloaded
  Future<bool> isFullyDownloaded(int gid, int totalPages) async {
    final dir = await _downloadDir;
    final galleryDir = Directory(p.join(dir, gid.toString()));
    if (!await galleryDir.exists()) return false;
    final files = await galleryDir.list().length;
    return files >= totalPages;
  }

  /// Update download progress
  Future<void> updateProgress(int gid, int downloadedPages) =>
      _db.updateDownloadProgress(gid, downloadedPages);

  /// Update download status
  Future<void> updateStatus(int gid, model.DownloadStatus status) =>
      _db.updateDownloadStatus(gid, status.index);

  /// Delete download task and files
  Future<void> deleteDownload(int gid) async {
    await _db.deleteDownload(gid);
    // Delete local files
    final dir = await _downloadDir;
    final galleryDir = Directory(p.join(dir, gid.toString()));
    if (await galleryDir.exists()) {
      await galleryDir.delete(recursive: true);
    }
  }

  /// Get total disk usage of downloads
  Future<int> getTotalDownloadSize() async {
    final dir = await _downloadDir;
    final dlDir = Directory(dir);
    if (!await dlDir.exists()) return 0;
    var totalSize = 0;
    await for (final entity in dlDir.list(recursive: true)) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }
    return totalSize;
  }
}
