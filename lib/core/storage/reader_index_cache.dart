import '../../models/reader_index_page.dart';

/// Completed index metadata only. Futures, full-image URLs and cancellation
/// tokens never cross sessions. Reads do not extend the expiry time.
class ReaderIndexCache {
  static final shared = ReaderIndexCache();
  final DateTime Function() _now;
  final Duration ttl;
  final int capacity;
  final _entries = <(String, int, String), Map<int, _Page>>{};
  int generation = 0;

  ReaderIndexCache({
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 10),
    this.capacity = 20,
  })  : assert(capacity > 0),
        _now = now ?? DateTime.now;

  ReaderIndexPage? get(String site, int gid, String token, int page) {
    final key = (site, gid, token);
    final pages = _entries.remove(key);
    if (pages == null) return null;
    pages.removeWhere((_, value) => !value.expires.isAfter(_now()));
    if (pages.isEmpty) return null;
    _entries[key] = pages;
    return pages[page]?.value;
  }

  void put(String site, int gid, String token, ReaderIndexPage page) {
    final key = (site, gid, token);
    final pages = _entries.remove(key) ?? <int, _Page>{};
    if (pages.values.any((p) =>
        p.value.pageSize != page.pageSize ||
        p.value.totalPages != page.totalPages)) pages.clear();
    pages[page.indexPage] = _Page(page, _now().add(ttl));
    _entries[key] = pages;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(String site, int gid, String token, int page) {
    _entries[(site, gid, token)]?.remove(page);
  }

  void clear() {
    generation++;
    _entries.clear();
  }
}

class _Page {
  final ReaderIndexPage value;
  final DateTime expires;
  _Page(this.value, this.expires);
}
