import 'dart:convert';
import '../../models/gallery_preview.dart';
import '../../models/search_result.dart';
import 'uploader_search_query.dart';

// Accept both generated OR chains and pasted/old bilingual title queries.
// A pipe inside title quotes separates alternatives, not a literal phrase.
List<String> titleSearchAlternatives(String query) {
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

List<String> expandSearchQueries(String keyword) {
  final titles = titleSearchAlternatives(keyword);
  if (titles.isNotEmpty) return titles;
  final uploader = plainUploaderSearchQuery(keyword);
  return [keyword, if (uploader != null) uploader];
}

Future<SearchResult> mergeSearchResults({
  required List<String> initialUrls,
  required Map<String, Object?> scope,
  required String cursorPrefix,
  required Future<SearchResult> Function(String) loadPage,
  required String Function(String) resolveNext,
  String? cursor,
  int page = 0,
}) async {
  final seen = <int>{};
  var urls = List<String>.from(initialUrls);
  if (cursor != null) {
    if (!cursor.startsWith(cursorPrefix)) {
      throw const FormatException('Invalid combined search cursor');
    }
    final saved = jsonDecode(utf8
            .decode(base64Url.decode(cursor.substring(cursorPrefix.length))))
        as Map<String, dynamic>;
    if (scope.entries.any((e) => saved[e.key] != e.value)) {
      throw const FormatException(
          'Combined search cursor belongs to another search');
    }
    urls = List<String>.from(saved['urls'] as List);
    seen.addAll(List<int>.from(saved['seen'] as List));
  }
  final results = <GalleryPreview>[];
  final visited = <String>{};
  // A page consisting entirely of duplicates must not end pagination while
  // either source still has another page. Work locally until a batch succeeds,
  // so retry after a failure never advances the caller's cursor.
  while (urls.isNotEmpty && results.isEmpty) {
    final next = <String>[];
    for (final url in urls) {
      if (!visited.add(url)) {
        throw const FormatException('Repeated combined search cursor');
      }
      final result = await loadPage(url);
      for (final gallery in result.galleries) {
        if (seen.add(gallery.gid)) results.add(gallery);
      }
      if (result.nextPageUrl != null)
        next.add(resolveNext(result.nextPageUrl!));
    }
    urls = next.toSet().toList();
  }
  results.sort((a, b) => b.gid.compareTo(a.gid));
  final nextCursor = urls.isEmpty
      ? null
      : cursorPrefix +
          base64Url.encode(utf8.encode(jsonEncode({
            ...scope,
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
