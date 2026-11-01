import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/storage/database.dart';
import 'gallery_source.dart';
import 'download_range.dart';

enum OfflineStatus {
  queued,
  preparing,
  downloading,
  paused,
  completed,
  failed,
  deleting,
  sourceRequired;

  static OfflineStatus parse(String value) =>
      values.firstWhere((v) => v.name == value, orElse: () => paused);
}

class OfflineKey {
  final GallerySource source;
  final int gid;
  final String token;
  const OfflineKey(this.source, this.gid, this.token);
  String get id =>
      sha256.convert(utf8.encode('${source.name}:$gid:$token')).toString();
}

class OfflineBook {
  final OfflineGallery record;
  final List<OfflinePage> pages;
  OfflineBook(this.record, Iterable<OfflinePage> pages)
      : pages = List.unmodifiable(pages);
  String get id => record.id;
  GallerySource? get source => GallerySource.parse(record.source);
  OfflineKey? get key =>
      source == null ? null : OfflineKey(source!, record.gid, record.token);
  OfflineStatus get status => OfflineStatus.parse(record.status);
  int get completedPages => pages.where((p) => p.status == 'completed').length;
  late final DownloadRange range =
      DownloadRange.fromStorage(record.downloadRange);
  int get targetPages => range.count(record.totalPages);
  int get completedTargetPages => pages
      .where((p) => range.contains(p.pageIndex) && p.status == 'completed')
      .length;
  bool get targetComplete =>
      hasTargetIndex &&
      range.validFor(record.totalPages) &&
      completedTargetPages == targetPages;
  bool get allPagesComplete =>
      hasCompleteIndex && completedPages == record.totalPages;
  int get bytes => pages.fold(0, (n, p) => n + p.bytes);
  bool get hasIndexMetadata =>
      key?.id == id && record.indexReady && record.totalPages > 0;
  late final Set<int> indexedPages = Set.unmodifiable({
    for (final page in pages)
      if (page.bookId == id &&
          page.pageIndex >= 0 &&
          page.pageIndex < record.totalPages &&
          page.pageToken.isNotEmpty &&
          page.indexStale != true)
        page.pageIndex,
  });
  bool get hasTargetIndex =>
      hasIndexMetadata &&
      range.validFor(record.totalPages) &&
      indexedPages.where(range.contains).length == targetPages;
  bool hasIndexPart(int part, int size) {
    final start = part * size;
    final end = ((part + 1) * size).clamp(0, record.totalPages);
    return hasIndexMetadata &&
        size > 0 &&
        part >= 0 &&
        start < end &&
        Iterable.generate(end - start, (i) => start + i)
            .every(indexedPages.contains);
  }

  bool get hasCompleteIndex =>
      key?.id == id &&
      record.indexReady &&
      record.totalPages > 0 &&
      pages.length == record.totalPages &&
      pages.asMap().entries.every((entry) =>
          entry.value.bookId == id &&
          entry.value.pageIndex == entry.key &&
          entry.value.indexStale != true &&
          entry.value.pageToken.isNotEmpty);
  bool get complete => status == OfflineStatus.completed && targetComplete;
}

class OfflineFailure implements Exception {
  final String code;
  const OfflineFailure(this.code);
  @override
  String toString() => 'OfflineFailure($code)';
}
