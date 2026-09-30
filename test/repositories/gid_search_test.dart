import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/search_repository.dart';

class MockDio extends Mock implements DioClient {}

class MockStorage extends Mock implements LocalStorage {}

String listing(String site, String mode,
    {int gid = 42, String token = 'abcdef1234'}) {
  final link =
      '<a href="$site/g/$gid/$token/"><span class="glink">Target</span></a>';
  if (mode == 'gld') return '<div class="itg gld"><div>$link</div></div>';
  return '<table class="itg $mode"><tbody>'
      '${mode == 'glte' ? '' : '<tr><th>Title</th></tr>'}'
      '<tr><td>$link</td><td></td><td></td></tr></tbody></table>';
}

void main() {
  final originalSite = AppConstants.useExHentai;
  tearDown(() => AppConstants.useExHentai = originalSite);

  test('only positive ASCII GIDs with a safe next cursor trigger lookup', () {
    for (final input in ['42', ' 42 ', '00042']) {
      expect(SearchRepository.parseGid(input), 42);
    }
    for (final input in [
      '',
      '0',
      '000',
      '-42',
      '+42',
      '４２',
      '4 2',
      '42.0',
      'title:42',
      'https://e-hentai.org/g/42/abc/',
      '9223372036854775807',
      '999999999999999999999999999'
    ]) {
      expect(SearchRepository.parseGid(input), isNull, reason: input);
    }
  });

  for (final ex in [false, true]) {
    for (final mode in ['glte', 'gltc', 'gltm', 'gld']) {
      test('exact match and full link on ${ex ? 'EX' : 'EH'} $mode', () async {
        AppConstants.useExHentai = ex;
        final site = AppConstants.baseUrl;
        final dio = MockDio();
        when(() => dio.get('$site/?f_cats=0&next=43')).thenAnswer(
            (_) async => '<a href="javascript:void(0)">Navigation</a>'
                '${listing(site, mode)}');
        final result =
            await SearchRepository(dio, MockStorage()).searchByGid(42);
        expect(result?.gid, 42);
        expect(result?.token, 'abcdef1234');
        verify(() => dio.get('$site/?f_cats=0&next=43')).called(1);
        verifyNoMoreInteractions(dio);
      });
    }
  }

  test('adjacent gallery is never substituted; lookup does not paginate',
      () async {
    final dio = MockDio();
    when(() => dio.get(any())).thenAnswer(
        (_) async => '${listing(AppConstants.baseUrl, 'glte', gid: 41)}'
            '<a id="unext" href="/?next=40">Next</a>');
    expect(await SearchRepository(dio, MockStorage()).searchByGid(42), isNull);
    verify(() => dio.get(any())).called(1);
  });

  test('no hits is a normal miss; login, garbage and foreign links are errors',
      () async {
    final dio = MockDio();
    final repo = SearchRepository(dio, MockStorage());
    when(() => dio.get(any())).thenAnswer((_) async => '<p>No hits found</p>');
    expect(await repo.searchByGid(42), isNull);
    for (final html in [
      '<form>Login</form>',
      '',
      listing(AppConstants.baseUrl, 'glte', token: 'invalid-token'),
      listing('https://example.test', 'glte')
    ]) {
      when(() => dio.get(any())).thenAnswer((_) async => html);
      await expectLater(repo.searchByGid(42), throwsFormatException);
    }
    when(() => dio.get(any())).thenThrow(Exception('timeout'));
    await expectLater(repo.searchByGid(42), throwsException);
  });
}
