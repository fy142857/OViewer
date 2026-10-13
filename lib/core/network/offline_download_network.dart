import 'dart:async';
import 'package:html/parser.dart' as html;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../../models/gallery_image.dart';
import '../../models/gallery_source.dart';
import '../../models/offline_book.dart';
import '../../models/reader_index_page.dart';
import '../constants/api_endpoints.dart';
import '../parser/gallery_content_warning.dart';
import '../parser/gallery_detail_parser.dart';
import '../parser/gallery_image_parser.dart';
import 'api_exception.dart';
import 'cookie_manager.dart';
import 'dio_client.dart';
import 'eh_image_cache_manager.dart';
import 'reader_request_controller.dart';

/// Injectable transport; the scheduler owns retries, cancellation and permits.
abstract class OfflineDownloadNetwork {
  Object? get session;
  GallerySource get source;
  ReaderRequestController requests() => ReaderRequestController();
  Future<ReaderIndexPage> index(
      OfflineKey key, int page, ReaderRequestController requests);
  Future<GalleryImage> image(
      OfflineKey key, String token, int page, ReaderRequestController requests,
      {String? alternate});
  Future<FileServiceResponse> bytes(
      String url, ReaderRequestController requests);
}

class SiteOfflineDownloadNetwork extends OfflineDownloadNetwork {
  final DioClient dio;
  final CookieManager cookies;
  SiteOfflineDownloadNetwork(this.dio, this.cookies);
  @override
  Object? get session => cookies.sessionRevision;
  @override
  GallerySource get source => GallerySource.current;

  Future<String> _get(
      OfflineKey key, String url, ReaderRequestController request) async {
    if (source != key.source) throw const OfflineFailure('source_changed');
    final revision = session;
    String response;
    try {
      response = await dio.get(url,
          cancelToken: request.cancelToken, followRedirects: false);
    } on ApiException catch (error) {
      if ((error.statusCode ?? 0) >= 300 && (error.statusCode ?? 0) < 400) {
        throw const OfflineFailure('authentication');
      }
      rethrow;
    }
    if (source != key.source || session != revision || request.isCancelled) {
      throw const OfflineFailure('session_changed');
    }
    final warning = GalleryContentWarning.parse(
        response,
        Uri.parse(ApiEndpoints.galleryDetail(key.gid, key.token,
            source: key.source)));
    if (warning != null) throw const OfflineFailure('content_warning');
    final lower = response.toLowerCase();
    if (lower.contains('exceeded your image viewing limits') ||
        lower.contains('excessive pageloads') ||
        lower.contains('temporarily banned')) {
      throw const OfflineFailure('quota');
    }
    final document = html.parse(response);
    if (document.querySelector(
            'input[name="UserName"], input[name="password"], input[name="PassWord"]') !=
        null) {
      throw const OfflineFailure('authentication');
    }
    return response;
  }

  @override
  Future<ReaderIndexPage> index(
      OfflineKey key, int page, ReaderRequestController requests) async {
    final response = await _get(
        key,
        ApiEndpoints.galleryThumbnails(key.gid, key.token,
            page: page, source: key.source),
        requests);
    final document = html.parse(response);
    for (final link in document.querySelectorAll('#gdt a[href]')) {
      final uri = Uri.tryParse(link.attributes['href']!);
      final match =
          RegExp(r'^/s/[^/]+/(\d+)-(\d+)$').firstMatch(uri?.path ?? '');
      if (match != null &&
          (int.parse(match[1]!) != key.gid ||
              (uri!.hasAuthority &&
                  uri.host != Uri.parse(key.source.baseUrl).host))) {
        throw const OfflineFailure('source_mismatch');
      }
    }
    for (final link in document.querySelectorAll('link[rel="canonical"]')) {
      final uri = Uri.tryParse(link.attributes['href'] ?? '');
      if (uri != null &&
          uri.path.startsWith('/g/') &&
          (uri.path != '/g/${key.gid}/${key.token}/' ||
              (uri.hasAuthority &&
                  uri.host != Uri.parse(key.source.baseUrl).host))) {
        throw const OfflineFailure('source_mismatch');
      }
    }
    return GalleryDetailParser.parseReaderIndex(response, page: page);
  }

  @override
  Future<GalleryImage> image(
      OfflineKey key, String token, int page, ReaderRequestController requests,
      {String? alternate}) async {
    final url = Uri.parse(
        ApiEndpoints.imagePage(token, key.gid, page, source: key.source));
    final response = await _get(
        key,
        (alternate == null
                ? url
                : url.replace(queryParameters: {'nl': alternate}))
            .toString(),
        requests);
    final image = GalleryImageParser.parse(response, page);
    final uri = Uri.tryParse(image.imageUrl);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) throw const OfflineFailure('invalid_image');
    return image;
  }

  @override
  Future<FileServiceResponse> bytes(
          String url, ReaderRequestController requests) async =>
      await EhImageCacheManager.readerFileService(cookies, requests,
              maxAttempts: 1)
          .get(url)
          .timeout(const Duration(seconds: 30));
}
