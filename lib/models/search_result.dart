import 'gallery_preview.dart';

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
