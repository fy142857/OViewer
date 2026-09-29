import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/utils/title_extractor.dart';

void main() {
  group('TitleExtractor.similarSearchQuery', () {
    test('treats title operators and short words as a title phrase', () {
      expect(
          TitleExtractor.similarSearchQuery(
              '[Author] Buzama Joushiki Kaihen ~Okorase Kyousei Hatsujou~ [English]'),
          'title:"Buzama Joushiki Kaihen ~Okorase Kyousei Hatsujou~"');
      expect(
          TitleExtractor.similarSearchQuery(
              'My Title -Side Story- artist:test'),
          'title:"My Title -Side Story- artist:test"');
      expect(TitleExtractor.similarSearchQuery('A to B'), 'title:"A to B"');
    });
    test('embedded quotes cannot terminate the generated title query', () {
      expect(TitleExtractor.similarSearchQuery('My "Title" -language:english'),
          'title:"My Title -language:english"');
      expect(TitleExtractor.similarSearchQuery('  中文\n標題  '), 'title:"中文 標題"');
    });
    test(
        'does not turn bracket-only or empty titles into an unrestricted search',
        () {
      expect(TitleExtractor.similarSearchQuery('[Title]'), 'title:"[Title]"');
      expect(TitleExtractor.similarSearchQuery(''), isEmpty);
      expect(TitleExtractor.similarSearchQuery(' " " '), isEmpty);
    });
  });
  group('TitleExtractor.extractCoreTitle', () {
    test(
        'strips leading convention + circle/author and trailing origin + language',
        () {
      expect(
        TitleExtractor.extractCoreTitle(
          '(C103) [Garyuuchitai (TANA)] Defeated Magical Warrior Reika... (Original) [English]',
        ),
        'Defeated Magical Warrior Reika...',
      );
    });

    test('strips leading author with nested parens and trailing tags', () {
      expect(
        TitleExtractor.extractCoreTitle(
          '[JK-Pasta (Kurata Muto)] Jinkaku Haisetsu!! Idol JK Oni Acme 4 [Spanish] [MTL] [Digital]',
        ),
        'Jinkaku Haisetsu!! Idol JK Oni Acme 4',
      );
    });

    test('returns title unchanged when no brackets', () {
      expect(
        TitleExtractor.extractCoreTitle('Simple Title'),
        'Simple Title',
      );
    });

    test('handles multiple trailing bracket groups', () {
      expect(
        TitleExtractor.extractCoreTitle(
          '(C99) [Author] Title With Dots... [Chinese] [Digital]',
        ),
        'Title With Dots...',
      );
    });

    test('handles empty string', () {
      expect(TitleExtractor.extractCoreTitle(''), '');
    });

    test('handles title that is all brackets', () {
      expect(TitleExtractor.extractCoreTitle('(C99) [Author]'), '');
    });
  });
}
