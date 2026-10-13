import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:oviewer/main.dart' as application;
import 'package:oviewer/core/network/dio_client.dart';

// This target is packaged only as com.oviewer.oviewer.offline_test. It runs
// real production widgets, persistence, source checks, downloads and service.
// Only gallery HTML/API transport is mapped to the local fixture HTTP server.
class FixtureDioClient extends DioClient {
  FixtureDioClient(super.cookies, super.database);
  String target(String url) {
    final uri = Uri.parse(url);
    if (!const ['e-hentai.org', 'exhentai.org'].contains(uri.host)) {
      throw StateError('Unexpected offline fixture host');
    }
    return Uri(
            scheme: 'http',
            host: '10.0.2.2',
            port: 8765,
            path: '/${uri.host == 'exhentai.org' ? 'ex' : 'eh'}${uri.path}',
            query: uri.query)
        .toString();
  }

  @override
  Future<String> get(String url,
          {Map<String, dynamic>? queryParams,
          CancelToken? cancelToken,
          bool followRedirects = true}) =>
      super.get(target(url),
          queryParams: queryParams,
          cancelToken: cancelToken,
          followRedirects: followRedirects);
  @override
  Future<String> post(String url,
          {dynamic data,
          Map<String, dynamic>? queryParams,
          CancelToken? cancelToken,
          String? contentType,
          Map<String, dynamic>? headers,
          bool followPostRedirects = false}) =>
      super.post(target(url),
          data: data,
          queryParams: queryParams,
          cancelToken: cancelToken,
          contentType: contentType,
          headers: headers,
          followPostRedirects: followPostRedirects);
}

Future<void> main() async {
  await application
      .startOfflineValidation((cookies, db) => FixtureDioClient(cookies, db));
  // Expose real widget semantics to adb/uiautomator during emulator acceptance.
  WidgetsBinding.instance.ensureSemantics();
}
