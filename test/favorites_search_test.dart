import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:oviewer/blocs/favorites/favorites_bloc.dart';
import 'package:oviewer/blocs/favorites/favorites_event.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'favorites_scope_test.dart' show result, flush;

class DioMock extends Mock implements DioClient {}

class Db extends Mock implements AppDatabase {}

class Repo extends Mock implements FavoritesRepository {}

class FailedStore extends InMemorySharedPreferencesStore {
  FailedStore(Map<String, Object> data) : super.withData(data);
  bool fail = true;
  bool throwOnWrite = false;
  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (fail && key == 'flutter.favorite_category_sidebar') {
      if (throwOnWrite) throw StateError('platform write failed');
      return Future.value(false);
    }
    return super.setValue(type, key, value);
  }
}

String html(List<int> ids, {String? next}) => ids.isEmpty && next == null
    ? '<p>No hits found</p>'
    : '${ids.map((id) => '<a href="/g/$id/abc/"><span class="glink">Gallery $id</span></a>').join()}'
        '${next == null ? '<span id="unext"></span>' : '<a id="unext" href="$next">Next</a>'}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(CancelToken()));
  tearDown(() {
    AppConstants.useExHentai = false;
    SharedPreferences.setMockInitialValues({});
  });
  for (final ex in [false, true]) {
    for (var cat = -1; cat <= 9; cat++) {
      test(
          'scoped search protocol EX=$ex favorite=$cat merges uploader and follows cursor',
          () async {
        AppConstants.useExHentai = ex;
        final dio = DioMock();
        final urls = <Uri>[];
        when(() => dio.get(any())).thenAnswer((call) async {
          final uri = Uri.parse(call.positionalArguments.first as String);
          urls.add(uri);
          return uri.queryParameters['next'] != null
              ? html([3])
              : html([1, 2], next: '?next=3');
        });
        final repo = FavoritesRepository(dio, Db());
        final first =
            await repo.fetchCloudFavorites(cat: cat, keyword: 'Account');
        expect(first.galleries.map((g) => g.gid), [2, 1]);
        final more = await repo.fetchCloudFavorites(
            cat: cat, keyword: 'Account', nextUrl: first.nextPageUrl, page: 1);
        expect(more.galleries.map((g) => g.gid), [3]);
        expect(more.nextPageUrl, isNull);
        for (final uri in urls) {
          expect(uri.host, ex ? 'exhentai.org' : 'e-hentai.org');
          expect(uri.path, '/favorites.php');
          expect(uri.queryParameters['favcat'], cat < 0 ? null : '$cat');
          expect(uri.queryParameters['sn'], 'on');
          expect(uri.queryParameters['st'], 'on');
          expect(uri.queryParameters['f_search'],
              anyOf('Account', 'uploader:"Account"'));
        }
        await expectLater(
            repo.fetchCloudFavorites(
                cat: cat, keyword: 'different', nextUrl: first.nextPageUrl),
            throwsFormatException);
        await expectLater(
            repo.fetchCloudFavorites(
                cat: cat == 9 ? 0 : 9,
                keyword: 'Account',
                nextUrl: first.nextPageUrl),
            throwsFormatException);
      });
    }
    test(
        'GID, URL, title alternatives and explicit tags stay on favorites EX=$ex',
        () async {
      AppConstants.useExHentai = ex;
      final dio = DioMock();
      final calls = <String>[];
      when(() => dio.get(any())).thenAnswer((call) async {
        final uri = Uri.parse(call.positionalArguments.first as String);
        expect(uri.path, '/favorites.php');
        calls.add(uri.queryParameters['f_search']!);
        return html([]);
      });
      final repo = FavoritesRepository(dio, Db());
      await repo.fetchCloudFavorites(keyword: '42');
      expect(calls, containsAll(['42', 'gid:42']));
      calls.clear();
      await repo.fetchCloudFavorites(keyword: 'https://e-hentai.org/g/42/abc/');
      expect(calls, ['gid:42']);
      calls.clear();
      await repo.fetchCloudFavorites(keyword: 'title:"English|日本語"');
      expect(calls, ['title:"English"', 'title:"日本語"']);
      calls.clear();
      await repo.fetchCloudFavorites(keyword: 'uploader:"Some Name"');
      expect(calls, ['uploader:"Some Name"']);
      calls.clear();
      await repo.fetchCloudFavorites(keyword: 'female:big breasts');
      expect(calls.single, contains('female:'));
    });
  }

  test(
      'duplicate-only pages continue and a failed branch does not consume the cursor',
      () async {
    final dio = DioMock();
    var fail = true;
    when(() => dio.get(any())).thenAnswer((call) async {
      final uri = Uri.parse(call.positionalArguments.first as String);
      final next = uri.queryParameters['next'];
      if (next == 'third' && fail) throw StateError('offline');
      return next == 'third'
          ? html([9])
          : html([1], next: next == null ? '?next=second' : '?next=third');
    });
    final repo = FavoritesRepository(dio, Db());
    final first = await repo.fetchCloudFavorites(keyword: 'title:"One"');
    await expectLater(
        repo.fetchCloudFavorites(
            keyword: 'title:"One"', nextUrl: first.nextPageUrl),
        throwsStateError);
    fail = false;
    final retry = await repo.fetchCloudFavorites(
        keyword: 'title:"One"', nextUrl: first.nextPageUrl);
    expect(retry.galleries.single.gid, 9);
    when(() => dio.get(any())).thenAnswer((_) async =>
        html([1], next: 'https://example.org/favorites.php?next=2'));
    await expectLater(repo.fetchCloudFavorites(keyword: 'title:"One"'),
        throwsFormatException);
    when(() => dio.get(any())).thenAnswer((_) async => '<form>Login</form>');
    await expectLater(repo.fetchCloudFavorites(keyword: 'title:"One"'),
        throwsFormatException);
  });

  for (final throws in [false, true]) {
    test(
        'migration preserves existing entry and retries partial writes (throws=$throws)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final platform = FailedStore({
        'flutter.favorite_category': 7,
        'flutter.favorite_destination': 3,
        'flutter.favorite_category_home': 2
      });
      platform.throwOnWrite = throws;
      SharedPreferencesStorePlatform.instance = platform;
      final store = LocalStorage();
      await store.init();
      expect(store.getFavoriteCategory(), 2);
      expect(store.getFavoriteCategory(entry: 'sidebar'), 7);
      expect(store.prefs.getInt('favorite_category'), 7);
      platform.fail = false;
      await store.migrateFavoriteCategories();
      expect(store.prefs.containsKey('favorite_category'), false);
      expect(store.getFavoriteCategory(), 2);
      expect(store.getFavoriteCategory(entry: 'sidebar'), 7);
      await store.setFavoriteCategory(8, entry: 'sidebar');
      final reopened = LocalStorage();
      await reopened.init();
      expect(reopened.getFavoriteCategory(), 2);
      expect(reopened.getFavoriteCategory(entry: 'sidebar'), 8);
      expect(reopened.getFavoriteDestination(), 3);
    });
  }

  for (final old in [7, 30, 'invalid']) {
    test('migration defaults and invalid new key: legacy=$old', () async {
      SharedPreferences.setMockInitialValues(
          {'favorite_category': old, 'favorite_category_home': 'bad'});
      final store = LocalStorage();
      await store.init();
      expect(store.getFavoriteCategory(), -1);
      expect(store.getFavoriteCategory(entry: 'sidebar'), old == 7 ? 7 : -1);
      expect(store.prefs.containsKey('favorite_category'), false);
    });
  }

  test('cloud changes cancel hidden work and refresh only the visible entry',
      () async {
    final repo = Repo();
    final changes = ValueNotifier<int>(0);
    when(() => repo.changes).thenReturn(changes);
    final requests = <(String?, CancelToken)>[];
    final pending = Completer<FavoritesResult>();
    var slow = false;
    when(() => repo.fetchCloudFavorites(
        page: any(named: 'page'),
        cat: any(named: 'cat'),
        keyword: any(named: 'keyword'),
        nextUrl: any(named: 'nextUrl'),
        cancelToken: any(named: 'cancelToken'))).thenAnswer((call) async {
      final q = call.namedArguments[#keyword] as String?;
      requests.add((q, call.namedArguments[#cancelToken] as CancelToken));
      if (q == 'home' && slow) return pending.future;
      return result([1]);
    });
    when(() => repo.rebuildCache(any(), isCurrent: any(named: 'isCurrent')))
        .thenAnswer((_) async {});
    final home = FavoritesBloc(repo);
    final side = home.forEntry(FavoritesEntry.sidebar);
    addTearDown(() async {
      await home.close();
      changes.dispose();
    });
    home.syncSession(site: 'eh', signedIn: true, revision: 0, account: 'A');
    await flush();
    home.attachView();
    side.attachView();
    await flush();
    home.add(const SearchFavorites('home'));
    side.add(const SearchFavorites('sidebar'));
    await flush();
    slow = true;
    home.add(const LoadFavorites());
    await flush();
    final oldToken = requests.last.$2;
    home.detachView();
    final count = requests.length;
    changes.value++;
    await flush();
    expect(oldToken.isCancelled, true);
    expect(requests.length, count + 1);
    expect(requests.last.$1, 'sidebar');
    pending.complete(result([999]));
    await flush();
    expect(home.state.favorites.single.gid, 1);
    slow = false;
    home.attachView();
    await flush();
    expect(requests.last.$1, 'home');
    expect(home.state.keyword, 'home');
    expect(side.state.keyword, 'sidebar');
  });

  test(
      'entries isolate query, category, pagination, cancellation and scroll buckets',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStorage();
    await store.init();
    final repo = Repo();
    final requests = <(String?, int, CancelToken)>[];
    final delayed = Completer<FavoritesResult>();
    when(() => repo.fetchCloudFavorites(
        page: any(named: 'page'),
        cat: any(named: 'cat'),
        nextUrl: any(named: 'nextUrl'),
        keyword: any(named: 'keyword'),
        cancelToken: any(named: 'cancelToken'))).thenAnswer((call) async {
      final q = call.namedArguments[#keyword] as String?;
      final cat = call.namedArguments[#cat] as int;
      requests.add((q, cat, call.namedArguments[#cancelToken] as CancelToken));
      if (q == 'slow') return delayed.future;
      return result([cat + 20], next: 'next-$q-$cat');
    });
    when(() => repo.rebuildCache(any(), isCurrent: any(named: 'isCurrent')))
        .thenAnswer((_) async {});
    when(() => repo.clearConfirmationCache()).thenAnswer((_) async {});
    final search = SearchRepository(DioMock(), store);
    final home = FavoritesBloc(repo,
        settings: SettingsRepository(store), search: search);
    final side = home.forEntry(FavoritesEntry.sidebar);
    addTearDown(home.close);
    home.syncSession(site: 'eh', signedIn: true, revision: 0, account: 'A');
    await flush();
    home.attachView();
    side.attachView();
    await flush();
    home.add(const SearchFavorites('home'));
    side.add(const SearchFavorites('sidebar'));
    await flush();
    home.add(const SelectFavoriteCategory(2));
    side.add(const SelectFavoriteCategory(7));
    await flush();
    final sideState = side.state;
    final sideScroll = side.scrollStorage;
    final sideRequests = requests.where((r) => r.$1 == 'sidebar').length;
    home.add(const SearchFavorites('slow'));
    await flush();
    final token = requests.last.$3;
    home.add(const SelectFavoriteCategory(3));
    await flush();
    expect(token.isCancelled, true);
    home.add(const SearchFavorites(''));
    await flush();
    delayed.complete(result([999]));
    await flush();
    expect(home.state.keyword, '');
    expect(home.state.category, 3);
    expect(home.state.favorites.single.gid, 23);
    expect(side.state, same(sideState));
    expect(side.scrollStorage, same(sideScroll));
    expect(requests.where((r) => r.$1 == 'sidebar').length, sideRequests);
    expect(requests.where((r) => r.$1 == 'sidebar').last.$3.isCancelled, false);
    expect(search.getSearchHistory(), containsAll(['home', 'sidebar', 'slow']));
    final beforeSide = side.state;
    home.add(LoadMoreFavorites());
    await flush();
    expect(side.state, same(beforeSide));
    side.detachView();
    home.syncSession(site: 'ex', signedIn: true, revision: 0, account: 'A');
    await flush();
    expect(side.state.keyword, 'sidebar');
    expect(side.state.favorites, isEmpty);
    side.attachView();
    await flush();
    expect(side.state.category, 7);
    home.syncSession(site: 'ex', signedIn: false, revision: 1, account: null);
    await flush();
    expect(home.state.keyword, '');
    expect(side.state.keyword, '');
    expect(side.state.category, 7);
  });
}
