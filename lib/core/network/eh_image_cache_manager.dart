import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:logger/logger.dart';
import '../constants/app_constants.dart';
import 'cookie_manager.dart';
import 'image_http_client.dart';
import 'network_proxy_io.dart';

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

class _CookieHttpFileService extends HttpFileService {
  static final _log = Logger();
  final CookieManager _cookieManager;

  _CookieHttpFileService(this._cookieManager, {super.httpClient});

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
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
      return _getWithRetries(url, headers: headers);
    }

    try {
      // The E-Hentai thumbnail host is the preferred route. In some proxy
      // networks s.exhentai.org completes CONNECT but drops its TLS handshake.
      final response = await _getWithRetries(
        preferredUrl,
        headers: headers,
        maxAttempts: 1,
      );
      if (response.statusCode < 400) return response;

      await response.content.drain<void>();
      _log.w(
        '[image] host=ehgt.org status=${response.statusCode}; '
        'retrying via s.exhentai.org proxy=${NetworkProxy.isEnabled}',
      );
    } catch (error) {
      _log.w(
        '[image] host=ehgt.org failed; retrying via s.exhentai.org '
        'proxy=${NetworkProxy.isEnabled} error=${error.runtimeType}',
      );
    }

    return _getWithRetries(url, headers: headers);
  }

  Future<FileServiceResponse> _getWithRetries(
    String url, {
    Map<String, String>? headers,
    int maxAttempts = 3,
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
      try {
        final response = await super.get(url, headers: merged);
        _log.d(
          '[image] host=${uri.host} status=${response.statusCode} '
          'proxy=${NetworkProxy.isEnabled} attempt=${attempt + 1}',
        );
        if (response.statusCode < 500 || attempt >= maxAttempts - 1) {
          return response;
        }
      } catch (error) {
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
