import 'package:html/parser.dart' as html_parser;
import '../core/network/dio_client.dart';
import '../core/parser/search_parser.dart';
import '../core/storage/local_storage.dart';
import '../core/utils/tag_search_query.dart';
import '../core/utils/uploader_search_query.dart';
import '../core/utils/search_queries.dart';
import '../models/search_result.dart';
export '../models/search_result.dart';
import '../models/gallery_preview.dart';
import '../models/search_filter.dart';
import '../core/constants/app_constants.dart';

class SearchRepository {
  final DioClient _dio;
  final LocalStorage _storage;

  SearchRepository(this._dio, this._storage);

  /// Only positive ASCII integers with room for the exclusive list cursor.
  static int? parseGid(String keyword) {
    final text = keyword.trim();
    if (!RegExp(r'^[0-9]+$').hasMatch(text)) return null;
    final gid = int.tryParse(text);
    return gid != null && gid > 0 && gid < 0x7fffffffffffffff ? gid : null;
  }

  /// Locate a visible gallery on the current site without search-page filters.
  /// `next` is exclusive; never substitute an adjacent gallery for the target.
  Future<GalleryPreview?> searchByGid(int gid) async {
    if (parseGid('$gid') == null) throw ArgumentError.value(gid, 'gid');
    final site = AppConstants.baseUrl;
    final html = await _dio.get('$site/?f_cats=0&next=${gid + 1}');
    final document = html_parser.parse(html);
    final noHits = document.body?.text.contains('No hits found') == true;
    if (document.querySelector('.itg') == null && !noHits) {
      throw const FormatException('Expected a gallery search results page');
    }
    final galleries = SearchParser.parseResults(html);
    if (galleries.isEmpty && !noHits) {
      throw const FormatException('Could not parse gallery search results');
    }
    for (final gallery in galleries) {
      if (gallery.gid != gid || !RegExp(r'^[a-f0-9]+$').hasMatch(gallery.token))
        continue;
      final validLink = document.querySelectorAll('a[href*="/g/"]').any((link) {
        final uri = Uri.parse(site).resolve(link.attributes['href']!);
        return uri.scheme == 'https' &&
            uri.origin == site &&
            uri.userInfo.isEmpty &&
            uri.path == '/g/$gid/${gallery.token}/';
      });
      if (validLink) return gallery;
      throw const FormatException('Invalid gallery link in GID results');
    }
    return null;
  }

  String _resolve(String url) {
    if (url.startsWith('http')) return url;
    return '${AppConstants.baseUrl}$url';
  }

  /// Search galleries with filter.
  /// Uses [nextUrl] for cursor pagination when loading more results.
  Future<SearchResult> search(
    SearchFilter filter, {
    int page = 0,
    String? nextUrl,
  }) async {
    final alternatives = titleSearchAlternatives(filter.keyword ?? '');
    if (alternatives.length > 1) {
      return _searchAlternatives(filter, alternatives, page, nextUrl);
    }
    if (alternatives.length == 1) {
      return _searchSingle(filter.copyWith(keyword: alternatives.single),
          page: page, nextUrl: nextUrl);
    }
    final uploader = plainUploaderSearchQuery(filter.keyword ?? '');
    if (uploader != null) {
      return _searchAlternatives(
          filter, [filter.keyword!, uploader], page, nextUrl,
          cursorPrefix: 'oviewer-uploader-union:');
    }
    return _searchSingle(filter, page: page, nextUrl: nextUrl);
  }

  Future<SearchResult> _searchSingle(SearchFilter filter,
      {int page = 0, String? nextUrl}) async {
    final url =
        nextUrl != null ? _resolve(nextUrl) : _buildSearchUrl(filter, page);
    final html = await _dio.get(url);
    final results = SearchParser.parseResults(html);
    final totalPages = SearchParser.parsePageCount(html);
    final resultCount = SearchParser.parseResultCount(html);
    final nextPageUrl = SearchParser.parseNextPageUrl(html);
    return SearchResult(
      galleries: results,
      totalPages: totalPages,
      totalResults: resultCount,
      nextPageUrl: nextPageUrl,
    );
  }

  static const _unionCursorPrefix = 'oviewer-title-union:';

  Future<SearchResult> _searchAlternatives(
          SearchFilter filter, List<String> queries, int page, String? cursor,
          {String cursorPrefix = _unionCursorPrefix}) =>
      mergeSearchResults(
        initialUrls: queries
            .map((q) => _buildSearchUrl(filter.copyWith(keyword: q), 0))
            .toList(),
        scope: {
          'site': AppConstants.baseUrl,
          'query': filter.keyword,
          'filter': _buildSearchUrl(filter, 0)
        },
        cursorPrefix: cursorPrefix,
        cursor: cursor,
        page: page,
        loadPage: (url) => _searchSingle(filter, nextUrl: url),
        resolveNext: _resolve,
      );

  /// Get search history
  List<String> getSearchHistory() => _storage.getSearchHistory();

  /// Add to search history
  Future<void> addSearchHistory(String keyword) async {
    final history = _storage.getSearchHistory();
    history.remove(keyword);
    history.insert(0, keyword);
    if (history.length > AppConstants.maxSearchHistory) {
      history.removeRange(AppConstants.maxSearchHistory, history.length);
    }
    await _storage.setSearchHistory(history);
  }

  /// Remove single search history item
  Future<void> removeSearchHistory(String keyword) async {
    final history = _storage.getSearchHistory();
    history.remove(keyword);
    await _storage.setSearchHistory(history);
  }

  /// Clear search history
  Future<void> clearSearchHistory() async {
    await _storage.setSearchHistory([]);
  }

  String _buildSearchUrl(SearchFilter filter, int page) {
    final params = <String>[];

    if (filter.keyword != null && filter.keyword!.isNotEmpty) {
      final keyword = normalizeTagSearchQuery(filter.keyword!);
      params.add('f_search=${Uri.encodeComponent(keyword)}');
    }

    // f_cats excludes categories using fixed site bits, not their UI indices.
    final selected = filter.categories.toSet();
    var excludedBits = 0;
    if (selected.isNotEmpty) {
      for (final entry in AppConstants.categoryBits.entries) {
        if (!selected.contains(entry.key)) {
          excludedBits |= entry.value;
        }
      }
    }
    // Empty/all selections explicitly mean unrestricted categories.
    params.add('f_cats=$excludedBits');

    if (filter.minRating != null) {
      params.add('f_srdd=${filter.minRating}');
      params.add('advsearch=1');
    }

    if (filter.searchGalleryName) params.add('f_sname=on');
    if (filter.searchGalleryTags) params.add('f_stags=on');
    if (filter.searchGalleryDesc) params.add('f_sdesc=on');

    final query = params.isNotEmpty ? '?${params.join('&')}' : '';
    return '${AppConstants.baseUrl}/$query';
  }
}
