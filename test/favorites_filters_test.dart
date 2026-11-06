import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/blocs/favorites/favorites_bloc.dart';
import 'package:oviewer/blocs/favorites/favorites_event.dart';
import 'favorites_scope_test.dart' show DioMock, Db, Repo, result, flush;

String categoryPage(List<(int, String)> rows, {String? next}) =>
    '<table class="itg gltc"><tbody><tr><th>Category</th><th>Gallery</th><th>Info</th></tr>'
    '${rows.map((row) => '<tr><td><div class="cn">${row.$2}</div></td><td><a href="/g/${row.$1}/abc/"><span class="glink">Gallery ${row.$1}</span></a></td><td>1 page</td></tr>').join()}'
    '</tbody></table>${next == null ? '<span id="unext"></span>' : '<a id="unext" href="$next">Next</a>'}'
    '${rows.isEmpty ? '<p>No hits found</p>' : ''}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(CancelToken()));
  tearDown(() => AppConstants.useExHentai = false);
  for (final ex in [false, true]) {
    for (final categories in [
      <String>[],
      ...AppConstants.categories.map((c) => [c]),
      ['Manga', 'Western'],
      AppConstants.categories
    ]) {
      for (final query in [null, 'Account']) {
        test(
            'favorites filter EX=$ex categories=$categories query=$query scopes every request',
            () async {
          AppConstants.useExHentai = ex;
          final dio = DioMock();
          final urls = <Uri>[];
          when(() => dio.get(any())).thenAnswer((call) async {
            final uri = Uri.parse(call.positionalArguments.first as String);
            urls.add(uri);
            final category = categories.isEmpty ? 'Misc' : categories.first;
            return uri.queryParameters['next'] == null
                ? categoryPage([(10, category)],
                    next: '?next=9&amp;favcat=1&amp;f_cats=1023')
                : categoryPage([(9, category)]);
          });
          final repo = FavoritesRepository(dio, Db());
          final first = await repo.fetchCloudFavorites(
              cat: 7, categories: categories, keyword: query);
          await repo.fetchCloudFavorites(
              cat: 7,
              categories: categories,
              keyword: query,
              nextUrl: first.nextPageUrl,
              page: 1);
          final allowed = categories.fold<int>(
              0, (bits, cat) => bits | AppConstants.categoryBits[cat]!);
          final mask = categories.isEmpty ? 0 : 1023 ^ allowed;
          expect(urls.length, greaterThanOrEqualTo(2));
          for (final uri in urls) {
            expect(uri.host, ex ? 'exhentai.org' : 'e-hentai.org');
            expect(uri.path, '/favorites.php');
            expect(uri.queryParameters['favcat'], '7');
            expect(uri.queryParameters['f_cats'], '$mask');
          }
          if (query != null && categories.length == 1) {
            await expectLater(
                repo.fetchCloudFavorites(
                    cat: 7,
                    categories: [],
                    keyword: query,
                    nextUrl: first.nextPageUrl),
                throwsFormatException);
          }
        });
      }
    }
  }
  for (final ex in [false, true]) {
    for (final query in [null, 'female:test']) {
      test(
          'mixed categories are filtered across empty pages EX=$ex query=$query',
          () async {
        AppConstants.useExHentai = ex;
        final dio = DioMock();
        final urls = <Uri>[];
        when(() => dio.get(any())).thenAnswer((call) async {
          final uri = Uri.parse(call.positionalArguments.first as String);
          urls.add(uri);
          return switch (uri.queryParameters['next']) {
            '1' => categoryPage([(5, 'Misc')], next: '?next=2'),
            '2' => categoryPage([(4, 'Manga'), (3, 'Western')]),
            _ => categoryPage([(8, 'Doujinshi'), (7, 'Manga'), (6, 'Western')],
                next: '?next=1'),
          };
        });
        final repo = FavoritesRepository(dio, Db());
        final first = await repo.fetchCloudFavorites(
            cat: 4, categories: ['Manga'], keyword: query);
        expect(first.galleries.map((g) => g.gid), [7]);
        final more = await repo.fetchCloudFavorites(
            cat: 4,
            categories: ['Manga'],
            keyword: query,
            nextUrl: first.nextPageUrl,
            page: 1);
        expect(more.galleries.map((g) => g.gid), [4]);
        expect(more.nextPageUrl, isNull);
        expect(urls.map((u) => u.queryParameters['next']), [null, '1', '2']);
        expect(urls.every((u) => u.queryParameters['favcat'] == '4'), true);
      });
    }
  }
  test('empty first pages continue until an actual match, or true exhaustion',
      () async {
    final dio = DioMock();
    when(() => dio.get(any())).thenAnswer((call) async {
      final uri = Uri.parse(call.positionalArguments.first as String);
      return uri.queryParameters['next'] == null
          ? categoryPage([(3, 'Misc')], next: '?next=2')
          : categoryPage([(2, 'Western')]);
    });
    final repo = FavoritesRepository(dio, Db());
    expect(
        (await repo.fetchCloudFavorites(categories: ['Western']))
            .galleries
            .single
            .gid,
        2);
    final empty = await repo.fetchCloudFavorites(categories: ['Manga']);
    expect(empty.galleries, isEmpty);
    expect(empty.nextPageUrl, isNull);
    final multi =
        await repo.fetchCloudFavorites(categories: ['Western', 'Misc']);
    expect(multi.galleries.single.gid, 3);
    expect(multi.nextPageUrl, isNotNull);
  });
  test(
      'skipping categories retains retry position and stops repeated or cancelled cursors',
      () async {
    final dio = DioMock();
    var fail = true;
    when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((call) async {
      final uri = Uri.parse(call.positionalArguments.first as String);
      if (uri.queryParameters['next'] != null) {
        if (fail) throw StateError('offline');
        return categoryPage([(1, 'Manga')]);
      }
      return categoryPage([(2, 'Misc')], next: '?next=1');
    });
    final repo = FavoritesRepository(dio, Db());
    final token = CancelToken();
    await expectLater(
        repo.fetchCloudFavorites(categories: ['Manga'], cancelToken: token),
        throwsStateError);
    fail = false;
    expect(
        (await repo
                .fetchCloudFavorites(categories: ['Manga'], cancelToken: token))
            .galleries
            .single
            .gid,
        1);
    token.cancel();
    await expectLater(
        repo.fetchCloudFavorites(categories: ['Manga'], cancelToken: token),
        throwsA(isA<DioException>()));
    when(() => dio.get(any())).thenAnswer(
        (_) async => categoryPage([(2, 'Misc')], next: '?next=repeat'));
    await expectLater(
        repo.fetchCloudFavorites(categories: ['Manga']), throwsFormatException);
  });
  test(
      'apply combines group and categories, cancels stale page, preserves query and isolates entries',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    final repo = Repo();
    final calls = <(int, String?, List<String>, CancelToken)>[];
    final stale = Completer<FavoritesResult>();
    when(() => repo.fetchCloudFavorites(
        cat: any(named: 'cat'),
        page: any(named: 'page'),
        nextUrl: any(named: 'nextUrl'),
        keyword: any(named: 'keyword'),
        categories: any(named: 'categories'),
        cancelToken: any(named: 'cancelToken'))).thenAnswer((call) {
      final cat = call.namedArguments[#cat] as int;
      final categories = call.namedArguments[#categories] as List<String>;
      calls.add((
        cat,
        call.namedArguments[#keyword] as String?,
        categories,
        call.namedArguments[#cancelToken] as CancelToken
      ));
      return cat == -1 ? stale.future : Future.value(result([cat]));
    });
    when(() => repo.rebuildCache(any(), isCurrent: any(named: 'isCurrent')))
        .thenAnswer((_) async {});
    when(() => repo.clearConfirmationCache()).thenAnswer((_) async {});
    final bloc = FavoritesBloc(repo, settings: SettingsRepository(storage));
    addTearDown(bloc.close);
    bloc.syncSession(site: 'eh', signedIn: true, revision: 1, account: 'a');
    await flush();
    bloc.add(const SearchFavorites('some query'));
    await flush();
    final old = calls.last.$4;
    bloc.add(const ApplyFavoriteFilters(3, ['Manga', 'Western']));
    await flush();
    expect(old.isCancelled, true);
    expect(bloc.state.category, 3);
    expect(bloc.state.galleryCategories, ['Manga', 'Western']);
    expect(bloc.state.keyword, 'some query');
    expect(calls.last.$1, 3);
    expect(calls.last.$2, 'some query');
    expect(calls.last.$3, ['Manga', 'Western']);
    final side = bloc.forEntry(FavoritesEntry.sidebar);
    expect(side.state.category, -1);
    expect(side.state.galleryCategories, isEmpty);
    stale.complete(result([99]));
    await flush();
    expect(bloc.state.favorites.single.gid, 3);
    bloc.add(const ApplyFavoriteFilters(-1, []));
    await flush();
    expect(bloc.state.galleryCategories, isEmpty);
    expect(bloc.state.keyword, 'some query');
  });
}
