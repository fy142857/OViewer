import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../../core/network/cookie_manager.dart' as app;
import '../../../core/network/network_proxy_io.dart';
import 'upload_protocol.dart';

class UploadResponse {
  final Uri uri;
  final String body;
  const UploadResponse(this.uri, this.body);
}

/// Upload management has its own transport and never enters the reader queue.
class UploadHttpClient {
  final app.CookieManager cookies;
  final Dio _dio;
  late final Dio _imageDio;
  final Set<CancelToken> _active = {};
  bool _disposed = false;

  UploadHttpClient(this.cookies,
      {HttpClientAdapter? adapter, HttpClientAdapter? imageAdapter})
      : _dio = Dio(BaseOptions(
          responseType: ResponseType.plain,
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 60),
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 600,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    'Chrome/130.0.0.0 Safari/537.36'
          },
        )) {
    _dio.httpClientAdapter = adapter ??
        IOHttpClientAdapter(
            createHttpClient: NetworkProxy.createAuthenticatedHttpClient);
    cookies.configureDio(_dio);
    // Signed image URLs do not need gallery authentication cookies. Keep this
    // client completely separate from CookieManager's site/image interceptors.
    _imageDio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: false,
      responseType: ResponseType.stream,
      validateStatus: (status) =>
          status != null && status >= 200 && status < 600,
      headers: {'User-Agent': _dio.options.headers['User-Agent']},
    ));
    _imageDio.httpClientAdapter = imageAdapter ??
        IOHttpClientAdapter(
            createHttpClient: NetworkProxy.createAuthenticatedHttpClient);
  }

  void cancelActive() {
    for (final token in _active.toList()) {
      token.cancel('upload_session_invalidated');
    }
  }

  void dispose() {
    _disposed = true;
    cancelActive();
    _dio.close(force: true);
    _imageDio.close(force: true);
  }

  Future<UploadResponse> get(Uri uri, {CancelToken? cancelToken}) =>
      _request('GET', uri, cancelToken: cancelToken);

  /// Some official controls use a state-changing GET. They have a distinct
  /// entry point; normal reads and redirects must never replay one of them.
  Future<UploadResponse> mutateGalleryAction(Uri observedUri,
      {required String expectedGalleryId,
      required String expectedAction,
      CancelToken? cancelToken}) {
    requireUploadUri(observedUri);
    if (observedUri.path != '/managegallery' ||
        !{'publish', 'delete', 'disown', 'unlock', 'clone'}
            .contains(expectedAction) ||
        !RegExp(r'^[1-9]\d*$').hasMatch(expectedGalleryId) ||
        observedUri.queryParametersAll['ulgid']?.length != 1 ||
        observedUri.queryParameters['ulgid'] != expectedGalleryId ||
        observedUri.queryParametersAll['act']?.length != 1 ||
        observedUri.queryParameters['act'] != expectedAction ||
        observedUri.queryParameters.keys
            .any((key) => !{'ulgid', 'act', 'from'}.contains(key))) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    return _request('GET', observedUri,
        mutation: true, initialMutationGet: true, cancelToken: cancelToken);
  }

  Future<UploadResponse> getStatistics(Uri observedUri,
      {CancelToken? cancelToken}) async {
    bool allowed(Uri uri) =>
        uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        {'e-hentai.org', 'exhentai.org', 'upld.e-hentai.org'}
            .contains(uri.host) &&
        {'/stats.php', '/stats'}.contains(uri.path) &&
        !uri.queryParameters.containsKey('act') &&
        RegExp(r'^[1-9]\d*$').hasMatch(uri.queryParameters['gid'] ?? '');
    if (!allowed(observedUri)) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final revision = cookies.sessionRevision;
    final token = cancelToken ?? CancelToken();
    _active.add(token);
    void current() {
      if (_disposed ||
          token.isCancelled ||
          cookies.sessionRevision != revision) {
        throw const UploadFailure(UploadFailureKind.sessionChanged);
      }
    }

    try {
      await Future.any([NetworkProxy.waitUntilReady(), token.whenCancel]);
      current();
      if (await cookies.getMemberId() == null) {
        throw const UploadFailure(UploadFailureKind.loginRequired);
      }
      var target = observedUri.removeFragment();
      for (var hop = 0; hop < 5; hop++) {
        current();
        final response = await _dio.get<String>(target.toString(),
            cancelToken: token,
            options: Options(
                extra: {app.CookieManager.sessionRequestKey: revision}));
        current();
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value('location');
          final next = location == null ? null : target.resolve(location);
          if (next == null ||
              !allowed(next) ||
              next.origin != observedUri.origin ||
              next.queryParameters['gid'] !=
                  observedUri.queryParameters['gid']) {
            throw const UploadFailure(UploadFailureKind.protocolChanged);
          }
          target = next.removeFragment();
          continue;
        }
        if (response.statusCode != 200) {
          throw const UploadFailure(UploadFailureKind.network);
        }
        final body = response.data ?? '';
        if (body.length > 2 * 1024 * 1024) {
          throw const UploadFailure(UploadFailureKind.protocolChanged);
        }
        return UploadResponse(target, body);
      }
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    } on DioException {
      current();
      throw const UploadFailure(UploadFailureKind.network);
    } finally {
      _active.remove(token);
    }
  }

  void _validateReadUri(Uri uri) {
    if (uri.path != '/managegallery') return;
    final actions = uri.queryParametersAll['act'] ?? const <String>[];
    if (actions.length > 1 ||
        actions.any((action) => action.isNotEmpty && action != 'new')) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
  }

  Future<UploadResponse> postForm(
      UploadForm form, Map<String, List<String>> edits,
      {CancelToken? cancelToken}) {
    final fields = form.submission(edits);
    final entries = [
      for (final entry in fields.entries)
        for (final value in entry.value) MapEntry(entry.key, value)
    ];
    final Object data;
    final String contentType;
    if (form.multipart) {
      data = FormData()..fields.addAll(entries);
      contentType = 'multipart/form-data';
    } else {
      data = entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      contentType = Headers.formUrlEncodedContentType;
    }
    return _request('POST', form.action,
        data: data,
        contentType: contentType,
        cancelToken: cancelToken,
        headers: {
          'Origin': uploadOrigin.origin,
          'Referer': form.action.toString()
        },
        mutation: true);
  }

  /// These JSON methods only read server state; management writes use forms.
  Future<Map<String, dynamic>> readApi(
      UploadApiSession api, String method, Map<String, Object> arguments,
      {CancelToken? cancelToken, Uri? referer}) async {
    if (!{'managefolders', 'viewimage', 'uploadprogress'}.contains(method)) {
      throw ArgumentError('Unsupported read-only upload method');
    }
    final response = await _request('POST', uploadOrigin.resolve('api'),
        data: jsonEncode(api.request(method, arguments)),
        contentType: Headers.jsonContentType,
        cancelToken: cancelToken,
        headers: {
          'Origin': uploadOrigin.origin,
          'Referer': requireUploadUri(referer ?? uploadOrigin.resolve('manage'))
              .toString()
        });
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected upload API envelope');
      }
      if (decoded.containsKey('login')) {
        throw const UploadFailure(UploadFailureKind.loginRequired);
      }
      if (decoded['error'] != null) {
        throw UploadFailure(UploadFailureKind.restricted,
            serverMessage: decoded['error'].toString());
      }
      return decoded;
    } on FormatException {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
  }

  /// A bounded, session-scoped read of an observed signed image destination.
  /// No site cookies, redirects, URL logging, or reader cache are involved.
  Future<Uint8List> readImage(Uri uri,
      {CancelToken? cancelToken, int maxBytes = 50000000}) async {
    if (maxBytes <= 0 || maxBytes > 50000000) {
      throw ArgumentError('Invalid preview size limit');
    }
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !(uri.host == 'ehgt.org' || uri.host.endsWith('.hath.network'))) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final revision = cookies.sessionRevision;
    final token = CancelToken();
    cancelToken?.whenCancel.then((_) => token.cancel('preview_cancelled'));
    void current() {
      if (_disposed ||
          token.isCancelled ||
          revision != cookies.sessionRevision) {
        throw const UploadFailure(UploadFailureKind.sessionChanged);
      }
    }

    if (_disposed) throw StateError('Upload transport is disposed');
    _active.add(token);
    ResponseBody? receivedBody;
    var subscribed = false;
    try {
      await Future.any([NetworkProxy.waitUntilReady(), token.whenCancel]);
      current();
      if (!await cookies.hasLoginCookies()) {
        throw const UploadFailure(UploadFailureKind.loginRequired);
      }
      current();
      final response = await _imageDio.get<ResponseBody>(
          uri.removeFragment().toString(),
          cancelToken: token);
      receivedBody = response.data;
      current();
      final body = response.data;
      if (response.statusCode != 200 || body == null) {
        throw const UploadFailure(UploadFailureKind.network);
      }
      final mime = response.headers
          .value('content-type')
          ?.split(';')
          .first
          .toLowerCase();
      if (mime != null &&
          !{'image/jpeg', 'image/png', 'image/gif', 'image/webp'}
              .contains(mime)) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
      final limit = maxBytes;
      final length =
          int.tryParse(response.headers.value('content-length') ?? '');
      if (length != null && length > limit) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage: 'The image exceeds the preview size limit.');
      }
      final result = Completer<Uint8List>();
      final bytes = BytesBuilder(copy: false);
      StreamSubscription<Uint8List>? subscription;
      void fail(Object error) {
        if (result.isCompleted) return;
        result.completeError(error);
        subscription?.cancel();
      }

      subscribed = true;
      subscription =
          body.stream.timeout(const Duration(seconds: 60)).listen((chunk) {
        if (result.isCompleted) return;
        try {
          current();
          if (bytes.length + chunk.length > limit) {
            throw const UploadFailure(UploadFailureKind.restricted,
                serverMessage: 'The image exceeds the preview size limit.');
          }
          bytes.add(chunk);
        } catch (error) {
          fail(error);
        }
      }, onError: (_) {
        try {
          current();
          fail(const UploadFailure(UploadFailureKind.network));
        } catch (error) {
          fail(error);
        }
      }, onDone: () {
        if (result.isCompleted) return;
        try {
          current();
          result.complete(bytes.takeBytes());
        } catch (error) {
          fail(error);
        }
      });
      token.whenCancel.then(
          (_) => fail(const UploadFailure(UploadFailureKind.sessionChanged)));
      if (result.isCompleted) await subscription.cancel();
      try {
        return await result.future;
      } finally {
        await subscription.cancel();
      }
    } on DioException {
      current();
      throw const UploadFailure(UploadFailureKind.network);
    } finally {
      // Dio's response wrapper does not propagate a downstream subscription
      // cancellation to its source. Cancel this private request token as well.
      token.cancel('preview_finished');
      if (!subscribed && receivedBody != null) {
        await receivedBody.stream.listen(null, onError: (_) {}).cancel();
      }
      _active.remove(token);
    }
  }

  Future<UploadResponse> _request(
    String method,
    Uri uri, {
    Object? data,
    String? contentType,
    CancelToken? cancelToken,
    bool mutation = false,
    bool initialMutationGet = false,
    Map<String, String>? headers,
  }) async {
    requireUploadUri(uri);
    if (!{'/manage', '/managegallery', '/managefolders', '/api'}
        .contains(uri.path)) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final revision = cookies.sessionRevision;
    final token = cancelToken ?? CancelToken();
    if (_disposed) throw StateError('Upload transport is disposed');
    _active.add(token);
    var requestStarted = false;
    void current() {
      if (_disposed ||
          token.isCancelled ||
          revision != cookies.sessionRevision) {
        throw UploadFailure(mutation && requestStarted
            ? UploadFailureKind.resultUncertain
            : UploadFailureKind.sessionChanged);
      }
    }

    try {
      await Future.any([NetworkProxy.waitUntilReady(), token.whenCancel]);
      current();
      if (!await cookies.hasLoginCookies()) {
        throw const UploadFailure(UploadFailureKind.loginRequired);
      }
      current();
      var target = uri.removeFragment();
      for (var hop = 0; hop < 6; hop++) {
        current();
        if (method == 'GET' && !(initialMutationGet && hop == 0)) {
          _validateReadUri(target);
        }
        requestStarted = true;
        final response = await _dio.request<String>(target.toString(),
            data: data,
            cancelToken: token,
            options: Options(
                method: method,
                contentType: contentType,
                headers: headers,
                extra: {app.CookieManager.sessionRequestKey: revision}));
        current();
        final status = response.statusCode!;
        if ({301, 302, 303, 307, 308}.contains(status)) {
          final location = response.headers.value('location');
          if (location == null) {
            throw UploadFailure(mutation
                ? UploadFailureKind.resultUncertain
                : UploadFailureKind.protocolChanged);
          }
          final next = target.resolve(location);
          if (mutation &&
              initialMutationGet &&
              next.scheme == 'https' &&
              next.port == 443 &&
              next.userInfo.isEmpty &&
              {'e-hentai.org', 'exhentai.org'}.contains(next.host) &&
              RegExp(r'^/g/[1-9]\d*/[a-f0-9]+/?$').hasMatch(next.path)) {
            // The operation may lead to its public gallery. Do not forward any
            // request or credentials: the owner page must confirm the outcome.
            return UploadResponse(target, '');
          }
          if (next.host == 'e-hentai.org' ||
              next.host == 'forums.e-hentai.org') {
            throw const UploadFailure(UploadFailureKind.loginRequired);
          }
          requireUploadUri(next);
          if (!{'/manage', '/managegallery', '/managefolders'}
                  .contains(next.path) ||
              ((mutation || method != 'GET') &&
                  (status == 307 || status == 308))) {
            throw UploadFailure(mutation
                ? UploadFailureKind.resultUncertain
                : UploadFailureKind.protocolChanged);
          }
          // Never replay a mutation body after a redirect.
          method = 'GET';
          data = null;
          contentType = null;
          target = next.removeFragment();
          continue;
        }
        if (status == 401) {
          throw const UploadFailure(UploadFailureKind.loginRequired);
        }
        if (status == 403 || status == 429) {
          throw const UploadFailure(UploadFailureKind.restricted);
        }
        if (status < 200 || status >= 300) {
          throw UploadFailure(mutation
              ? UploadFailureKind.resultUncertain
              : UploadFailureKind.network);
        }
        return UploadResponse(target, response.data ?? '');
      }
      throw UploadFailure(mutation
          ? UploadFailureKind.resultUncertain
          : UploadFailureKind.protocolChanged);
    } on DioException {
      if (revision != cookies.sessionRevision ||
          token.isCancelled ||
          _disposed) {
        throw UploadFailure(mutation && requestStarted
            ? UploadFailureKind.resultUncertain
            : UploadFailureKind.sessionChanged);
      }
      throw UploadFailure(mutation && requestStarted
          ? UploadFailureKind.resultUncertain
          : UploadFailureKind.network);
    } finally {
      _active.remove(token);
    }
  }
}
