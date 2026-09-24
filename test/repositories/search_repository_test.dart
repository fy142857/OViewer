import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/search_repository.dart';

class MockDio extends Mock implements DioClient {}

class MockStorage extends Mock implements LocalStorage {}

void main() {
  final originalSite = AppConstants.useExHentai;
  tearDown(() => AppConstants.useExHentai = originalSite);

  for (final ex in [false, true]) {
    // Expected masks are the site's protocol values, independent of UI order.
    final categoryCases = <String, int>{
      'Doujinshi': 1021,
      'Manga': 1019,
      'Artist CG': 1015,
      'Game CG': 1007,
      'Western': 511,
      'Non-H': 767,
      'Image Set': 991,
      'Cosplay': 959,
      'Asian Porn': 895,
      'Misc': 1022,
    };
    final selections = <List<String>, int>{
      for (final entry in categoryCases.entries) [entry.key]: entry.value,
      ['Manga', 'Doujinshi']: 1017,
      ['Doujinshi', 'Manga', 'Manga']: 1017,
      []: 0,
      categoryCases.keys.toList(): 0,
    };
    for (final entry in selections.entries) {
      test('category selection ${entry.key} sends ${entry.value} on '
          '${ex ? "EX" : "EH"}', () async {
        AppConstants.useExHentai = ex;
        final dio = MockDio();
        when(() => dio.get(any())).thenAnswer((_) async => '<html></html>');
        final repo = SearchRepository(dio, MockStorage());

        await repo.search(SearchFilter(
          keyword: 'language:chinese',
          categories: entry.key,
          minRating: 3,
        ));

        final url = Uri.parse(
            verify(() => dio.get(captureAny())).captured.single as String);
        expect(url.host, ex ? 'exhentai.org' : 'e-hentai.org');
        expect(url.queryParameters['f_cats'], '${entry.value}');
        expect(url.queryParameters['f_search'], 'language:chinese');
        expect(url.queryParameters['f_srdd'], '3');
      });
    }

    test('category filter survives cursor pagination on ${ex ? "EX" : "EH"}',
        () async {
      AppConstants.useExHentai = ex;
      final dio = MockDio();
      when(() => dio.get(any())).thenAnswer((_) async => '<html></html>');
      final repo = SearchRepository(dio, MockStorage());
      const cursor = '/?f_cats=1019&f_search=language%3Achinese&next=12345';

      await repo.search(
        const SearchFilter(categories: ['Manga']),
        nextUrl: cursor,
      );

      verify(() => dio.get('${AppConstants.baseUrl}$cursor')).called(1);
    });

    test('alias search sends canonical f_search on ${ex ? "EX" : "EH"}',
        () async {
      AppConstants.useExHentai = ex;
      final dio = MockDio();
      final storage = MockStorage();
      when(() => dio.get(any())).thenAnswer((_) async => '<html></html>');
      final repo = SearchRepository(dio, storage);
      await repo.search(const SearchFilter(
        keyword: r'artist:"moxueyin | jiuxueran$" language:chinese',
        minRating: 3,
      ));
      final url = Uri.parse(
          verify(() => dio.get(captureAny())).captured.single as String);
      expect(url.host, ex ? 'exhentai.org' : 'e-hentai.org');
      expect(url.queryParameters['f_search'],
          r'artist:"moxueyin$" language:chinese');
      expect(url.queryParameters['f_srdd'], '3');
      expect(url.queryParameters['f_stags'], 'on');
      expect(url.toString(), isNot(contains('|')));
    });
  }

  test('history keeps original input and remains newest first', () async {
    final storage = MockStorage();
    when(() => storage.getSearchHistory()).thenReturn(['older']);
    when(() => storage.setSearchHistory(any())).thenAnswer((_) async {});
    final repo = SearchRepository(MockDio(), storage);
    await repo.addSearchHistory(r'artist:"moxueyin | jiuxueran$"');
    verify(() => storage.setSearchHistory([
          r'artist:"moxueyin | jiuxueran$"',
          'older',
        ])).called(1);
  });
}
