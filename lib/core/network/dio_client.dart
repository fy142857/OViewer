import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import '../constants/app_constants.dart';
import 'cookie_manager.dart' as app;
import 'api_exception.dart';
import 'dio_proxy_io.dart';

class DioClient {
  static final _log = Logger();
  late final Dio _dio;
  final app.CookieManager _cookieManager;

  DioClient(this._cookieManager) {
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
      onRequest: (options, handler) {
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
  }) async {
    try {
      final targetUrl = _appendQueryParameters(url, queryParams);
      _ensureCurrentSite(targetUrl);
      final response = await _dio.post(
        targetUrl,
        data: data,
        cancelToken: cancelToken,
      );
      return response.data as String;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw _handleDioError(e);
    }
  }

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
        : 'Proxy set to: $proxyUrl');
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
