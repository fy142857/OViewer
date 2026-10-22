import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/storage/database.dart';
import 'gallery_source.dart';

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
  int get bytes => pages.fold(0, (n, p) => n + p.bytes);
  bool get hasCompleteIndex =>
      key?.id == id &&
      record.indexReady &&
      record.totalPages > 0 &&
      pages.length == record.totalPages &&
      pages.asMap().entries.every((entry) =>
          entry.value.bookId == id &&
          entry.value.pageIndex == entry.key &&
          entry.value.pageToken.isNotEmpty);
  bool get complete =>
      status == OfflineStatus.completed &&
      record.indexReady &&
      record.totalPages > 0 &&
      completedPages == record.totalPages;
}

class OfflineFailure implements Exception {
  final String code;
  const OfflineFailure(this.code);
  @override
  String toString() => 'OfflineFailure($code)';
}
