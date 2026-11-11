import 'dart:async';
import 'package:file/file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// Needed to await registration through CacheManager.store in 3.3.x.
// ignore: implementation_imports
import 'package:flutter_cache_manager/src/storage/cache_object.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../constants/app_constants.dart';
import 'cookie_manager.dart';
import 'image_http_client.dart';
import 'network_proxy_io.dart';
import 'reader_request_controller.dart';
import 'image_cache_scope.dart';
import 'image_cache_quota.dart';
import '../storage/reader_reentry_cache.dart';

/// Custom [CacheManager] that injects cookies from the app [CookieManager]
/// into every image request. This is required for ExHentai, which returns
/// 403 / a blank sad-panda page when cookies are missing.
class EhImageCacheManager extends CacheManager {
  static const _key = 'ehImageCache';
  static EhImageCacheManager? _instance;
  final Config _readerConfig;
  final ImageCacheQuota _quota;
  final bool _retainEngine;
  Future<void>? _clearing;
  final ValueNotifier<bool> clearing = ValueNotifier(false);
  Future<int>? _sizeRead;
  final Set<Future<void>> _registrations = {};
  int _fileSequence = 0;
  int _clearGeneration = 0;

  static EhImageCacheManager get instance {
    assert(_instance != null,
        'EhImageCacheManager not initialised. Call init() first.');
    return _instance!;
  }

  /// Install an explicit test backend instead of selecting a native database
  /// from the host OS, which is unavailable in a Flutter unit-test process.
  @visibleForTesting
  static void initForTesting(Config config) {
    _instance = EhImageCacheManager.forTesting(config);
  }

  /// Call once during app startup, after [CookieManager.init].
  static void init(CookieManager cookieManager, {int limitMB = 500}) {
    ReaderReentryCache.shared.observeMemory();
    _instance = EhImageCacheManager._(cookieManager, limitMB);
  }

  Listenable get changes =>
      Listenable.merge([_quota.changes, ReaderReentryCache.shared.changes]);
  int get retainedMemoryBytes => ReaderReentryCache.shared.memoryBytes;
  bool get cleanupFailed => _quota.cleanupFailed;
  Future<void> applyLimitMB(int mb) => _quota.setLimit(mb * 1024 * 1024);
  Future<void> enforceLimit() => _quota.enforce();
  Future<void> enforceLimitQuietly() => _quota.maintainQuietly();

  /// Reader images use an explicitly owned client, never the global cache's
  /// in-flight requests. A new reader can request the same URL immediately.
  static FileService readerFileService(
    CookieManager cookies,
    ReaderRequestController requests, {
    int maxAttempts = 3,
    ImageCacheScope? imageScope,
  }) =>
      _CookieHttpFileService(cookies,
          readerRequest: requests,
          maxAttempts: maxAttempts,
          imageScope: imageScope ?? ImageCacheScope.capture());

  EhImageCacheManager._(CookieManager cookieManager, int limitMB)
      : this._configured(
            Config(
              _key,
              fileService: _CookieHttpFileService(
                cookieManager,
              ),
            ),
            limitBytes: limitMB * 1024 * 1024,
            retainEngine: true);

  static (Config, ImageCacheQuota) _configure(Config config, int limitBytes) {
    final quota =
        ImageCacheQuota(config.repo, config.fileSystem, limitBytes: limitBytes);
    final managed = Config(config.cacheKey,
        repo: quota,
        fileSystem: config.fileSystem,
        fileService: config.fileService);
    return (managed, quota);
  }

  EhImageCacheManager._configured(Config config,
      {int limitBytes = 500 * 1024 * 1024, bool retainEngine = false})
      : this._withQuota(_configure(config, limitBytes), retainEngine);

  EhImageCacheManager._withQuota(
      (Config, ImageCacheQuota) configured, this._retainEngine)
      : _readerConfig = configured.$1,
        _quota = configured.$2,
        super(configured.$1);

