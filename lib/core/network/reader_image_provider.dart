import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../constants/app_constants.dart';
import 'reader_request_controller.dart';

/// The shared disk cache contains completed images, never in-flight requests.
class ReaderImageCache {
  final BaseCacheManager _cache;

  const ReaderImageCache(this._cache);

  Future<Uint8List?> read(String url) async {
    final entry = await _cache.getFileFromCache(url);
    if (entry == null || !entry.validTill.isAfter(DateTime.now())) return null;
    return entry.file.readAsBytes();
  }

  Future<void> write(String url, Uint8List bytes) async {
    await _cache.putFile(url, bytes,
        maxAge: const Duration(days: AppConstants.maxCacheAgeDays));
  }

  Future<void> remove(String url) => _cache.removeFile(url);
}

/// Successful bytes are shared across visits. Active image streams stay scoped
/// to their reader session so a new visit never inherits a cancelled download.
class ReaderImageProvider extends ImageProvider<ReaderImageProvider> {
  final String url;
  final ReaderRequestController requests;
  final FileService fileService;
  final ReaderImageCache cache;
  final int attempt;

  const ReaderImageProvider(
    this.url, {
    required this.requests,
    required this.fileService,
    required this.cache,
    this.attempt = 0,
  });

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      ReaderImageProvider key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    requests.onCancel(() => PaintingBinding.instance.imageCache.evict(key));
    return MultiFrameImageStreamCompleter(
      codec: _load(decode, chunks),
      chunkEvents: chunks.stream,
      scale: 1,
      debugLabel: url,
    );
  }

  void _ensureActive() {
    if (requests.isCancelled) {
      throw StateError('Reader image request cancelled');
    }
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode,
      StreamController<ImageChunkEvent> chunks) async {
    try {
      _ensureActive();
      // An explicit retry bypasses cached bytes, including a corrupt entry.
      // Ordinary reentry always tries the shared completed-image cache first.
      if (attempt == 0) {
        try {
          final cached = await cache.read(url);
          _ensureActive();
          if (cached != null) return await _decode(cached, decode);
        } catch (_) {
          _ensureActive();
          // A missing or corrupt cache entry must not block a fresh download.
          try {
            await cache.remove(url);
          } catch (_) {}
        }
      } else {
        try {
          await cache.remove(url);
        } catch (_) {}
      }
      _ensureActive();
      final response = await fileService.get(url);
      _ensureActive();
      if (response.statusCode != 200) {
        await response.content.listen(null).cancel();
        throw NetworkImageLoadException(
            statusCode: response.statusCode, uri: Uri.parse(url));
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.content) {
        _ensureActive();
        bytes.add(chunk);
        chunks.add(ImageChunkEvent(
          cumulativeBytesLoaded: bytes.length,
          expectedTotalBytes: response.contentLength,
        ));
      }
      _ensureActive();
      if (bytes.isEmpty) throw StateError('Empty reader image');
      final completedBytes = bytes.takeBytes();
      final codec = await _decode(completedBytes, decode);
      // Persist only a complete, decodable image. Cancellation and HTTP/decode
      // failures never write partial or failed responses into the shared cache.
      try {
        await cache.write(url, completedBytes);
      } catch (_) {
        // A cache write failure should not turn a loaded image into an error.
      }
      if (requests.isCancelled) {
        codec.dispose();
        _ensureActive();
      }
      return codec;
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } finally {
      chunks.close();
    }
  }

  Future<ui.Codec> _decode(Uint8List bytes, ImageDecoderCallback decode) async {
    _ensureActive();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);
    try {
      _ensureActive();
      // Creating a codec only parses the image header. Validate the first
      // actual frame before considering these bytes successfully loaded.
      final firstFrame = await codec.getNextFrame();
      if (requests.isCancelled) {
        firstFrame.image.dispose();
        _ensureActive();
      }
      return _ValidatedImageCodec(codec, firstFrame);
    } catch (_) {
      codec.dispose();
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderImageProvider &&
      other.url == url &&
      identical(other.requests, requests) &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(url, requests, attempt);
}

/// Hand the validated first frame to Flutter without decoding it twice or
/// skipping the first frame of an animated image.
class _ValidatedImageCodec implements ui.Codec {
  final ui.Codec _codec;
  ui.FrameInfo? _firstFrame;

  _ValidatedImageCodec(this._codec, this._firstFrame);

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final first = _firstFrame;
    if (first == null) return _codec.getNextFrame();
    _firstFrame = null;
    return first;
  }

  @override
  void dispose() {
    _firstFrame?.image.dispose();
    _firstFrame = null;
    _codec.dispose();
  }
}
