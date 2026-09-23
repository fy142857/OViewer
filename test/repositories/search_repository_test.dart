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
