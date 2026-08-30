import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'network_proxy_io.dart';

void configureProxy(Dio dio, String? proxyUrl) {
  NetworkProxy.setProxy(proxyUrl);
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: NetworkProxy.createHttpClient,
  );
}
