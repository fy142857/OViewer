import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:get_it/get_it.dart';
import 'package:oviewer/blocs/search/search_bloc.dart';
import 'package:oviewer/blocs/search/search_event.dart';
import 'package:oviewer/blocs/search/search_state.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/utils/uploader_search_query.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'similar_title_search_test.dart' show MockDio, MockStorage, html;

class Favorites extends Mock implements FavoritesRepository {}

void main() {
  tearDown(() async {
    AppConstants.useExHentai = false;
    await GetIt.I.reset();
  });

  for (final ex in [false, true]) {
    for (final name in [
      'Name With Spaces',
      '中文上传者',
      '12345',
      'Name | Alias',
      'Unknown'
    ]) {
      test('plain account name also searches uploader: EX=$ex, $name',
          () async {
        AppConstants.useExHentai = ex;
        final dio = MockDio();
        final queries = <String>[];
        when(() => dio.get(any())).thenAnswer((call) async {
          final uri = Uri.parse(call.positionalArguments.single as String);
          expect(uri.host, ex ? 'exhentai.org' : 'e-hentai.org');
          expect(uri.queryParameters['f_cats'], '1019');
          expect(uri.queryParameters['f_srdd'], '3');
          final query = uri.queryParameters['f_search']!;
          queries.add(query);
          return html(query.startsWith('uploader:') ? [42] : []);
        });
        final result = await SearchRepository(dio, MockStorage()).search(
            SearchFilter(
                keyword: name, categories: const ['Manga'], minRating: 3));
        expect(queries, [name, 'uploader:"$name"']);
        expect(result.galleries.map((g) => g.gid), [42]);
      });
    }
  }

  test(
      'explicit qualifiers, operators and blank searches remain single requests',
      () async {
    for (final query in [
      'uploader:"Name With Spaces"',
      'uploaduid:123',
      'artist:"name"',
      'title:"A title"',
      'language:chinese',
      '-excluded',
      '~alternative',
      'name*',
      'exact\$',
      'a OR b',
      ''
    ]) {
      final dio = MockDio();
      when(() => dio.get(any())).thenAnswer((_) async => html([]));
      await SearchRepository(dio, MockStorage())
          .search(SearchFilter(keyword: query));
      final uri = Uri.parse(
          verify(() => dio.get(captureAny())).captured.single as String);
      expect(uri.queryParameters['f_search'], query.isEmpty ? null : query);
      expect(plainUploaderSearchQuery(query), isNull);
    }
    expect(plainUploaderSearchQuery('"Name With Spaces"'),
        'uploader:"Name With Spaces"');
    expect(plainUploaderSearchQuery('"-name"'), 'uploader:"-name"');
  });

  test('both result streams merge and continue through duplicate-only pages',
      () async {
    final dio = MockDio();
    final calls = <String>[];
    when(() => dio.get(any())).thenAnswer((call) async {
      final uri = Uri.parse(call.positionalArguments.single as String);
      final cursor = uri.queryParameters['cursor'];
      calls.add(cursor ?? uri.queryParameters['f_search']!);
      if (cursor == 'ordinary2') {
        return html([2, 3], next: '/?cursor=ordinary3');
      }
      if (cursor == 'ordinary3') return html([4]);
      if (cursor == 'uploader2') {
        return html([1, 3], next: '/?cursor=uploader3');
      }
      if (cursor == 'uploader3') return html([4, 5]);
      return uri.queryParameters['f_search'] == 'Account'
          ? html([1, 2], next: '/?cursor=ordinary2')
          : html([2, 3], next: '/?cursor=uploader2');
    });
    final repo = SearchRepository(dio, MockStorage());
    const filter = SearchFilter(keyword: 'Account');
    final first = await repo.search(filter);
    expect(first.galleries.map((g) => g.gid), [3, 2, 1]);
    final next = await repo.search(filter, page: 1, nextUrl: first.nextPageUrl);
    expect(next.galleries.map((g) => g.gid), [5, 4]);
    expect(next.totalResults, 5);
    expect(next.nextPageUrl, isNull);
    expect(calls, [
      'Account',
      'uploader:"Account"',
      'ordinary2',
      'uploader2',
      'ordinary3',
      'uploader3'
    ]);
    await expectLater(
        repo.search(filter.copyWith(categories: ['Manga']),
            nextUrl: first.nextPageUrl),
        throwsFormatException);
  });

  test(
      'one exhausted source cannot end the other, and failed page retries retain its cursor',
      () async {
    final dio = MockDio();
    var fail = true;
    when(() => dio.get(any())).thenAnswer((call) async {
      final uri = Uri.parse(call.positionalArguments.single as String);
      if (uri.queryParameters['cursor'] == 'uploader2') {
        if (fail) throw StateError('network');
        return html([2]);
      }
      return uri.queryParameters['f_search'] == 'Account'
          ? html([1])
          : html([1], next: '/?cursor=uploader2');
    });
    final repo = SearchRepository(dio, MockStorage());
    const filter = SearchFilter(keyword: 'Account');
    final first = await repo.search(filter);
    expect(first.nextPageUrl, isNotNull);
    await expectLater(repo.search(filter, page: 1, nextUrl: first.nextPageUrl),
        throwsStateError);
    fail = false;
    final next = await repo.search(filter, page: 1, nextUrl: first.nextPageUrl);
    expect(next.galleries.map((g) => g.gid), [2]);
    expect(next.nextPageUrl, isNull);
  });

  test(
      'ordinary title/tag matches remain visible when the uploader has no matches',
      () async {
    final dio = MockDio();
    when(() => dio.get(any())).thenAnswer((call) async {
      final q = Uri.parse(call.positionalArguments.single as String)
          .queryParameters['f_search'];
      return html(q == 'ordinary title' ? [8] : []);
    });
    final result = await SearchRepository(dio, MockStorage())
        .search(const SearchFilter(keyword: 'ordinary title'));
    expect(result.galleries.single.gid, 8);
  });

  test(
      'search flow accepts a bare name, publishes uploader matches, and keeps raw history',
      () async {
    final dio = MockDio();
    final storage = MockStorage();
    final favorites = Favorites();
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {});
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    when(() => storage.getSearchHistory()).thenReturn([]);
    when(() => storage.setSearchHistory(any())).thenAnswer((_) async {});
    when(() => dio.get(any())).thenAnswer((call) async {
      final q = Uri.parse(call.positionalArguments.single as String)
          .queryParameters['f_search'];
      return html(q == 'uploader:"Account Name"' ? [42] : []);
    });
    final bloc = SearchBloc(SearchRepository(dio, storage));
    final done = bloc.stream.firstWhere((s) => s.status == SearchStatus.loaded);
    bloc.add(const PerformSearch(SearchFilter(keyword: 'Account Name')));
    final result = await done;
    expect(result.results.single.gid, 42);
    expect(result.filter.keyword, 'Account Name');
    verify(() => storage.setSearchHistory(['Account Name'])).called(1);
    await bloc.close();
  });
}
