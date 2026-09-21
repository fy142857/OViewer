import '../core/parser/gallery_detail_parser.dart';

/// One HTML index page; [totalPages] counts manga images, not index pages.
class ReaderIndexPage {
  final int totalPages;
  final int indexPage;
  final int indexPageCount;
  final int pageSize;
  final Map<int, ThumbnailInfo> thumbnails;

  ReaderIndexPage({
    required this.totalPages,
    required this.indexPage,
    required this.indexPageCount,
    required this.pageSize,
    required Map<int, ThumbnailInfo> thumbnails,
  }) : thumbnails = Map.unmodifiable(thumbnails);
}
