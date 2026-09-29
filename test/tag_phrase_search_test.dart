import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/utils/tag_autocomplete.dart';
import 'package:oviewer/repositories/tag_translation_repository.dart';

class MockDio extends Mock implements DioClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TagTranslationRepository repo;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'eh_tag_translations_cache': jsonEncode({
        'data': [
          {
            'namespace': 'artist',
            'data': {
              for (var i = 0; i < 40; i++) 'early $i last': {'name': '末尾 $i'},
              'very long last': {'name': '完整 标签'},
              'nanao yukiji': {'name': '七尾 雪路'},
              'moxueyin | jiuxueran': {'name': '墨雪吟'},
            }
          },
          {
            'namespace': 'group',
            'data': {
              'very long last extra': {'name': '完整 标签 额外'},
            }
          },
        ],
      }),
    });
    final storage = LocalStorage();
    await storage.init();
    final dio = MockDio();
    when(() => dio.get(any()))
        .thenAnswer((_) async => throw StateError('offline'));
    repo = TagTranslationRepository(dio, storage);
    await repo.loadTranslations();
  });

  test('longest phrase wins even beyond the first 20 short matches', () {
    final result = repo.searchPhrases(
        ['unrelated very long last', 'very long last', 'long last', 'last'])!;
    expect(result.queryIndex, 1);
    expect(result.tags.map((t) => t.fullTag),
        ['artist:very long last', 'group:very long last extra']);
  });

  test('batch matching preserves replacement, order, aliases and boundaries',
      () {
    for (final text in [
      'nanao yukiji',
      'other NANAO  YUKI',
      '完整 标签',
      'jiuxueran',
      'language:chinese keep nanao yukiji',
      'very long last',
      'nothing matches',
      'last',
      'artist:"nanao yukiji\$"',
      'nanao yukiji ',
      '${List.filled(96, 'unrelated').join(' ')} nanao yukiji',
    ]) {
      for (final cursor in [text.length, text.length ~/ 2]) {
        final value = TextEditingValue(
            text: text, selection: TextSelection.collapsed(offset: cursor));
        final legacy = tagSuggestions(value, repo.searchByTranslation);
        var scans = 0;
        final batched = tagSuggestions(value, repo.searchByTranslation,
            searchPhrases: (queries) {
          scans++;
          return repo.searchPhrases(queries);
        });
        expect(batched.map((s) => s.apply()).toList(),
            legacy.map((s) => s.apply()).toList(),
            reason: '$text at $cursor');
        expect(scans, lessThanOrEqualTo(1));
      }
    }
  });

  test('explicit selection and composition retain existing rules', () {
    const text = 'prefix nanao yukiji suffix';
    const value = TextEditingValue(
        text: text, selection: TextSelection(baseOffset: 7, extentOffset: 19));
    expect(
        tagSuggestions(value, repo.searchByTranslation,
                searchPhrases: repo.searchPhrases)
            .single
            .apply()
            .text,
        'prefix artist:"nanao yukiji\$" suffix');
    expect(
        tagSuggestions(
            value.copyWith(composing: const TextRange(start: 7, end: 19)),
            repo.searchByTranslation,
            searchPhrases: repo.searchPhrases),
        isEmpty);
  });
}
