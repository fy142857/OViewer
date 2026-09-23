import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/utils/tag_search_query.dart';

void main() {
  test('converts alias display text to canonical exact tags', () {
    expect(
        exactTagQuery('artist', 'moxueyin | jiuxueran'), r'artist:"moxueyin$"');
    expect(normalizeTagSearchQuery(r'artist:"moxueyin | jiuxueran$"'),
        r'artist:"moxueyin$"');
    expect(
        normalizeTagSearchQuery(r'a:"moxueyin|jiuxueran"$'), r'a:"moxueyin"$');
    expect(normalizeTagSearchQuery(r'artist:moxueyin|jiuxueran$'),
        r'artist:moxueyin$');
  });

  test('preserves qualifiers, operators, spaces and exact/partial matching',
      () {
    const input = r'language:chinese -artist:"master name | alias$" '
        r'~c:"saber | arturia pendragon$" weak:parody:"master | alias"';
    const expected = r'language:chinese -artist:"master name$" '
        r'~c:"saber$" weak:parody:"master"';
    expect(normalizeTagSearchQuery(input), expected);
    expect(normalizeTagSearchQuery(expected), expected);
  });

  test('does not rewrite titles, free text, uploaders or incomplete tags', () {
    for (final query in [
      r'title:"moxueyin | jiuxueran$"',
      r'uploader:"name | suffix"',
      r'"artist:moxueyin|jiuxueran$"',
      r'moxueyin | jiuxueran',
      r'artist:"moxueyin | jiuxueran',
      r'artist:"moxueyin | $"',
      r'artist:" | jiuxueran$"',
      r'artist:"nanao yukiji$"',
    ]) {
      expect(normalizeTagSearchQuery(query), query);
    }
  });
}
