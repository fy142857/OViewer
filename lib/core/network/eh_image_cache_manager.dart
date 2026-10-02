import 'package:file/file.dart';
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
import 'reader_image_cache_key.dart';
import 'image_cache_quota.dart';

/// Custom [CacheManager] that injects cookies from the app [CookieManager]
/// into every image request. This is required for ExHentai, which returns
/// 403 / a blank sad-panda page when cookies are missing.
class EhImageCacheManager extends CacheManager {
  static const _key = 'ehImageCache';
  static EhImageCacheManager? _instance;
  final Config _readerConfig;
  final ImageCacheQuota _quota;
  Future<Map<String, List<String>>>? _legacyReaderKeys;
  Future<void>? _clearing;
  int _fileSequence = 0;

  static EhImageCacheManager get instance {
    assert(_instance != null,
        'EhImageCacheManager not initialised. Call init() first.');
    return _instance!;
  }

  /// Call once during app startup, after [CookieManager.init].
  static void init(CookieManager cookieManager, {int limitMB = 500}) {
    _instance = EhImageCacheManager._(cookieManager, limitMB);
  }

  ValueListenable<int> get changes => _quota.changes;
  bool get cleanupFailed => _quota.cleanupFailed;
  Future<void> applyLimitMB(int mb) => _quota.setLimit(mb * 1024 * 1024);
  Future<void> enforceLimit() => _quota.enforce();
  Future<void> enforceLimitQuietly() => _quota.maintainQuietly();

  /// Reader images use an explicitly owned client, never the global cache's
  /// in-flight requests. A new reader can request the same URL immediately.
  static FileService readerFileService(
    CookieManager cookies,
    ReaderRequestController requests,
  ) =>
      _CookieHttpFileService(cookies, readerRequest: requests);

  EhImageCacheManager._(CookieManager cookieManager, int limitMB)
      : this._configured(
            Config(
              _key,
              fileService: _CookieHttpFileService(
                cookieManager,
              ),
            ),
            limitBytes: limitMB * 1024 * 1024);

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
      {int limitBytes = 500 * 1024 * 1024})
      : this._withQuota(_configure(config, limitBytes));

  EhImageCacheManager._withQuota((Config, ImageCacheQuota) configured)
      : _readerConfig = configured.$1,
        _quota = configured.$2,
        super(configured.$1);

  @visibleForTesting
  EhImageCacheManager.forTesting(Config config,
      {int limitBytes = 500 * 1024 * 1024})
      : this._configured(config, limitBytes: limitBytes);

  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    await _quota.drain();
    final result =
        await super.getFileFromCache(key, ignoreMemCache: ignoreMemCache);
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
    _quota.pin(cacheKey);
    try {
      await _quota.drain();
      // async* backpressure keeps the pin through the consumer's byte read/decode.
      yield* super.getFileStream(url,
          key: key, headers: headers, withProgress: withProgress);
    } finally {
      await _quota.unpin(cacheKey, check: true);
    }
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
    _quota.pin(cacheKey);
    try {
      await _quota.drain();
      // Await registration: the library returns before the new file is indexed.
      final path =
          'oviewer-${DateTime.now().microsecondsSinceEpoch}-${_fileSequence++}.$extension';
      final file = await _readerConfig.fileSystem.createFile(path);
      await write(file);
      await store.putFile(CacheObject(url,
          key: cacheKey,
          relativePath: path,
          validTill: DateTime.now().add(maxAge),
          eTag: eTag,
          length: await file.length()));
      return file;
    } finally {
      await _quota.unpin(cacheKey, check: true);
    }
  }

  Future<Iterable<String>> legacyReaderKeys(String key) async {
    // Ensure the shared cache repository has finished opening.
    await getFileFromCache(key);
    final index = await (_legacyReaderKeys ??=
        _readerConfig.repo.getAllObjects().then((entries) {
      final result = <String, List<String>>{};
      for (final entry in entries) {
        final stable = readerImageCacheKey(entry.url);
        if (stable != entry.url && entry.key == entry.url) {
          (result[stable] ??= []).add(entry.key);
        }
      }
      return result;
    }));
    return index[key] ?? const [];
  }

  @override
  Future<void> emptyCache() =>
      _clearing ??= _clearImages().whenComplete(() => _clearing = null);

  /// Actual bytes in the image-cache directory, including expired files that
  /// have not been deleted yet. Database metadata and saved photos live elsewhere.
  Future<int> getSizeBytes() async {
    final probe = await _readerConfig.fileSystem.createFile('__size_probe__');
    final directory = probe.parent;
    if (!await directory.exists()) return 0;
    var total = 0;
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
    _quota.pause();
    _legacyReaderKeys = null;
    final memory = PaintingBinding.instance.imageCache;
    memory.clear();
    memory.clearLiveImages();
    try {
      // Wait for repository initialization without creating a cache entry.
      await getFileFromCache('__oviewer_cache_clear__');
      final entries = await _readerConfig.repo.getAllObjects();
      Object? failure;
      StackTrace? failureStack;
      for (final entry in entries) {
        try {
          // flutter_cache_manager 3.x emptyCache starts file deletion without
          // awaiting it. removeFile awaits deletion before removing metadata,
          // so a failed file stays discoverable for the user's next retry.
          await removeFile(entry.key);
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        }
      }
      if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    } finally {
      _legacyReaderKeys = null;
      store.emptyMemoryCache();
      memory.clear();
      memory.clearLiveImages();
      await _quota.resume();
    }
  }
}

class _CookieHttpFileService extends FileService {
  static final _log = Logger();
  final CookieManager _cookieManager;
  http.Client? _defaultHttpClient;
  final ReaderRequestController? readerRequest;

  _CookieHttpFileService(
    this._cookieManager, {
    http.Client? httpClient,
    this.readerRequest,
  }) : _defaultHttpClient = httpClient;

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    await NetworkProxy.waitUntilReady();
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
        headers: headers,
        readerRequest: readerRequest,
      );
    }

    try {
      // The E-Hentai thumbnail host is the preferred route. In some proxy
      // networks s.exhentai.org completes CONNECT but drops its TLS handshake.
      final response = await _getWithRetries(
        preferredUrl,
        headers: headers,
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
      headers: headers,
      readerRequest: readerRequest,
    );
  }

  Future<FileServiceResponse> _getWithRetries(
    String url, {
    Map<String, String>? headers,
    int maxAttempts = 3,
    ReaderRequestController? readerRequest,
  }) async {
    final uri = Uri.parse(url);
    final merged = Map<String, String>.from(headers ?? {});
    await _cookieManager.applyRequestHeaders(uri, merged);
    // Match the User-Agent used by DioClient so servers see consistent requests.
    merged['User-Agent'] =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
        'Mobile/15E148 Safari/604.1';

    var attempt = 0;
    while (true) {
      _ensureReaderRequestActive(readerRequest);
      try {
        final response = await _send(
          url,
          headers: merged,
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
    required Map<String, String> headers,
    ReaderRequestController? readerRequest,
  }) async {
    _ensureReaderRequestActive(readerRequest);
    final request = http.Request('GET', Uri.parse(url));
    request.headers.addAll(headers);
    final client = readerRequest?.imageClient ??
        (_defaultHttpClient ??= createImageHttpClient());
    final response = await client.send(request);
    return HttpGetResponse(response);
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
