import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import '../core/network/dio_client.dart';
import '../core/parser/gallery_list_parser.dart';
import '../core/parser/gallery_detail_parser.dart';
import '../core/parser/gallery_image_parser.dart';
import '../core/parser/my_tags_parser.dart';
import '../core/constants/api_endpoints.dart';
import '../core/constants/app_constants.dart';
import '../models/gallery_preview.dart';
import '../models/gallery_detail.dart';
import '../models/gallery_image.dart';

class GalleryRepository {
  static final _log = Logger();
  final DioClient _dio;
  final Map<int, _ApiCredentials> _apiCredentials = {};

  GalleryRepository(this._dio);

  /// Resolve a URL that may be relative to absolute.
  /// Handles: full URLs, absolute paths (/...), query-only (?...).
  String _resolve(String url) {
    if (url.startsWith('http')) return url;
    if (url.startsWith('?')) return '${AppConstants.baseUrl}/$url';
    return '${AppConstants.baseUrl}$url';
  }

  /// Fetch gallery list. Uses [nextUrl] for cursor pagination if available,
  /// otherwise falls back to the first-page URL.
  Future<GalleryListResult> fetchGalleryList({
    int page = 0,
    String? nextUrl,
  }) async {
    final url = nextUrl != null
        ? _resolve(nextUrl)
        : ApiEndpoints.galleryList(page: page);
    _log.i('[fetchGalleryList] requesting url=$url');
    final html = await _dio.get(url);
    final galleries = GalleryListParser.parse(html);
    final pageCount = GalleryListParser.parsePageCount(html);
    final nextPageUrl = GalleryListParser.parseNextPageUrl(html);

    _log.i('[fetchGalleryList] got=${galleries.length} '
        'firstGid=${galleries.isNotEmpty ? galleries.first.gid : "N/A"} '
        'pageCount=$pageCount nextUrl=${nextPageUrl ?? "null"}');

    return GalleryListResult(
      galleries: galleries,
      totalPages: pageCount,
      nextPageUrl: nextPageUrl,
    );
  }

  /// Fetch popular galleries
  Future<GalleryListResult> fetchPopularList({int page = 0}) async {
    final html = await _dio.get(ApiEndpoints.popular());
    final galleries = GalleryListParser.parse(html);
    return GalleryListResult(galleries: galleries, totalPages: 1);
  }

  /// Fetch watched galleries (requires login)
  Future<GalleryListResult> fetchWatched({
    int page = 0,
    String? nextUrl,
  }) async {
    final url =
        nextUrl != null ? _resolve(nextUrl) : ApiEndpoints.watched(page: page);
    final html = await _dio.get(url);
    final galleries = GalleryListParser.parse(html);
    final pageCount = GalleryListParser.parsePageCount(html);
    final nextPageUrl = GalleryListParser.parseNextPageUrl(html);
    return GalleryListResult(
      galleries: galleries,
      totalPages: pageCount,
      nextPageUrl: nextPageUrl,
    );
  }

  /// Fetch favorites list for the home tab
  Future<GalleryListResult> fetchFavoritesList({
    int page = 0,
    String? nextUrl,
  }) async {
    final url = nextUrl != null
        ? _resolve(nextUrl)
        : ApiEndpoints.favorites(page: page);
    final html = await _dio.get(url);
    final galleries = GalleryListParser.parse(html);
    final pageCount = GalleryListParser.parsePageCount(html);
    final nextPageUrl = GalleryListParser.parseNextPageUrl(html);
    return GalleryListResult(
      galleries: galleries,
      totalPages: pageCount,
      nextPageUrl: nextPageUrl,
    );
  }

  /// Fetch gallery detail page.
  /// If the HTML `#gj` element is empty (common on ExHentai), falls back to
  /// a single gdata API call to retrieve the Japanese title.
  Future<GalleryDetail> fetchGalleryDetail(
    int gid,
    String token, {
    CancelToken? cancelToken,
  }) async {
    final url = ApiEndpoints.galleryDetail(gid, token);
    final html = await _dio.get(url, cancelToken: cancelToken);
    _cacheApiCredentials(gid, html);
    final detail = GalleryDetailParser.parse(html, gid, token);

    if (detail.titleJpn == null) {
      final titleJpn = await _fetchTitleJpnFromApi(
        gid,
        token,
        cancelToken: cancelToken,
      );
      if (titleJpn != null && titleJpn.isNotEmpty) {
        return GalleryDetail(
          gid: detail.gid,
          token: detail.token,
          title: detail.title,
          titleJpn: titleJpn,
          thumbUrl: detail.thumbUrl,
          category: detail.category,
          uploader: detail.uploader,
          postedAt: detail.postedAt,
          parent: detail.parent,
          visible: detail.visible,
          language: detail.language,
          fileCount: detail.fileCount,
          fileSize: detail.fileSize,
          rating: detail.rating,
          ratingCount: detail.ratingCount,
          favoriteCount: detail.favoriteCount,
          favoritedSlot: detail.favoritedSlot,
          tags: detail.tags,
          comments: detail.comments,
          thumbnails: detail.thumbnails,
          archiveUrl: detail.archiveUrl,
        );
      }
    }
    return detail;
  }

  /// Fetch Japanese title for a single gallery via gdata API.
  Future<String?> _fetchTitleJpnFromApi(
    int gid,
    String token, {
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post(
        ApiEndpoints.apiEndpoint,
        cancelToken: cancelToken,
        data: {
          'method': 'gdata',
          'gidlist': [
            [gid, token]
          ],
          'namespace': 1,
        },
      );
      final json = jsonDecode(response);
      final list = json['gmetadata'] as List?;
      if (list != null && list.isNotEmpty) {
        return list[0]['title_jpn'] as String?;
      }
    } catch (e) {
      _log.w('Failed to fetch title_jpn from gdata API: $e');
    }
    return null;
  }

