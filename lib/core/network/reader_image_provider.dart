import 'image_cache_scope.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../constants/app_constants.dart';
import 'reader_request_controller.dart';
import '../storage/reader_reentry_cache.dart';
import '../../models/gallery_image.dart';
import 'reader_image_cache_key.dart';
import 'eh_image_cache_manager.dart';
import '../../models/reader_page_resource.dart';

/// The shared disk cache contains completed images, never in-flight requests.
class ReaderImageCache {
  final BaseCacheManager _cache;
  final ImageCacheScope scope;

  DateTime? lastReadExpiry;
  ReaderImageCache(this._cache, {ImageCacheScope? scope})
      : scope = scope ?? ImageCacheScope.capture();

  String key(String url) => scope.key(readerImageCacheKey(url));

  Future<Uint8List?> read(String url) async {
    scope.ensureCurrent();
    lastReadExpiry = null;
    final cacheKey = key(url);
    if (_cache is EhImageCacheManager) {
      final manager = _cache as EhImageCacheManager;
      final bytes = await manager.readBytes(cacheKey);
      scope.ensureCurrent();
      if (bytes != null) {
        lastReadExpiry = (await manager.getFileFromCache(cacheKey))?.validTill;
      }
      scope.ensureCurrent();
      return bytes;
    }
    final entry = await _cache.getFileFromCache(cacheKey);
    scope.ensureCurrent();
    if (entry == null || !entry.validTill.isAfter(DateTime.now())) return null;
    lastReadExpiry = entry.validTill;
    final bytes = await entry.file.readAsBytes();
    scope.ensureCurrent();
    return bytes;
  }

  Future<void> write(String url, Uint8List bytes) async {
    scope.ensureCurrent();
    await _cache.putFile(url, bytes,
        key: key(url),
        maxAge: const Duration(days: AppConstants.maxCacheAgeDays));
    // The key was captured before the await; a late write never enters the
    // newly selected site's/session's namespace.
    scope.ensureCurrent();
  }

  Future<void> remove(String url) => _cache.removeFile(key(url));
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
  final ReaderReentryCache? reentry;
  final ReaderCacheTicket? ticket;
  final GalleryImage? galleryImage;
  final bool cacheOnly;
  final ImageCacheScope? imageScope;
  final VoidCallback? onCacheMiss;

  const ReaderImageProvider(
    this.url, {
    required this.requests,
    required this.fileService,
    required this.cache,
    this.attempt = 0,
    this.onImageReady,
    this.idleTimeout = const Duration(seconds: 30),
    this.onResourceReady,
    this.reentry,
    this.ticket,
    this.galleryImage,
    this.cacheOnly = false,
    this.imageScope,
    this.onCacheMiss,
  });

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
      ReaderImageProvider key, ImageDecoderCallback decode) {
    final retained = ticket == null ? null : reentry?.frame(ticket!);
    if (cacheOnly && retained != null && !_obsolete) {
      ReaderPageResource? resource;
      final completed = OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: retained.image.clone())));
      requests.onCancel(() => resource?.releaseMemory());
      // Flutter briefly adds/removes its own cache listener before attaching
      // the widget. Create the export handle after that synchronous bookkeeping.
      scheduleMicrotask(() {
        if (!_obsolete) {
          resource = ReaderPageResource(() => cache.read(url),
              fallback: retained.encoded);
          onResourceReady?.call(resource!);
          onImageReady?.call();
        }
      });
      requests.onCancel(() => PaintingBinding.instance.imageCache.evict(key));
      completed
          .addOnLastListenerRemovedCallback(() => resource?.releaseMemory());
      return completed;
    }
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

  bool get _obsolete =>
      requests.isCancelled ||
      imageScope?.isCurrent == false ||
      ticket != null && !reentry!.accepts(ticket!);

  void _ensureActive() {
    imageScope?.ensureCurrent();
    if (requests.isCancelled) {
      throw StateError('Reader image request cancelled');
    }
    if (ticket != null && !reentry!.accepts(ticket!)) {
      throw StateError('Reader image cache session expired');
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
      if (attempt == 0 || cacheOnly) {
        try {
          final cached = await _waitFor(cache.read(url));
          _ensureActive();
          if (cached != null) {
            final codec = await _decode(cached, decode);
            _retain(codec, cached,
                durable: true,
                expires: reentry == null ? null : cache.lastReadExpiry);
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
      if (cacheOnly) {
        onCacheMiss?.call();
        throw const ReaderLocalCacheMiss();
      }
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
      var durable = false;
      try {
        if (ticket == null || reentry!.accepts(ticket!)) {
          await _waitFor(cache.write(url, completedBytes));
          durable = true;
        }
      } catch (_) {
        // A cache write failure should not turn a loaded image into an error.
      }
      if (requests.isCancelled ||
          ticket != null && !reentry!.accepts(ticket!)) {
        codec.dispose();
        _ensureActive();
      }
      _retain(codec, completedBytes, durable: durable);
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

  void _retain(ui.Codec codec, Uint8List bytes,
      {required bool durable, DateTime? expires}) {
    if (requests.isCancelled || ticket == null || galleryImage == null) return;
    final frame = codec is _ValidatedImageCodec && codec.frameCount == 1
        ? codec._firstFrame?.image
        : null;
    reentry?.complete(
        ticket!,
        galleryImage!,
        imageScope?.key(readerImageCacheKey(url)) ?? readerImageCacheKey(url),
        frame,
        bytes,
        durable: durable,
        expires: expires);
  }

  Future<ui.Codec> _decode(Uint8List bytes, ImageDecoderCallback decode) async {
    _ensureActive();
    final buffer = await _waitFor(ui.ImmutableBuffer.fromUint8List(bytes),
        disposeLate: (buffer) => buffer.dispose());
    if (_obsolete) buffer.dispose();
    _ensureActive();
    final codec =
        await _waitFor(decode(buffer), disposeLate: (codec) => codec.dispose());
    try {
      _ensureActive();
      // Creating a codec only parses the image header. Validate the first
      // actual frame before considering these bytes successfully loaded.
      final firstFrame = await _waitFor(codec.getNextFrame(),
          disposeLate: (frame) => frame.image.dispose());
      if (requests.isCancelled ||
          ticket != null && !reentry!.accepts(ticket!)) {
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
      other.imageScope?.requestTag == imageScope?.requestTag &&
      identical(other.requests, requests) &&
      other.attempt == attempt &&
      other.cacheOnly == cacheOnly &&
      other.ticket?.generation == ticket?.generation &&
      other.ticket?.revision == ticket?.revision &&
      other.ticket?.serial == ticket?.serial &&
      other.idleTimeout == idleTimeout;

  @override
  int get hashCode => Object.hash(
      url,
      requests,
      attempt,
      idleTimeout,
      cacheOnly,
      ticket?.generation,
      ticket?.revision,
      ticket?.serial,
      imageScope?.requestTag);
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

class ReaderLocalCacheMiss implements Exception {
  const ReaderLocalCacheMiss();
}
