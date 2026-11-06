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
import 'favorites_search_test.dart' show html;

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
            return uri.queryParameters['next'] == null
                ? html([10], next: '?next=9&amp;favcat=1&amp;f_cats=1023')
                : html([9]);
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
