import 'dart:convert';

/// Normalized, inclusive, zero-based page intervals. Null storage means all.
class DownloadRange {
  final List<(int, int)>? _intervals;
  const DownloadRange.all() : _intervals = null;
  DownloadRange._(Iterable<(int, int)> intervals)
      : _intervals = List.unmodifiable(intervals);

  bool get isAll => _intervals == null;
  int get firstPage => _intervals?.first.$1 ?? 0;

  factory DownloadRange.parse(String input, int totalPages) {
    if (input.trim().isEmpty) throw const FormatException('range_empty');
    final intervals = <(int, int)>[];
    for (final part in input.replaceAll('，', ',').split(',')) {
      final match = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+)\s*)?$').firstMatch(part);
      if (match == null) throw const FormatException('range_format');
      final first = int.tryParse(match[1]!);
      final last = int.tryParse(match[2] ?? match[1]!);
      if (first == null || last == null || first < 1 || last > totalPages) {
        throw const FormatException('range_bounds');
      }
      if (first > last) throw const FormatException('range_order');
      intervals.add((first - 1, last - 1));
    }
    return DownloadRange._normalized(intervals);
  }

  factory DownloadRange._normalized(List<(int, int)> intervals) {
    intervals.sort((a, b) => a.$1.compareTo(b.$1));
    final result = <(int, int)>[];
    for (final interval in intervals) {
      if (result.isNotEmpty && interval.$1 <= result.last.$2 + 1) {
        final old = result.removeLast();
        result.add((old.$1, old.$2 > interval.$2 ? old.$2 : interval.$2));
      } else {
        result.add(interval);
      }
    }
    return DownloadRange._(result);
  }

  factory DownloadRange.fromStorage(String? value) {
    if (value == null) return const DownloadRange.all();
    final decoded = jsonDecode(value);
    if (decoded is! List || decoded.isEmpty) {
      throw const FormatException('range_format');
    }
    final intervals = <(int, int)>[];
    for (final pair in decoded) {
      if (pair is! List ||
          pair.length != 2 ||
          pair[0] is! int ||
          pair[1] is! int ||
          pair[0] < 0 ||
          pair[1] < pair[0]) {
        throw const FormatException('range_format');
      }
      intervals.add((pair[0] as int, pair[1] as int));
    }
    return DownloadRange._normalized(intervals);
  }

  String? toStorage() => _intervals == null
      ? null
      : jsonEncode(_intervals!.map((r) => [r.$1, r.$2]).toList());
  bool validFor(int total) =>
      total > 0 && (_intervals == null || _intervals!.last.$2 < total);
  bool contains(int page) =>
      page >= 0 &&
      (_intervals == null ||
          _intervals!.any((r) => page >= r.$1 && page <= r.$2));
  int count(int total) => _intervals == null
      ? total
      : _intervals!.fold(0, (n, r) => n + r.$2 - r.$1 + 1);
  DownloadRange union(DownloadRange other) => isAll || other.isAll
      ? const DownloadRange.all()
      : DownloadRange._normalized([..._intervals!, ...other._intervals!]);
  String get label =>
      _intervals
          ?.map((r) => r.$1 == r.$2 ? '${r.$1 + 1}' : '${r.$1 + 1}-${r.$2 + 1}')
          .join(', ') ??
      '';
}
