import '../core/network/dio_client.dart';
import '../core/parser/search_parser.dart';
import '../core/storage/local_storage.dart';
import '../core/utils/tag_search_query.dart';
import '../models/gallery_preview.dart';
import '../models/search_filter.dart';
import '../core/constants/app_constants.dart';

class SearchRepository {
  final DioClient _dio;
  final LocalStorage _storage;

  SearchRepository(this._dio, this._storage);

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
    final url = nextUrl != null ? _resolve(nextUrl) : _buildSearchUrl(filter, page);
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

class SearchResult {
  final List<GalleryPreview> galleries;
  final int totalPages;
  final int totalResults;
  final String? nextPageUrl;

  const SearchResult({
    required this.galleries,
    required this.totalPages,
    required this.totalResults,
    this.nextPageUrl,
  });
}
