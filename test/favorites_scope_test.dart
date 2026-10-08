import 'dart:async';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/favorites/favorites_bloc.dart';
import 'package:oviewer/blocs/favorites/favorites_event.dart';
import 'package:oviewer/blocs/favorites/favorites_state.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';

class Repo extends Mock implements FavoritesRepository {}

class Prefs extends Mock implements SettingsRepository {}

class DioMock extends Mock implements DioClient {}

class Db extends Mock implements AppDatabase {}

GalleryPreview gallery(int id) => GalleryPreview(
    gid: id,
    token: 'abc',
    title: 'Gallery $id',
    thumbUrl: '',
    category: 'Manga',
    uploader: '',
    postedAt: DateTime(2026),
    fileCount: 1,
    rating: 1);
FavoritesResult result(List<int> ids, {String? next, String? url}) =>
    FavoritesResult(
        galleries: ids.map(gallery).toList(),
        totalPages: -1,
        nextPageUrl: next,
        requestUrl: url);
Future<void> flush() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUpAll(() => registerFallbackValue(CancelToken()));
  tearDown(() => AppConstants.useExHentai = false);
  for (final ex in [false, true]) {
    for (var cat = -1; cat <= 9; cat++) {
      test('favorites protocol EX=$ex category=$cat and cursor scope',
          () async {
        AppConstants.useExHentai = ex;
        final dio = DioMock();
        final urls = <Uri>[];
        when(() => dio.get(any())).thenAnswer((call) async {
          urls.add(Uri.parse(call.positionalArguments.single as String));
          return '<a href="/g/42/abc/">Gallery</a><div class="searchnav"><a id="unext" href="?next=41&amp;favcat=0">Next</a></div>';
        });
        final repo = FavoritesRepository(dio, Db());
        final first = await repo.fetchCloudFavorites(cat: cat);
        await repo.fetchCloudFavorites(cat: cat, nextUrl: first.nextPageUrl);
        for (final uri in urls) {
          expect(uri.host, ex ? 'exhentai.org' : 'e-hentai.org');
          expect(uri.queryParameters['favcat'], cat < 0 ? null : '$cat');
        }
        expect(urls.last.queryParameters['next'], '41');
        expect(first.galleries.single.isFavorited, true);
      });
    }
  }
  test('cursor end, valid empty category, invalid HTML and unsafe next links',
      () async {
    final dio = DioMock();
    var html =
        '<a href="/g/42/abc/">Gallery</a><div class="searchnav"><span id="unext">Next</span></div>';
    when(() => dio.get(any())).thenAnswer((_) async => html);
    final repo = FavoritesRepository(dio, Db());
    expect((await repo.fetchCloudFavorites()).nextPageUrl, isNull);
    html = '<p>No hits found</p>';
    expect((await repo.fetchCloudFavorites(cat: 9)).galleries, isEmpty);
    html = '<form>Log in</form>';
    await expectLater(repo.fetchCloudFavorites(), throwsFormatException);
    await expectLater(
        repo.fetchCloudFavorites(nextUrl: 'https://example.org/favorites.php'),
        throwsFormatException);
  });

  test('numeric pagination uses next links and ignores backward pages',
      () async {
    final dio = DioMock();
    var pageHtml =
        '<a href="/g/42/abc/">Gallery</a><table class="ptt"><tr><td class="ptds">1</td><td><a href="?page=1">2</a></td></tr></table>';
    when(() => dio.get(any())).thenAnswer((_) async => pageHtml);
    final repo = FavoritesRepository(dio, Db());
    expect(
        Uri.parse((await repo.fetchCloudFavorites(cat: 8)).nextPageUrl!)
            .queryParameters['page'],
        '1');
    pageHtml =
        '<a href="/g/41/abc/">Gallery</a><table class="ptt"><tr><td class="ptds">2</td><td><a href="?page=0">Previous</a></td></tr></table>';
    expect(
        (await repo.fetchCloudFavorites(cat: 8, page: 1)).nextPageUrl, isNull);
  });

  test(
      'favorite selection survives storage recreation, and invalid values default to all',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStorage();
    await store.init();
    final settings = SettingsRepository(store);
    final first = FavoritesBloc(Repo(), settings: settings);
    expect(first.state.category, -1);
    await first.close();
    await settings.setFavoriteCategory(9);
    final reopened = LocalStorage();
    await reopened.init();
    final next = FavoritesBloc(Repo(), settings: SettingsRepository(reopened));
    expect(next.state.category, 9);
    await next.close();
    await reopened.prefs.setInt('favorite_category', 99);
    final invalid =
        FavoritesBloc(Repo(), settings: SettingsRepository(reopened));
    expect(invalid.state.category, -1);
    await invalid.close();
    await reopened.prefs.setString('favorite_category', 'invalid');
    final corrupt =
        FavoritesBloc(Repo(), settings: SettingsRepository(reopened));
    expect(corrupt.state.category, -1);
    await corrupt.close();
  });

  test(
      'account changed while reading local data cannot start a favorite removal',
      () async {
    final dio = DioMock();
    final db = Db();
    var revision = 0;
    final existing = Completer<LocalFavorite?>();
    when(() => dio.sessionRevision).thenAnswer((_) => revision);
    when(() => db.getLocalFavorite(42)).thenAnswer((_) => existing.future);
    final repo = FavoritesRepository(dio, db);
    final pending =
        expectLater(repo.removeCloudFavorite(42, 'abc'), throwsStateError);
    revision = 1;
    existing.complete(null);
    await pending;
    verifyNever(() => dio.post(any(), data: any(named: 'data')));
    verifyNever(() => db.removeLocalFavorite(any()));
  });

  group('shared favorites state', () {
    late Repo repo;
    late Prefs prefs;
    late FavoritesBloc bloc;
    setUp(() async {
      repo = Repo();
      prefs = Prefs();
      when(() => prefs.getFavoriteCategory()).thenReturn(4);
      when(() => prefs.setFavoriteCategory(any())).thenAnswer((_) async {});
      when(() => repo.fetchCloudFavorites(
              cat: any(named: 'cat'),
              page: any(named: 'page'),
              nextUrl: any(named: 'nextUrl'),
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer(
              (call) async => result([call.namedArguments[#cat] as int]));
      when(() => repo.rebuildCache(any(), isCurrent: any(named: 'isCurrent')))
          .thenAnswer((_) async {});
      when(() => repo.clearConfirmationCache()).thenAnswer((_) async {});
      bloc = FavoritesBloc(repo, settings: prefs);
      bloc.syncSession(site: 'eh', signedIn: true, revision: 0, account: 'A');
      await flush();
    });
    tearDown(() => bloc.close());
    test(
        'saved selection, simultaneous views and repeated choice do not duplicate loads',
        () async {
      expect(bloc.state.category, 4);
      bloc.attachView();
      bloc.attachView();
      await flush();
      expect(bloc.state.favorites.single.gid, 4);
      verify(() => repo.fetchCloudFavorites(
          cat: 4, cancelToken: any(named: 'cancelToken'))).called(1);
      bloc.add(const SelectFavoriteCategory(9));
      await flush();
      expect(bloc.state.category, 9);
      expect(bloc.state.favorites.single.gid, 9);
      verify(() => prefs.setFavoriteCategory(9)).called(1);
      bloc.add(const SelectFavoriteCategory(9));
      await flush();
      verify(() => repo.fetchCloudFavorites(
          cat: 9, cancelToken: any(named: 'cancelToken'))).called(1);
    });
    test('late previous category response is cancelled and never merged',
        () async {
      final old = Completer<FavoritesResult>();
      CancelToken? token;
      when(() => repo.fetchCloudFavorites(
          cat: 4, cancelToken: any(named: 'cancelToken'))).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return old.future;
      });
      bloc.attachView();
      await flush();
      bloc.add(const SelectFavoriteCategory(7));
      await flush();
      expect(token!.isCancelled, true);
      old.complete(result([999]));
      await flush();
      expect(bloc.state.favorites.single.gid, 7);
    });
    test(
        'failed preference save keeps selection and contents; subsequent retry works',
        () async {
      bloc.attachView();
      await flush();
      when(() => prefs.setFavoriteCategory(8)).thenThrow(StateError('storage'));
      bloc.add(const SelectFavoriteCategory(8));
      await flush();
      expect(bloc.state.category, 4);
      expect(bloc.state.favorites.single.gid, 4);
      expect(bloc.state.errorMessage, 'favoriteFilterSaveFailed');
      when(() => prefs.setFavoriteCategory(8)).thenAnswer((_) async {});
      bloc.add(const SelectFavoriteCategory(8));
      await flush();
      expect(bloc.state.category, 8);
    });
    test(
        'pagination deduplicates, skips duplicate-only pages and retries without cursor loss',
        () async {
      var fail = true;
      when(() => repo.fetchCloudFavorites(
          cat: 4,
          page: any(named: 'page'),
          nextUrl: any(named: 'nextUrl'),
          cancelToken: any(named: 'cancelToken'))).thenAnswer((call) async {
        final url = call.namedArguments[#nextUrl];
        if (url == 'two') return result([1], next: 'three');
        if (url == 'three') {
          if (fail) throw StateError('offline');
          return result([1, 2]);
        }
        return result([1, 1], next: 'two', url: 'first');
      });
      bloc.attachView();
      await flush();
      bloc.add(LoadMoreFavorites());
      await flush();
      expect(bloc.state.loadMoreFailed, true);
      expect(bloc.state.nextPageUrl, 'two');
      expect(bloc.state.favorites.map((g) => g.gid), [1]);
      fail = false;
      bloc.add(LoadMoreFavorites());
      await flush();
      expect(bloc.state.favorites.map((g) => g.gid), [1, 2]);
      expect(bloc.state.hasReachedEnd, true);
    });
    test('cyclic cursor fails instead of looping or silently declaring the end',
        () async {
      when(() => repo.fetchCloudFavorites(
              cat: 4, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => result([1], next: 'first', url: 'first'));
      bloc.attachView();
      await flush();
      bloc.add(LoadMoreFavorites());
      await flush();
      expect(bloc.state.loadMoreFailed, true);
      expect(bloc.state.hasReachedEnd, false);
    });
    test('rapid selections serialize persistence and final choice wins',
        () async {
      final firstSave = Completer<void>();
      final saved = <int>[];
      when(() => prefs.setFavoriteCategory(any())).thenAnswer((call) async {
        final category = call.positionalArguments.single as int;
        if (category == 1) await firstSave.future;
        saved.add(category);
      });
      bloc.attachView();
      await flush();
      bloc.add(const SelectFavoriteCategory(1));
      await flush();
      bloc.add(const SelectFavoriteCategory(9));
      await flush();
      firstSave.complete();
      await flush();
      expect(saved, [1, 9]);
      expect(bloc.state.category, 9);
      expect(bloc.state.favorites.single.gid, 9);
    });
    test('site/account changes reject previous pending page completion',
        () async {
      final pending = Completer<FavoritesResult>();
      var call = 0;
      when(() => repo.fetchCloudFavorites(
              cat: 4, cancelToken: any(named: 'cancelToken')))
          .thenAnswer(
              (_) => ++call == 1 ? pending.future : Future.value(result([88])));
      bloc.attachView();
      await flush();
      bloc.syncSession(site: 'ex', signedIn: true, revision: 1, account: 'B');
      await flush();
      pending.complete(result([99]));
      await flush();
      expect(bloc.state.favorites.single.gid, 88);
      expect(bloc.state.category, 4);
      verify(() => repo.clearConfirmationCache()).called(1);
    });
    test('failed cache clearing can retry without poisoning later loads',
        () async {
      var fail = true;
      when(() => repo.clearConfirmationCache()).thenAnswer((_) async {
        if (fail) throw StateError('database');
      });
      bloc.attachView();
      await flush();
      bloc.syncSession(site: 'ex', signedIn: true, revision: 1, account: 'A');
      await flush();
      expect(bloc.state.status, FavoritesStatus.error);
      fail = false;
      bloc.add(const LoadFavorites());
      await flush();
      expect(bloc.state.status, FavoritesStatus.loaded);
    });

    test(
        'removal refreshes current category instead of returning to Favorite 0',
        () async {
      when(() => repo.removeCloudFavorite(4, 'abc')).thenAnswer((_) async {});
      bloc.attachView();
      await flush();
      bloc.add(const RemoveFavorite(gid: 4, token: 'abc'));
      await flush();
      expect(bloc.state.category, 4);
      verify(() => repo.fetchCloudFavorites(
          cat: 4, cancelToken: any(named: 'cancelToken'))).called(2);
    });

    test('closing during preference save cannot start a new network request',
        () async {
      final saving = Completer<void>();
      when(() => prefs.setFavoriteCategory(8)).thenAnswer((_) => saving.future);
      bloc.add(const SelectFavoriteCategory(8));
      await flush();
      final closing = bloc.close();
      saving.complete();
      await closing;
      verifyNever(() => repo.fetchCloudFavorites(
          cat: 8, cancelToken: any(named: 'cancelToken')));
    });

    test(
        'logout discards pending work, clears membership and keeps preferred category',
        () async {
      final old = Completer<FavoritesResult>();
      when(() => repo.fetchCloudFavorites(
              cat: 4, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) => old.future);
      bloc.attachView();
      await flush();
      bloc.syncSession(site: 'eh', signedIn: false, revision: 1);
      await flush();
      old.complete(result([999]));
      await flush();
      expect(bloc.state.favorites, isEmpty);
      expect(bloc.state.category, 4);
      verify(() => repo.clearConfirmationCache()).called(1);
      verifyNever(
          () => repo.rebuildCache(any(), isCurrent: any(named: 'isCurrent')));
    });
  });
}