  @visibleForTesting
  EhImageCacheManager.forTesting(Config config,
      {int limitBytes = 500 * 1024 * 1024, bool retainEngine = false})
      : this._configured(config,
            limitBytes: limitBytes, retainEngine: retainEngine);

  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    await _quota.drain();
    while (_clearing != null) {
      await _waitForClear();
    }
    // A disk lookup also schedules an unawaited metadata touch in the library.
    // Keep it in the lookup's generation so clearing cannot be undone by it.
    final result = await _quota.inWriteGeneration(
        () => super.getFileFromCache(key, ignoreMemCache: ignoreMemCache));
    if (result != null) await _quota.touch(key);
    return result;
  }

  /// A byte read and automatic eviction must never race on the same disk file.
  Future<Uint8List?> readBytes(String key) async {
    _quota.pin(key);
    try {
      final entry = await getFileFromCache(key);
      if (entry == null || !entry.validTill.isAfter(DateTime.now())) {
        return null;
      }
      return await entry.file.readAsBytes();
    } finally {
      await _quota.unpin(key);
    }
  }

  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    final cacheKey = key ?? url;
    final tag = headers?[ImageCacheScope.header];
    final scope = tag == null ? null : ImageCacheScope.fromTag(tag);
    await _waitForClear();
    final generation = _clearGeneration;
    _quota.pin(cacheKey);
    try {
      await _quota.drain();
      // async* backpressure keeps the pin through the consumer's byte read/decode.
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          scope?.ensureCurrent();
          await for (final response in _quota.guardWriteStream(() => super
              .getFileStream(url,
                  key: key, headers: headers, withProgress: withProgress))) {
            if (generation != _clearGeneration) {
              throw StateError('Image cache was cleared during download');
            }
            scope?.ensureCurrent();
            yield response;
          }
          break;
        } on ImageScopeExpired {
          scope?.ensureCurrent();
          if (scope == null || attempt != 0) rethrow;
          // A rapid EH -> EX -> EH can subscribe to the cache library's old
          // in-flight request for the same durable key. Let it close/remove
          // that request, then retry once with the current scope's headers.
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      await _quota.unpin(cacheKey, check: true);
    }
  }

  @override
  Future<FileInfo> downloadFile(String url,
      {String? key,
      Map<String, String>? authHeaders,
      bool force = false}) async {
    await _waitForClear();
    final generation = _clearGeneration;
    final result = await _quota.inWriteGeneration(() => super
        .downloadFile(url, key: key, authHeaders: authHeaders, force: force));
    if (generation != _clearGeneration) {
      throw StateError('Image cache was cleared during download');
    }
    return result;
  }

  @override
  Future<File> putFile(String url, Uint8List fileBytes,
          {String? key,
          String? eTag,
          Duration maxAge = const Duration(days: 30),
          String fileExtension = 'file'}) =>
      _putCompleted(url, key ?? url, eTag, maxAge, fileExtension, (file) async {
        await file.writeAsBytes(fileBytes);
      });

  @override
  Future<File> putFileStream(String url, Stream<List<int>> source,
          {String? key,
          String? eTag,
          Duration maxAge = const Duration(days: 30),
          String fileExtension = 'file'}) =>
      _putCompleted(url, key ?? url, eTag, maxAge, fileExtension,
          (file) => source.pipe(file.openWrite()));

  Future<File> _putCompleted(
      String url,
      String cacheKey,
      String? eTag,
      Duration maxAge,
      String extension,
      Future<void> Function(File) write) async {
    final generation = _clearGeneration;
    // Writes requested during cleanup belong to the new generation. Do not let
    // their files or same-key metadata race with the deletion snapshot.
    await _waitForClear();
    _quota.pin(cacheKey);
    try {
      await _quota.drain();
      // Await registration: the library returns before the new file is indexed.
      final path =
          'oviewer-${DateTime.now().microsecondsSinceEpoch}-${_fileSequence++}.$extension';
      final file = await _readerConfig.fileSystem.createFile(path);
      await write(file);
      final length = await file.length();
      if (generation != _clearGeneration) {
        await file.delete();
        throw StateError('Image cache was cleared during write');
      }
      final registration = store.putFile(CacheObject(url,
          key: cacheKey,
          relativePath: path,
          validTill: DateTime.now().add(maxAge),
          eTag: eTag,
          length: length));
      _registrations.add(registration);
      try {
        await registration;
      } finally {
        _registrations.remove(registration);
      }
      if (generation != _clearGeneration) {
        // A newer write may already own this key. Delete only this writer's
        // unique file; a stale missing-file index is discarded on its next read.
        if (await file.exists()) await file.delete();
        store.emptyMemoryCache();
        throw StateError('Image cache was cleared during registration');
      }
      return file;
    } finally {
      await _quota.unpin(cacheKey, check: true);
    }
  }

  @override
  Future<void> emptyCache() {
    if (_clearing != null) return _clearing!;
    final completion = Completer<void>();
    _clearing = completion.future;
    _clearGeneration++;
    _quota.invalidateWrites();
    clearing.value = true;
    _clearImages().then((_) {
      _clearing = null;
      clearing.value = false;
      completion.complete();
    }, onError: (Object error, StackTrace stack) {
      _clearing = null;
      clearing.value = false;
      completion.completeError(error, stack);
    });
    return completion.future;
  }

  Future<void> _waitForClear() async {
    while (_clearing != null) {
      try {
        await _clearing;
      } catch (_) {
        // Partial deletion failure must not disable subsequent cache writes.
      }
    }
  }

  /// Actual bytes in the image-cache directory, including expired files that
  /// have not been deleted yet. Database metadata and saved photos live elsewhere.
  Future<int> getSizeBytes() async {
    await _waitForClear();
    if (_clearing != null) return getSizeBytes();
    return _sizeRead ??= _measureSize().whenComplete(() => _sizeRead = null);
  }

  Future<int> _measureSize() async {
    final probe = await _readerConfig.fileSystem.createFile('__size_probe__');
    final directory = probe.parent;
    if (!await directory.exists()) return ReaderReentryCache.shared.memoryBytes;
    var total = ReaderReentryCache.shared.memoryBytes;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      try {
        final stat = await entity.stat();
        if (stat.type == FileSystemEntityType.file) total += stat.size;
      } catch (_) {
        // A concurrent cache eviction may remove a file while counting.
        if (await entity.exists()) rethrow;
      }
    }
    return total;
  }

  Future<void> _clearImages() async {
    ReaderReentryCache.shared.clear();
    _quota.pause();
    final memory = PaintingBinding.instance.imageCache;
    memory.clear();
    memory.clearLiveImages();
    var retained = false;
    try {
      if (_retainEngine && defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('oviewer/image_cache').invokeMethod('retain');
        retained = true;
      }
      // Let a pre-clear size scan and already-started metadata registrations
      // finish once; no new scan or writer can enter until this task completes.
      try {
        await _sizeRead;
      } catch (_) {}
      await Future.wait(_registrations.toList().map((write) async {
        try {
          await write;
        } catch (_) {}
      }));
      await _quota.drain();
      final entries = await _readerConfig.repo.getAllObjects();
      Object? failure;
      StackTrace? failureStack;
      var next = 0;
      Future<void> worker() async {
        while (next < entries.length) {
          final entry = entries[next++];
          try {
            // Use the snapshot directly: no lookup/touch per key. This API
            // awaits disk deletion before metadata, retaining failed records.
            await removeClearEntry(entry);
          } catch (error, stack) {
            failure ??= error;
            failureStack ??= stack;
          }
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
      final error = failure;
      if (error != null) Error.throwWithStackTrace(error, failureStack!);
    } finally {
      store.emptyMemoryCache();
      memory.clear();
      memory.clearLiveImages();
      try {
        await _quota.resume();
      } finally {
        if (retained) {
          await const MethodChannel('oviewer/image_cache')
              .invokeMethod('release');
        }
      }
    }
  }

  @visibleForTesting
  Future<void> removeClearEntry(CacheObject entry) =>
      store.removeCachedFile(entry);
}

class _CookieHttpFileService extends FileService {
  static final _log = Logger();
  final CookieManager _cookieManager;
  http.Client? _defaultHttpClient;
  final ReaderRequestController? readerRequest;
  final int maxAttempts;
  final ImageCacheScope? imageScope;

  _CookieHttpFileService(
    this._cookieManager, {
    http.Client? httpClient,
    this.readerRequest,
    this.maxAttempts = 3,
    this.imageScope,
  }) : _defaultHttpClient = httpClient;

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final cleanHeaders = Map<String, String>.from(headers ?? {});
    final tag = cleanHeaders.remove(ImageCacheScope.header);
    final scope = imageScope ??
        (tag == null
            ? ImageCacheScope.capture()
            : ImageCacheScope.fromTag(tag));
    scope.ensureCurrent();
    await NetworkProxy.waitUntilReady();
    scope.ensureCurrent();
    _ensureReaderRequestActive(readerRequest);
    final requestUri = Uri.tryParse(url);
    if (requestUri != null &&
        !AppConstants.useExHentai &&
        _isExHentaiHost(requestUri.host)) {
      _log.w('[image] blocked ExHentai resource while E-Hentai mode is active');
      throw StateError(
        'ExHentai image requests are disabled while E-Hentai mode is active.',
      );
    }

    final preferredUrl = _ehgtPreferredUrl(url);
    if (preferredUrl == null) {
      return _getWithRetries(
        url,
        maxAttempts: maxAttempts,
        headers: cleanHeaders,
        scope: scope,
        readerRequest: readerRequest,
      );
    }

    try {
      // The E-Hentai thumbnail host is the preferred route. In some proxy
      // networks s.exhentai.org completes CONNECT but drops its TLS handshake.
      final response = await _getWithRetries(
        preferredUrl,
        headers: cleanHeaders,
        scope: scope,
        maxAttempts: 1,
        readerRequest: readerRequest,
      );
      if (response.statusCode < 400) return response;

      await response.content.drain<void>();
      _log.w(
        '[image] host=ehgt.org status=${response.statusCode}; '
        'retrying via s.exhentai.org proxy=${NetworkProxy.isEnabled}',
      );
    } catch (error) {
      _ensureReaderRequestActive(readerRequest);
      _log.w(
        '[image] host=ehgt.org failed; retrying via s.exhentai.org '
        'proxy=${NetworkProxy.isEnabled} error=${error.runtimeType}',
      );
    }

    return _getWithRetries(
      url,
      maxAttempts: maxAttempts,
      headers: cleanHeaders,
      scope: scope,
      readerRequest: readerRequest,
    );
  }

  Future<FileServiceResponse> _getWithRetries(
    String url, {
    required ImageCacheScope scope,
    Map<String, String>? headers,
    int maxAttempts = 3,
    ReaderRequestController? readerRequest,
  }) async {
    final uri = Uri.parse(url);
    final merged = Map<String, String>.from(headers ?? {});
    scope.ensureCurrent();
    await _cookieManager.applyRequestHeaders(uri, merged);
    scope.ensureCurrent();
    // Match the User-Agent used by DioClient so servers see consistent requests.
    merged['User-Agent'] =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
        'Mobile/15E148 Safari/604.1';

    var attempt = 0;
    while (true) {
      scope.ensureCurrent();
      _ensureReaderRequestActive(readerRequest);
      try {
        final response = await _send(
          url,
          headers: merged,
          scope: scope,
          readerRequest: readerRequest,
        );
        _log.d(
          '[image] host=${uri.host} status=${response.statusCode} '
          'proxy=${NetworkProxy.isEnabled} attempt=${attempt + 1}',
        );
        if (response.statusCode < 500 || attempt >= maxAttempts - 1) {
          return response;
        }
        await response.content.drain<void>();
      } catch (error) {
        _ensureReaderRequestActive(readerRequest);
        _log.w(
          '[image] host=${uri.host} request failed '
          'proxy=${NetworkProxy.isEnabled} attempt=${attempt + 1} '
          'error=${error.runtimeType}: $error',
        );
        if (attempt >= maxAttempts - 1) rethrow;
      }
      attempt++;
      await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
    }
  }

  Future<FileServiceResponse> _send(
    String url, {
    required ImageCacheScope scope,
    required Map<String, String> headers,
    ReaderRequestController? readerRequest,
  }) async {
    _ensureReaderRequestActive(readerRequest);
    scope.ensureCurrent();
    if (const bool.fromEnvironment('READER_DIAGNOSTICS')) {
      debugPrint('[reader-metric] image_request');
    }
    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll(headers);
    final client = readerRequest?.imageClient ??
        (_defaultHttpClient ??= createImageHttpClient());
    final response = await client.send(request);
    if (!scope.isCurrent) {
      await response.stream.listen((_) {}).cancel();
      scope.ensureCurrent();
    }
    return HttpGetResponse(http.StreamedResponse(response.stream.map((bytes) {
      scope.ensureCurrent();
      return bytes;
    }), response.statusCode,
        headers: response.headers,
        contentLength: response.contentLength,
        request: response.request,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase));
  }

  void _ensureReaderRequestActive(ReaderRequestController? readerRequest) {
    if (readerRequest?.isCancelled ?? false) {
      throw StateError('The reader image request has been cancelled.');
    }
  }

  String? _ehgtPreferredUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.toLowerCase() != 's.exhentai.org') {
      return null;
    }
    return uri.replace(host: 'ehgt.org').toString();
  }

  bool _isExHentaiHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'exhentai.org' || normalized.endsWith('.exhentai.org');
  }
}
