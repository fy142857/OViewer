import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/search_repository.dart';

class MockDio extends Mock implements DioClient {}

class MockStorage extends Mock implements LocalStorage {}

String html(List<int> gids, {String? next}) =>
    '${gids.map((id) => '<a href="/g/$id/abc/">Gallery $id</a>').join()}'
    '${next == null ? '' : '<table class="ptt"><tr><td><a id="unext" href="$next">Next</a></td></tr></table>'}';

void main() {
  tearDown(() => AppConstants.useExHentai = false);
  const filter = SearchFilter(
      keyword: 'title:"Original" OR title:"译名"',
      categories: ['Manga'],
      minRating: 3);
  for (final ex in [false, true]) {
    for (final emptyFirst in [false, true]) {
      test('either title alone can match: EX=$ex, first empty=$emptyFirst',
          () async {
        AppConstants.useExHentai = ex;
        final dio = MockDio();
        final queries = <String>[];
        when(() => dio.get(any())).thenAnswer((call) async {
          final uri = Uri.parse(call.positionalArguments.single as String);
          expect(uri.host, ex ? 'exhentai.org' : 'e-hentai.org');
          expect(uri.queryParameters['f_cats'], '1019');
          expect(uri.queryParameters['f_srdd'], '3');
          final q = uri.queryParameters['f_search']!;
          queries.add(q);
          return html((q == 'title:"Original"') == emptyFirst ? [] : [42]);
        });
        final result =
            await SearchRepository(dio, MockStorage()).search(filter);
        expect(result.galleries.map((g) => g.gid), [42]);
        expect(queries, ['title:"Original"', 'title:"译名"']);
        expect(result.nextPageUrl, isNull);
      });
    }
  }

  test('merges both titles and skips duplicate-only pages without ending early',
      () async {
    final dio = MockDio();
    final calls = <String>[];
    when(() => dio.get(any())).thenAnswer((call) async {
      final uri = Uri.parse(call.positionalArguments.single as String);
      final cursor = uri.queryParameters['cursor'];
      calls.add(cursor ?? uri.queryParameters['f_search']!);
      if (cursor == 'left2') return html([1, 2], next: '/?cursor=left3');
      if (cursor == 'left3') return html([2, 3]);
      return uri.queryParameters['f_search'] == 'title:"Original"'
          ? html([1, 2], next: '/?cursor=left2')
          : html([2, 4]);
    });
    final repo = SearchRepository(dio, MockStorage());
    final first = await repo.search(filter);
    expect(first.galleries.map((g) => g.gid), [4, 2, 1]);
    final second =
        await repo.search(filter, page: 1, nextUrl: first.nextPageUrl);
    expect(second.galleries.map((g) => g.gid), [3]);
    expect(second.nextPageUrl, isNull);
    expect(second.totalResults, 4);
    expect(calls, ['title:"Original"', 'title:"译名"', 'left2', 'left3']);
  });

  test('failure is retryable and never permanently loses an alternative',
      () async {
    final dio = MockDio();
    var fail = true;
    when(() => dio.get(any())).thenAnswer((call) async {
      final q = Uri.parse(call.positionalArguments.single as String)
          .queryParameters['f_search'];
      if (q == 'title:"译名"' && fail) throw StateError('network failed');
      return html(q == 'title:"Original"' ? [1] : [2]);
    });
    final repo = SearchRepository(dio, MockStorage());
    await expectLater(repo.search(filter), throwsStateError);
    fail = false;
    expect((await repo.search(filter)).galleries.map((g) => g.gid), [2, 1]);
  });
}
