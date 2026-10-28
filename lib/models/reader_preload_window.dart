import 'reader_page_layout.dart';

/// Original page indices, regardless of direction or presentation layout.
class ReaderPreloadWindow {
  ReaderPreloadWindow(ReaderSpreads spreads, int currentPage, int count,
      {Set<int> visiblePages = const {}, bool expandAroundVisible = true}) {
    if (spreads.totalPages <= 0) return;
    final visibleSpreads = visiblePages
        .where((p) => p >= 0 && p < spreads.totalPages)
        .map(spreads.spreadOf)
        .toSet();
    if (visibleSpreads.isEmpty) {
      visibleSpreads
          .add(spreads.spreadOf(currentPage.clamp(0, spreads.totalPages - 1)));
    }
    final ordered = visibleSpreads.toList()..sort();
    for (var group = ordered.first; group <= ordered.last; group++) {
      visible.addAll(spreads.pages(group));
    }
    final focus =
        spreads.spreadOf(currentPage.clamp(0, spreads.totalPages - 1));
    final firstGroup = expandAroundVisible ? ordered.first : focus;
    final lastGroup = expandAroundVisible ? ordered.last : focus;
    for (var distance = 1; distance <= count.clamp(1, 5); distance++) {
      for (final group in [lastGroup + distance, firstGroup - distance]) {
        if (group >= 0 && group < spreads.count) {
          neighbours.addAll(
              spreads.pages(group).where((page) => !visible.contains(page)));
        }
      }
    }
    targets.addAll([...visible, ...neighbours]);
    final first = visible.first;
    final last = visible.last;
    addresses.addAll(targets);
    // Keep the inexpensive address look-ahead even when only one image/group
    // is requested. A group can contain two original pages.
    for (var distance = 1; distance <= 3; distance++) {
      for (final page in [last + distance, first - distance]) {
        if (page >= 0 && page < spreads.totalPages) addresses.add(page);
      }
    }
  }

  final Set<int> visible = {};
  final List<int> neighbours = [];
  final Set<int> targets = {};
  final Set<int> addresses = {};
}
