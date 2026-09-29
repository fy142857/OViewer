import 'dart:convert';
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
    final alternatives = _titleAlternatives(filter.keyword ?? '');
    if (alternatives.length > 1) {
      return _searchTitleAlternatives(filter, alternatives, page, nextUrl);
    }
    if (alternatives.length == 1) {
      return _searchSingle(filter.copyWith(keyword: alternatives.single),
          page: page, nextUrl: nextUrl);
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

  // Accept both generated OR chains and pasted/old bilingual title queries.
  // A pipe inside title quotes separates alternatives, not a literal phrase.
  List<String> _titleAlternatives(String query) {
    if (!RegExp(r'^title:"[^"]+"(?: OR title:"[^"]+")*$')
        .hasMatch(query.trim())) {
      return [];
    }
    return RegExp(r'title:"([^"]+)"')
        .allMatches(query)
        .expand((m) => m[1]!.split(RegExp(r'[|｜]')))
        .map((title) => title.trim())
        .where((title) => title.isNotEmpty)
        .map((title) => 'title:"$title"')
        .toSet()
        .toList();
  }

  static const _unionCursorPrefix = 'oviewer-title-union:';

  Future<SearchResult> _searchTitleAlternatives(SearchFilter filter,
      List<String> queries, int page, String? cursor) async {
    final seen = <int>{};
    var urls = queries
        .map((query) => _buildSearchUrl(filter.copyWith(keyword: query), 0))
        .toList();
    if (cursor != null) {
      if (!cursor.startsWith(_unionCursorPrefix)) {
        throw const FormatException('Invalid title search cursor');
      }
      final saved = jsonDecode(utf8.decode(
              base64Url.decode(cursor.substring(_unionCursorPrefix.length))))
          as Map<String, dynamic>;
      if (saved['site'] != AppConstants.baseUrl ||
          saved['query'] != filter.keyword) {
        throw const FormatException(
            'Title search cursor belongs to another search');
      }
      urls = List<String>.from(saved['urls'] as List);
      seen.addAll(List<int>.from(saved['seen'] as List));
    }
    final results = <GalleryPreview>[];
    final visited = <String>{};
    // A page consisting entirely of duplicates must not end pagination while
    // either title still has another page. Work locally until a batch succeeds,
    // so retry after a failure never advances the caller's cursor.
    while (urls.isNotEmpty && results.isEmpty) {
      final next = <String>[];
      for (final url in urls) {
        if (!visited.add(url)) {
          throw const FormatException('Repeated title search cursor');
        }
        final result = await _searchSingle(filter, nextUrl: url);
        for (final gallery in result.galleries) {
          if (seen.add(gallery.gid)) results.add(gallery);
        }
        if (result.nextPageUrl != null) next.add(_resolve(result.nextPageUrl!));
      }
      urls = next.toSet().toList();
    }
    results.sort((a, b) => b.gid.compareTo(a.gid));
    final nextCursor = urls.isEmpty
        ? null
        : _unionCursorPrefix +
            base64Url.encode(utf8.encode(jsonEncode({
              'site': AppConstants.baseUrl,
              'query': filter.keyword,
              'urls': urls,
              'seen': seen.toList(),
            })));
    // There is no exact combined total until both streams are exhausted.
    return SearchResult(
        galleries: results,
        totalPages: page + 1,
        totalResults: urls.isEmpty ? seen.length : 0,
        nextPageUrl: nextCursor);
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
