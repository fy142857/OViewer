import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/models/download_range.dart';

void main() {
  test('directory parts are deduplicated at boundaries without scanning gaps', () {
    expect(DownloadRange.parse('20-21,40,401-402', 1000).indexParts(1000, 20), [0, 1, 20]);
    expect(const DownloadRange.all().indexParts(45, 20), [0, 1, 2]);
    expect(() => DownloadRange.parse('100', 100).indexParts(50, 20), throwsArgumentError);
  });
  test('normalizes multiple ranges, duplicates and Chinese commas', () {
    final range = DownloadRange.parse(' 8-10， 2, 1-3, 7, 3-5 ', 10);
    expect(range.label, '1-5, 7-10');
    expect(range.count(10), 9);
    expect(range.contains(5), false);
    expect(range.contains(6), true);
    expect(range.contains(-1), false);
    expect(DownloadRange.fromStorage(range.toStorage()).label, range.label);
  });
  test('union is idempotent and all absorbs partial selections', () {
    final first = DownloadRange.parse('2-4', 10);
    expect(first.union(first).toStorage(), first.toStorage());
    expect(first.union(DownloadRange.parse('5,8', 10)).label, '2-5, 8');
    expect(first.union(const DownloadRange.all()).isAll, true);
    expect(DownloadRange.fromStorage(null).count(23), 23);
  });
  for (final value in [
    '',
    '0',
    '-1',
    '11',
    '5-3',
    '1,,2',
    '1.5',
    '1-',
    '1-2-3',
    '1 2',
    '99999999999999999999999999999'
  ]) {
    test('rejects invalid selection "$value"', () {
      expect(() => DownloadRange.parse(value, 10), throwsFormatException);
    });
  }
  test('range remains explicit when gallery size changes', () {
    final range = DownloadRange.parse('3-10', 10);
    expect(range.validFor(8), false);
    expect(range.validFor(12), true);
    expect(range.count(12), 8);
    expect(range.firstPage, 2);
    expect(const DownloadRange.all().validFor(0), false);
  });
  for (final value in ['[]', '{}', '[[3,2]]', '[[-1,2]]', '[[1,"2"]]']) {
    test('fails closed for malformed stored range $value', () {
      expect(() => DownloadRange.fromStorage(value), throwsFormatException);
    });
  }
}
