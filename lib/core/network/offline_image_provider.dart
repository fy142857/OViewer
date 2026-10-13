import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../storage/database.dart';
import '../storage/offline_files.dart';
import '../../models/reader_page_resource.dart';

/// A local-only image source, including animated images and export handles.
class OfflineImageProvider extends ImageProvider<OfflineImageProvider> {
  final OfflineFiles files;
  final OfflinePage page;
  final int attempt;
  final Object? session;
  final ValueChanged<ReaderPageResource>? onResource;
  const OfflineImageProvider(this.files, this.page,
      {this.attempt = 0, this.onResource, this.session});
  @override
  Future<OfflineImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          OfflineImageProvider key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
          codec: _load(decode),
          scale: 1,
          debugLabel: 'offline:${page.bookId}:${page.pageIndex}');
  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      final bytes =
          await files.read(page.relativePath!, page.bytes, page.sha256!);
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await decode(buffer);
      onResource?.call(ReaderPageResource(
          () => files.read(page.relativePath!, page.bytes, page.sha256!),
          fallback: bytes));
      return codec;
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is OfflineImageProvider &&
      identical(files, other.files) &&
      page.bookId == other.page.bookId &&
      page.pageIndex == other.page.pageIndex &&
      page.sha256 == other.page.sha256 &&
      page.relativePath == other.page.relativePath &&
      attempt == other.attempt &&
      (onResource == null) == (other.onResource == null) &&
      identical(session, other.session);
  @override
  int get hashCode => Object.hash(files, page.bookId, page.pageIndex,
      page.sha256, page.relativePath, attempt, session, onResource == null);
}
