import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../constants/app_constants.dart';
import 'reader_request_controller.dart';
import 'reader_image_cache_key.dart';
import 'eh_image_cache_manager.dart';
import '../../models/reader_page_resource.dart';

/// The shared disk cache contains completed images, never in-flight requests.
class ReaderImageCache {
  final BaseCacheManager _cache;
  final Future<Iterable<String>> Function(String)? legacyKeys;

  const ReaderImageCache(this._cache, {this.legacyKeys});

  Future<Uint8List?> read(String url) async {
    final key = readerImageCacheKey(url);
    Future<Uint8List?> readKey(String candidate) async {
      if (_cache is EhImageCacheManager) {
        return (_cache as EhImageCacheManager).readBytes(candidate);
      }
      final entry = await _cache.getFileFromCache(candidate);
      if (entry == null || !entry.validTill.isAfter(DateTime.now())) {
        return null;
      }
      return entry.file.readAsBytes();
    }

    final cached = await readKey(key);
    if (cached != null || key == url) {
      if (cached != null && kDebugMode) {
        debugPrint('[reader-cache] hit=content');
      }
      return cached;
    }
    final original = await readKey(url);
    if (original != null) {
      if (kDebugMode) debugPrint('[reader-cache] hit=original-url');
      return original;
    }
    // Old installations stored completed files under the full source URL.
    // Reuse those files across /h -> /om failover without deleting the cache.
    for (final candidate in await legacyKeys?.call(key) ?? <String>[]) {
      if (candidate == url || candidate == key) continue;
      final bytes = await readKey(candidate);
      if (bytes != null) {
        if (kDebugMode) debugPrint('[reader-cache] hit=legacy-alternate');
        return bytes;
      }
    }
    return null;
  }

  Future<void> write(String url, Uint8List bytes) async {
    await _cache.putFile(url, bytes,
        key: readerImageCacheKey(url),
        maxAge: const Duration(days: AppConstants.maxCacheAgeDays));
  }

  Future<void> remove(String url) async {
    final key = readerImageCacheKey(url);
    final keys = <String>{key, url};
    if (key != url) keys.addAll(await legacyKeys?.call(key) ?? <String>[]);
    for (final candidate in keys) {
      await _cache.removeFile(candidate);
    }
  }
}

/// Successful bytes are shared across visits. Active image streams stay scoped
/// to their reader session so a new visit never inherits a cancelled download.
class ReaderImageProvider extends ImageProvider<ReaderImageProvider> {
  final String url;
  final ReaderRequestController requests;
  final FileService fileService;
  final ReaderImageCache cache;
  final int attempt;
  final void Function()? onImageReady;
  final Duration idleTimeout;
  final ValueChanged<ReaderPageResource>? onResourceReady;

  const ReaderImageProvider(
    this.url, {
    required this.requests,
    required this.fileService,
    required this.cache,
    this.attempt = 0,
    this.onImageReady,
    this.idleTimeout = const Duration(seconds: 30),
    this.onResourceReady,
  });

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      ReaderImageProvider key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    requests.onCancel(() => PaintingBinding.instance.imageCache.evict(key));
    ReaderPageResource? resource;
    final completer = MultiFrameImageStreamCompleter(
      codec: _load(decode, chunks, (value) {
        resource = value;
        onResourceReady?.call(value);
      }),
      chunkEvents: chunks.stream,
      scale: 1,
      debugLabel: url,
    );
    requests.onCancel(() => resource?.releaseMemory());
    completer.addOnLastListenerRemovedCallback(() => resource?.releaseMemory());
    return completer;
  }

  void _ensureActive() {
    if (requests.isCancelled) {
      throw StateError('Reader image request cancelled');
    }
  }

  Future<T> _waitFor<T>(Future<T> work, {void Function(T)? disposeLate}) {
    var timedOut = false;
    return work.then((value) {
      if (timedOut) disposeLate?.call(value);
      return value;
    }).timeout(idleTimeout, onTimeout: () {
      timedOut = true;
      throw TimeoutException('Reader image loading stalled', idleTimeout);
    });
  }

  Future<ui.Codec> _load(
      ImageDecoderCallback decode,
      StreamController<ImageChunkEvent> chunks,
      ValueChanged<ReaderPageResource> resourceReady) async {
    try {
      _ensureActive();
      // An explicit retry bypasses cached bytes, including a corrupt entry.
      // Ordinary reentry always tries the shared completed-image cache first.
      if (attempt == 0) {
        try {
          final cached = await _waitFor(cache.read(url));
          _ensureActive();
          if (cached != null) {
            final codec = await _decode(cached, decode);
            resourceReady(
                ReaderPageResource(() => cache.read(url), fallback: cached));
            onImageReady?.call();
            return codec;
          }
        } on TimeoutException {
          _ensureActive();
          // Slow cache IO does not invalidate a previously successful image.
        } catch (_) {
          _ensureActive();
          // A missing or corrupt cache entry must not block a fresh download.
          try {
            await _waitFor(cache.remove(url));
          } catch (_) {}
        }
      } else {
        try {
          await _waitFor(cache.remove(url));
        } catch (_) {}
      }
      _ensureActive();
      final response =
          await _waitFor(fileService.get(url), disposeLate: (response) {
        // A timed-out request may still return headers. Drop its body instead
        // of decoding/caching it or letting it replace a later retry.
        unawaited(
            response.content.listen(null, onError: (Object _) {}).cancel());
      });
      _ensureActive();
      if (response.statusCode != 200) {
        await response.content.listen(null).cancel();
        throw NetworkImageLoadException(
            statusCode: response.statusCode, uri: Uri.parse(url));
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.content.timeout(idleTimeout)) {
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
        await _waitFor(cache.write(url, completedBytes));
      } catch (_) {
        // A cache write failure should not turn a loaded image into an error.
      }
      if (requests.isCancelled) {
        codec.dispose();
        _ensureActive();
      }
      resourceReady(
          ReaderPageResource(() => cache.read(url), fallback: completedBytes));
      onImageReady?.call();
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
    final buffer = await _waitFor(ui.ImmutableBuffer.fromUint8List(bytes),
        disposeLate: (buffer) => buffer.dispose());
    if (requests.isCancelled) buffer.dispose();
    _ensureActive();
    final codec =
        await _waitFor(decode(buffer), disposeLate: (codec) => codec.dispose());
    try {
      _ensureActive();
      // Creating a codec only parses the image header. Validate the first
      // actual frame before considering these bytes successfully loaded.
      final firstFrame = await _waitFor(codec.getNextFrame(),
          disposeLate: (frame) => frame.image.dispose());
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
      other.attempt == attempt &&
      other.idleTimeout == idleTimeout;

  @override
  int get hashCode => Object.hash(url, requests, attempt, idleTimeout);
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