  /// Fetch thumbnail page tokens for a gallery
  Future<ThumbnailResult> fetchThumbnails(
    int gid,
    String token, {
    int page = 0,
    CancelToken? cancelToken,
  }) async {
    final url = ApiEndpoints.galleryThumbnails(gid, token, page: page);
    final html = await _dio.get(url, cancelToken: cancelToken);
    final thumbnails = GalleryDetailParser.parseThumbnails(html);
    final totalPages = GalleryDetailParser.parseThumbnailPageCount(html);
    return ThumbnailResult(thumbnails: thumbnails, totalPages: totalPages);
  }

  /// Fetch actual image URL for a specific page
  Future<GalleryImage> fetchImage(
    String pageToken,
    int gid,
    int pageIndex, {
    CancelToken? cancelToken,
  }) async {
    final url = ApiEndpoints.imagePage(pageToken, gid, pageIndex);
    final html = await _dio.get(url, cancelToken: cancelToken);
    return GalleryImageParser.parse(html, pageIndex);
  }

  /// Re-fetch image URL using the nl (network location) key for server failover.
  /// This requests an alternate image server when the original one fails.
  Future<GalleryImage> fetchImageWithNl(
    String pageToken,
    int gid,
    int pageIndex,
    String nlKey, {
    CancelToken? cancelToken,
  }) async {
    final url =
        '${ApiEndpoints.imagePage(pageToken, gid, pageIndex)}?nl=$nlKey';
    final html = await _dio.get(url, cancelToken: cancelToken);
    return GalleryImageParser.parse(html, pageIndex);
  }

  /// Rate a gallery (requires login)
  /// [rating] is 0.5 to 5.0 in 0.5 increments (sent as 2-10 integer)
  Future<RatingResult> rateGallery(int gid, String token, double rating) async {
    final credentials = await _ensureApiCredentials(gid, token);
    final apiRating = (rating * 2).round().clamp(2, 10);
    final response = await _dio.post(
      ApiEndpoints.apiEndpoint,
      data: {
        'method': 'rategallery',
        'apiuid': credentials.apiUid,
        'apikey': credentials.apiKey,
        'gid': gid,
        'token': token,
        'rating': apiRating,
      },
    );
    // Response: {"rating_avg":4.56,"rating_cnt":123}
    final avgMatch =
        RegExp(r'"rating_avg"\s*:\s*([\d.]+)').firstMatch(response);
    final cntMatch = RegExp(r'"rating_cnt"\s*:\s*(\d+)').firstMatch(response);
    return RatingResult(
      averageRating:
          avgMatch != null ? double.parse(avgMatch.group(1)!) : rating,
      ratingCount: cntMatch != null ? int.parse(cntMatch.group(1)!) : 0,
    );
  }

  /// Post a comment on a gallery (requires login)
  Future<void> postComment(int gid, String token, String comment) async {
    final url = ApiEndpoints.galleryComment(gid, token);
    await _dio.post(url, data: {
      'commenttext_new': comment,
    });
  }

  /// Vote on a comment (requires login)
  Future<void> voteComment(
      int gid, String token, int commentId, bool isUpvote) async {
    final credentials = await _ensureApiCredentials(gid, token);
    await _dio.post(
      ApiEndpoints.apiEndpoint,
      data: {
        'method': 'votecomment',
        'apiuid': credentials.apiUid,
        'apikey': credentials.apiKey,
        'gid': gid,
        'token': token,
        'comment_id': commentId,
        'comment_vote': isUpvote ? 1 : -1,
      },
    );
  }

  Future<_ApiCredentials> _ensureApiCredentials(
    int gid,
    String token,
  ) async {
    final cached = _apiCredentials[gid];
    if (cached != null) return cached;

    final html = await _dio.get(ApiEndpoints.galleryDetail(gid, token));
    _cacheApiCredentials(gid, html);
    final credentials = _apiCredentials[gid];
    if (credentials == null) {
      throw StateError(
        'The logged-in session did not provide API credentials.',
      );
    }
    return credentials;
  }

  void _cacheApiCredentials(int gid, String html) {
    final uidMatch = RegExp(r'apiuid\s*=\s*(-?\d+)').firstMatch(html);
    final keyMatch = RegExp(
      r'''apikey\s*=\s*["']([^"']+)["']''',
    ).firstMatch(html);
    final apiUid = int.tryParse(uidMatch?.group(1) ?? '');
    final apiKey = keyMatch?.group(1);
    if (apiUid != null && apiUid >= 0 && apiKey != null && apiKey.isNotEmpty) {
      _apiCredentials[gid] = _ApiCredentials(apiUid, apiKey);
    }
  }

  /// Fetch hidden tags from the user's My Tags page
  Future<List<String>> fetchMyTags() async {
    final html = await _dio.get(ApiEndpoints.myTags);
    return MyTagsParser.parseHiddenTags(html);
  }
}

class _ApiCredentials {
  final int apiUid;
  final String apiKey;

  const _ApiCredentials(this.apiUid, this.apiKey);
}

class GalleryListResult {
  final List<GalleryPreview> galleries;
  final int totalPages;
  final String? nextPageUrl;

  const GalleryListResult({
    required this.galleries,
    required this.totalPages,
    this.nextPageUrl,
  });
}

class ThumbnailResult {
  final List<ThumbnailInfo> thumbnails;
  final int totalPages;

  const ThumbnailResult({
    required this.thumbnails,
    required this.totalPages,
  });
}

class RatingResult {
  final double averageRating;
  final int ratingCount;

  const RatingResult({
    required this.averageRating,
    required this.ratingCount,
  });
}
