import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/utils/tag_autocomplete.dart';
import 'package:oviewer/repositories/tag_translation_repository.dart';

const artist = TagSearchResult(
  namespace: 'artist',
  key: 'nanao yukiji',
  translation: '七尾 雪路',
);

List<TagSearchResult> search(String query) =>
    artist.key.contains(query.toLowerCase()) ||
            artist.translation.contains(query)
        ? [artist]
        : [];

void main() {
  test('history candidates preserve recency and ignore case/extra whitespace',
      () {
    expect(
        matchingSearchHistory('NANAO  YUKI', [
          'unrelated',
          'nanao yukiji language:chinese',
          r'artist:"nanao yukiji$"',
          'NANAO   YUKIJI language:chinese',
        ]),
        ['nanao yukiji language:chinese', r'artist:"nanao yukiji$"']);
    expect(matchingSearchHistory('', ['nanao']), isEmpty);
    expect(matchingSearchHistory('missing', ['nanao']), isEmpty);
  });

  test('alias suggestions insert only the canonical tag', () {
    const text = 'jiuxueran';
    final results = tagSuggestions(
        const TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length)),
        (_) => [
              const TagSearchResult(
                  namespace: 'artist',
                  key: 'moxueyin | jiuxueran',
                  translation: '墨雪吟')
            ]);
    expect(results.single.apply().text, 'artist:"moxueyin\$" ');
  });
  for (final phrase in [
    'nanao yukiji',
    'nanao yuki',
    'NANAO YUKIJI',
    'nanao   yukiji',
    'nanao\tyukiji',
    'nanao\u00a0yukiji',
    '七尾 雪路',
    'yukiji',
  ]) {
    test('replaces the whole matching phrase: $phrase', () {
      final value = TextEditingValue(
          text: phrase,
          selection: TextSelection.collapsed(offset: phrase.length));
      final result = tagSuggestions(value, search).single.apply();
      expect(result.text, 'artist:"nanao yukiji\$" ');
      expect(result.selection.extentOffset, result.text.length);
      expect(result.composing, TextRange.empty);
    });
  }

  test('preserves unrelated words and existing quoted filters', () {
    const prefix = 'language:"chinese\$" unrelated ';
    const text = '${prefix}nanao yukiji';
    final result = tagSuggestions(
            const TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length)),
            search)
        .single
        .apply();
    expect(result.text, '${prefix}artist:"nanao yukiji\$" ');
  });

  test('edits at the caret and preserves following filters', () {
    const text = 'other nanao yukiji language:english';
    final cursor = text.indexOf(' language:');
    final result = tagSuggestions(
            TextEditingValue(
                text: text, selection: TextSelection.collapsed(offset: cursor)),
            search)
        .single
        .apply();
    expect(result.text, 'other artist:"nanao yukiji\$" language:english');
    expect(
        result.selection.extentOffset, 'other artist:"nanao yukiji\$"'.length);
  });

  test('replaces the complete active word when the caret is inside it', () {
    const text = 'nanao yukiji';
    final result = tagSuggestions(
            const TextEditingValue(
                text: text, selection: TextSelection.collapsed(offset: 9)),
            search)
        .single
        .apply();
    expect(result.text, 'artist:"nanao yukiji\$" ');
  });

  test('explicit selection defines the replacement range', () {
    const text = 'keep nanao yukiji suffix';
    final result = tagSuggestions(
            const TextEditingValue(
                text: text,
                selection: TextSelection(baseOffset: 5, extentOffset: 17)),
            search)
        .single
        .apply();
    expect(result.text, 'keep artist:"nanao yukiji\$" suffix');
  });

  test('completed filters, whitespace, empty input and IME are not replaced',
      () {
    for (final text in [
      '',
      'nanao yukiji ',
      'artist:"nanao yukiji\$"',
      '-nanao',
      '~nanao',
      '"nanao yukiji"'
    ]) {
      expect(
          tagSuggestions(
              TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: text.length)),
              search),
          isEmpty,
          reason: text);
    }
    expect(
        tagSuggestions(
            const TextEditingValue(
                text: 'nanao',
                selection: TextSelection.collapsed(offset: 5),
                composing: TextRange(start: 0, end: 5)),
            search),
        isEmpty);
  });
}
