import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import '../constants/app_constants.dart';
import 'cookie_manager.dart' as app;
import 'api_exception.dart';
import 'dio_proxy_io.dart';
import 'network_proxy_io.dart';
import '../storage/database.dart';

class DioClient {
  static final _log = Logger();
  late final Dio _dio;
  final app.CookieManager _cookieManager;
  final AppDatabase _database;

  Future<void> allowGalleryWarning(Uri gallery) async {
    if (gallery.origin != AppConstants.baseUrl ||
        !RegExp(r'^/g/\d+/[a-f0-9]+/$').hasMatch(gallery.path)) {
      throw ArgumentError('Expected a gallery on the current site.');
    }
    await _database.acceptGalleryWarning(
        int.parse(gallery.pathSegments[1]), gallery.pathSegments[2]);
  }

  Future<void> _applyGalleryWarningChoice(RequestOptions options) async {
    final uri = options.uri;
    if (uri.origin != 'https://e-hentai.org' &&
        uri.origin != 'https://exhentai.org') return;
    final gallery = RegExp(r'^/g/(\d+)/([a-f0-9]+)/$').firstMatch(uri.path);
    final image = RegExp(r'^/s/[^/]+/(\d+)-\d+$').firstMatch(uri.path);
    if (gallery == null && image == null) return;
    final accepted = await _database.hasAcceptedGalleryWarning(
        int.parse((gallery ?? image)![1]!),
        token: gallery?[2]);
    if (!accepted) return;
    // Per-request preference only. Do not persist a site-wide "never warn"
    // cookie or change authentication cookies/account settings.
    final current =
        options.headers['cookie'] ?? options.headers.remove('Cookie') ?? '';
    final cookies = current
        .toString()
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !s.startsWith('nw='));
    options.headers['cookie'] = [...cookies, 'nw=1'].join('; ');
  }

  DioClient(this._cookieManager, this._database) {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: AppConstants.connectTimeout),
      receiveTimeout: const Duration(milliseconds: AppConstants.receiveTimeout),
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
            'Mobile/15E148 Safari/604.1',
      },
      responseType: ResponseType.plain,
    ));

    _cookieManager.configureDio(_dio);

    // Logging interceptor (debug only)
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        try {
          await _applyGalleryWarningChoice(options);
        } catch (error) {
          handler.reject(DioException(requestOptions: options, error: error));
          return;
        }
        _log.d('REQUEST: ${options.method} ${options.uri}');
        handler.next(options);
      },
      onResponse: (response, handler) {
        _log.d(
            'RESPONSE: ${response.statusCode} ${response.requestOptions.uri}');
        handler.next(response);
      },
      onError: (error, handler) {
        _log.e('ERROR: ${error.message} ${error.requestOptions.uri}');
        handler.next(error);
      },
    ));
  }

  Future<String> get(
    String url, {
    Map<String, dynamic>? queryParams,
    CancelToken? cancelToken,
  }) async {
    try {
      if (cancelToken == null) {
        await NetworkProxy.waitUntilReady();
      } else {
        await Future.any(
            [NetworkProxy.waitUntilReady(), cancelToken.whenCancel]);
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      }
      final targetUrl = _appendQueryParameters(url, queryParams);
      _ensureCurrentSite(targetUrl);
      final response = await _dio.get(
        targetUrl,
        cancelToken: cancelToken,
      );
      return response.data as String;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw _handleDioError(e);
    }
  }

  Future<String> post(
    String url, {
    dynamic data,
    Map<String, dynamic>? queryParams,
    CancelToken? cancelToken,
    String? contentType,
    Map<String, dynamic>? headers,
    bool followPostRedirects = false,
  }) async {
    try {
      if (cancelToken == null) {
        await NetworkProxy.waitUntilReady();
      } else {
        await Future.any(
            [NetworkProxy.waitUntilReady(), cancelToken.whenCancel]);
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      }
      final targetUrl = _appendQueryParameters(url, queryParams);
      _ensureCurrentSite(targetUrl);
      var response = await _dio.post(
        targetUrl,
        data: data,
        options: Options(
            contentType: contentType,
            headers: headers,
            followRedirects: followPostRedirects ? false : null,
            validateStatus: followPostRedirects ? _isFormStatus : null),
        cancelToken: cancelToken,
      );
      if (followPostRedirects) {
        final original = Uri.parse(targetUrl);
        for (var hops = 0; _isFormRedirect(response.statusCode); hops++) {
          if (hops >= 5) {
            throw ApiException.parse('Too many comment redirects.');
          }
          final location = response.headers.value('location');
          if (location == null) {
            throw ApiException.parse('Missing redirect location.');
          }
          var target = response.realUri.resolve(location);
          // Only follow this gallery's post/redirect/get. Never resend the body
          // or send the session to another host/gallery or a login page.
          if (target.origin != original.origin ||
              target.userInfo.isNotEmpty ||
              target.path.replaceFirst(RegExp(r'/$'), '') !=
                  original.path.replaceFirst(RegExp(r'/$'), '')) {
            throw const ApiException(
                message:
                    'Comment redirected away from this gallery. Please check your login.');
          }
          target = target.replace(queryParameters: {
            ...target.queryParameters,
            if (original.queryParameters['hc'] == '1') 'hc': '1',
          }).removeFragment();
          _ensureCurrentSite(target.toString());
          response = await _dio.get(target.toString(),
              cancelToken: cancelToken,
              options: Options(
                  followRedirects: false, validateStatus: _isFormStatus));
        }
      }
      return response.data as String;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw _handleDioError(e);
    }
  }

  static bool _isFormRedirect(int? status) =>
      status == 301 || status == 302 || status == 303;
  static bool _isFormStatus(int? status) =>
      status != null &&
      ((status >= 200 && status < 300) || _isFormRedirect(status));

  String _appendQueryParameters(
    String url,
    Map<String, dynamic>? queryParams,
  ) {
    if (queryParams == null || queryParams.isEmpty) return url;
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      ...queryParams.map((key, value) => MapEntry(key, value.toString())),
    }).toString();
  }

  void _ensureCurrentSite(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || AppConstants.useExHentai) return;
    final host = uri.host.toLowerCase();
    if (host == 'exhentai.org' || host.endsWith('.exhentai.org')) {
      throw const ApiException(
        message:
            'ExHentai requests are disabled while E-Hentai mode is active.',
      );
    }
  }

  /// Set HTTP/SOCKS5 proxy for all requests.
  /// Format: "http://host:port" or "socks5://host:port"
  void setProxy(String? proxyUrl) {
    configureProxy(_dio, proxyUrl);
    _log.i(proxyUrl == null || proxyUrl.isEmpty
        ? 'Proxy cleared'
        : 'Proxy configured');
  }

  ApiException _handleDioError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException.timeout();
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode ?? 0;
        if (statusCode == 401 || statusCode == 403) {
          return ApiException.unauthorized();
        }
        if (statusCode == 509) {
          return ApiException.banned();
        }
        return ApiException.server(statusCode);
      case DioExceptionType.connectionError:
        return ApiException.network();
      default:
        return ApiException(
          message: error.message ?? 'Unknown network error',
          originalError: error,
        );
    }
  }
}
