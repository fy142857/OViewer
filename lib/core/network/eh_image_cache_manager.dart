import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import '../constants/app_constants.dart';
import 'cookie_manager.dart';
import 'image_http_client.dart';
import 'network_proxy_io.dart';
import 'reader_request_controller.dart';

/// Custom [CacheManager] that injects cookies from the app [CookieManager]
/// into every image request. This is required for ExHentai, which returns
/// 403 / a blank sad-panda page when cookies are missing.
class EhImageCacheManager extends CacheManager {
  static const _key = 'ehImageCache';
  static EhImageCacheManager? _instance;

  static EhImageCacheManager get instance {
    assert(_instance != null,
        'EhImageCacheManager not initialised. Call init() first.');
    return _instance!;
  }

  /// Call once during app startup, after [CookieManager.init].
  static void init(CookieManager cookieManager) {
    _instance = EhImageCacheManager._(cookieManager);
  }

  EhImageCacheManager._(CookieManager cookieManager)
      : super(Config(
          _key,
          fileService: _CookieHttpFileService(
            cookieManager,
            httpClient: createImageHttpClient(),
          ),
        ));
}

class _CookieHttpFileService extends FileService {
  static final _log = Logger();
  final CookieManager _cookieManager;
  final http.Client _defaultHttpClient;

  _CookieHttpFileService(
    this._cookieManager, {
    http.Client? httpClient,
  }) : _defaultHttpClient = httpClient ?? createImageHttpClient();

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final readerRequest = ReaderImageRequestRegistry.controllerFor(url);
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
    final client = readerRequest?.imageClient ?? _defaultHttpClient;
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
