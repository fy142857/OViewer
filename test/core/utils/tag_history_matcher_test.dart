import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/utils/tag_autocomplete.dart';
import 'package:oviewer/core/utils/tag_history_matcher.dart';

const names = {
  'artist': {
    'nanao yukiji | pen name': '七尾雪路（七尾ゆきじ）',
    'peko': 'ぺこ（かにビーム）',
    'shared': '作者同名',
  },
  'character': {'shared': '角色同名'},
  'language': {'chinese': '中文'},
};

void main() {
  late TagHistoryMatcher aliases;
  setUp(() => aliases = TagHistoryMatcher(names));

  for (final saved in [
    r'artist:"nanao yukiji$"',
    r'artist:"nanao yukiji | pen name$"',
    'nanao yukiji',
    '七尾雪路',
    '七尾ゆきじ',
    'pen name',
  ]) {
    test('English/Chinese/Japanese aliases recall original history: $saved',
        () {
      for (final input in [
        'NANAO  YUKI',
        'nanao yukiji',
        '七尾雪',
        '七尾ゆき',
        'pen name'
      ]) {
        expect(matchingSearchHistory(input, [saved], aliases: aliases), [saved],
            reason: input);
      }
    });
  }

  test(
      'namespace, quoted filters and modifier are respected for alias matching',
      () {
    const saved = r'a:"nanao yukiji$" language:chinese';
    expect(aliases.match('artist:七尾 中文', [saved]), [saved]);
    expect(aliases.match('artist:七尾 language:english', [saved]), isEmpty);
    expect(aliases.match('character:七尾', [saved]), isEmpty);
    expect(aliases.match('artist:角色同名', [r'character:"shared$"']), isEmpty);
    expect(aliases.match('artist:作者同名', [r'character:"shared$"']), isEmpty);
    expect(aliases.match('artist:七尾', [r'-artist:"nanao yukiji$"']), isEmpty);
    expect(aliases.match('-artist:七尾', [r'-artist:"nanao yukiji$"']),
        [r'-artist:"nanao yukiji$"']);
    expect(aliases.match(r'artist:"nanao yuki$"', [saved]), isEmpty);
    expect(
        aliases.match(
            'artist:七尾', [r'uploader:"nanao yukiji"', r'title:"nanao yukiji"']),
        isEmpty);
    expect(
        aliases
            .match('七尾', [r'uploader:"nanao yukiji"', r'title:"nanao yukiji"']),
        isEmpty);
    expect(aliases.match('uploader:nanao', ['uploader:nanao']),
        ['uploader:nanao']);
  });

  test('name-field parenthesized aliases work in either direction', () {
    expect(aliases.match('かに', [r'artist:"peko$"']), [r'artist:"peko$"']);
    expect(aliases.match('peko', ['かにビーム']), ['かにビーム']);
  });

  test('generic and weak tag queries retain their qualifier semantics', () {
    const saved = r'tag:"nanao yukiji$"';
    expect(aliases.match('七尾', [saved]), [saved]);
    expect(aliases.match('tag:七尾', [r'artist:"nanao yukiji$"']),
        [r'artist:"nanao yukiji$"']);
    expect(aliases.match('artist:七尾', [saved]), [saved]);
    expect(aliases.match('weak:七尾', [r'weak:artist:"nanao yukiji$"']),
        [r'weak:artist:"nanao yukiji$"']);
    expect(aliases.match('weak:artist:七尾', [r'weak:"nanao yukiji$"']),
        [r'weak:"nanao yukiji$"']);
    expect(aliases.match('weak:七尾', [saved]), isEmpty);
  });

  test(
      'preserves recency, spelling, filters and literal matching without duplicates',
      () {
    final history = [
      'unrelated',
      '七尾ゆきじ language:chinese',
      r'artist:"nanao yukiji$"',
      r'ARTIST:"NANAO   YUKIJI$"',
      'nanao yukiji'
    ];
    expect(aliases.match('七尾', history),
        ['七尾ゆきじ language:chinese', r'artist:"nanao yukiji$"', 'nanao yukiji']);
    expect(aliases.match('', history), isEmpty);
    expect(aliases.match('unrel', history), ['unrelated']);
    expect(aliases.match('七尾', [history[2]]), [history[2]]);
    expect(aliases.match('七尾', []), isEmpty);
    expect(aliases.match('七尾', [history[4], history[2]]),
        [history[4], history[2]]);
    expect(matchingSearchHistory('七尾', history), ['七尾ゆきじ language:chinese']);
  });

  test(
      'history matches are not capped by the first twenty dictionary suggestions',
      () {
    final matcher = TagHistoryMatcher({
      'artist': {
        for (var i = 0; i < 100; i++) 'author $i': '作者$i',
      }
    });
    final history = [for (var i = 99; i >= 0; i--) 'artist:"author $i\$"'];
    expect(matcher.match('作者', history), history);
    expect(matcher.match('作者99', history), [history.first]);
  });
}
