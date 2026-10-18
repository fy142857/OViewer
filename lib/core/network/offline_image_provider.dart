import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../storage/database.dart';
import '../storage/offline_files.dart';
import '../storage/offline_entry_read.dart';
import '../../models/reader_page_resource.dart';
import '../../models/offline_book.dart';

/// A local-only image source, including animated images and export handles.
class OfflineImageProvider extends ImageProvider<OfflineImageProvider> {
  final OfflineFiles files;
  final OfflinePage page;
  final int attempt;
  final Object? session;
  final ValueChanged<ReaderPageResource>? onResource;
  final ValueChanged<String>? onPhase;
  final VoidCallback? onImageReady;
  final Future<void> Function()? beforeLoad;
  final OfflineEntryRead? prepared;
  final bool Function()? isCurrent;
  final VoidCallback? onLoadError;
  const OfflineImageProvider(this.files, this.page,
      {this.attempt = 0,
      this.onResource,
      this.session,
      this.onPhase,
      this.onImageReady,
      this.beforeLoad,
      this.prepared,
      this.isCurrent,
      this.onLoadError});
  @override
  Future<OfflineImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          OfflineImageProvider key, ImageDecoderCallback decode) =>
      _OfflineCompleter(
          onImageReady: onImageReady,
          onLoadError: onLoadError,
          codec: _load(decode),
          scale: 1,
          debugLabel: 'offline:${page.bookId}:${page.pageIndex}');
  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      await beforeLoad?.call();
      if (isCurrent?.call() == false) throw const OfflineFailure('cancelled');
      onPhase?.call('file_start');
      final bytes = await (prepared != null && identical(prepared!.files, files)
          ? prepared!.take(page)
          : files.read(page.relativePath!, page.bytes, page.sha256!));
      if (isCurrent?.call() == false) throw const OfflineFailure('cancelled');
      onPhase?.call('verified');
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await decode(buffer);
      if (isCurrent?.call() == false) {
        codec.dispose();
        throw const OfflineFailure('cancelled');
      }
      onPhase?.call('codec_ready');
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

class _OfflineCompleter extends MultiFrameImageStreamCompleter {
  final VoidCallback? onImageReady;
  final VoidCallback? onLoadError;
  bool _reported = false;
  _OfflineCompleter(
      {required super.codec,
      required super.scale,
      super.debugLabel,
      this.onImageReady,
      this.onLoadError});
  @override
  void reportError(
      {DiagnosticsNode? context,
      required Object exception,
      StackTrace? stack,
      InformationCollector? informationCollector,
      bool silent = false}) {
    if (!_reported) {
      _reported = true;
      onLoadError?.call();
    }
    super.reportError(
        context: context,
        exception: exception,
        stack: stack,
        informationCollector: informationCollector,
        silent: silent);
  }

  @override
  void setImage(ImageInfo image) {
    super.setImage(image);
    if (!_reported) {
      _reported = true;
      onImageReady?.call();
    }
  }
}
