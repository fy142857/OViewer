enum ReaderPageLayout { single, doublePage }

/// Presentation indices never replace original page indices in storage/network.
class ReaderSpreads {
  const ReaderSpreads(this.totalPages, this.layout);
  final int totalPages;
  final ReaderPageLayout layout;
  int get pagesPerSpread => layout == ReaderPageLayout.single ? 1 : 2;
  int get count => (totalPages + pagesPerSpread - 1) ~/ pagesPerSpread;
  int spreadOf(int page) => page ~/ pagesPerSpread;
  List<int> pages(int spread, {bool reverse = false}) {
    final start = spread * pagesPerSpread;
    final result = [
      for (var p = start; p < start + pagesPerSpread && p < totalPages; p++)
        if (p >= 0) p
    ];
    return reverse ? result.reversed.toList() : result;
  }

  List<int> containing(int page) => pages(spreadOf(page));
  String label(int page) {
    final visible = containing(page);
    if (visible.isEmpty) return '0';
    return visible.length == 1
        ? '${visible.first + 1}'
        : '${visible.first + 1}–${visible.last + 1}';
  }
}
