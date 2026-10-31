import 'reader_page_layout.dart';

/// Original page indices, regardless of direction or presentation layout.
class ReaderPreloadWindow {
  // Build-time override is used by the isolated device benchmark, never a
  // second user preference. The unit follows the current page/spread layout.
  static const _addressLeadOverride =
      int.fromEnvironment('READER_ADDRESS_LEAD', defaultValue: -1);

  static int addressLeadForCount(int count) {
    if (_addressLeadOverride >= 0) return _addressLeadOverride.clamp(0, 4);
    // Larger image windows already provide enough time for link requests.
    // See READER_PRELOAD_VALIDATION.md for the measured 1/2/3-group comparison.
    return count.clamp(1, 5) <= 3 ? 2 : 1;
  }

  ReaderPreloadWindow(ReaderSpreads spreads, int currentPage, int count,
      {Set<int> visiblePages = const {},
      bool expandAroundVisible = true,
      int? addressLead}) {
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
    addresses.addAll(targets);
    final lead = addressLead ?? addressLeadForCount(count);
    for (var distance = 1; distance <= lead.clamp(0, 4); distance++) {
      for (final group in [
        lastGroup + count.clamp(1, 5) + distance,
        firstGroup - count.clamp(1, 5) - distance
      ]) {
        if (group >= 0 && group < spreads.count) {
          addresses.addAll(spreads.pages(group));
        }
      }
    }
  }

  final Set<int> visible = {};
  final List<int> neighbours = [];
  final Set<int> targets = {};
  final Set<int> addresses = {};
}
