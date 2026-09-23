import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/parser/gallery_list_parser.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/blocs/gallery_list/gallery_list_bloc.dart';
import 'package:oviewer/blocs/gallery_list/gallery_list_event.dart';
import 'package:oviewer/blocs/gallery_list/gallery_list_state.dart';
import 'package:oviewer/blocs/search/search_bloc.dart';
import 'package:oviewer/blocs/search/search_event.dart';
import 'package:oviewer/blocs/search/search_state.dart';

class MockDb extends Mock implements AppDatabase {}

class MockDio extends Mock implements DioClient {}

class MockGallery extends Mock implements GalleryRepository {}

class MockSearch extends Mock implements SearchRepository {}

class MockSettings extends Mock implements SettingsRepository {}

GalleryPreview gallery(int gid, bool? cloud) => GalleryPreview(
      gid: gid,
      token: 'abc',
      title: 'Gallery',
      thumbUrl: '',
      category: 'Manga',
      rating: 4,
      uploader: '',
      fileCount: 1,
      postedAt: DateTime(2026),
      cloudFavorited: cloud,
      isFavorited: cloud == true,
    );

void main() {
  late Set<int> cached;
  late MockDb db;
  late FavoritesRepository favorites;
  setUpAll(() {
    registerFallbackValue(const LocalFavoritesCompanion());
    registerFallbackValue(const SearchFilter());
  });
  setUp(() {
    cached = {};
    db = MockDb();
    when(() => db.getLocalFavoriteGids()).thenAnswer((_) async => {...cached});
    when(() => db.addLocalFavorite(any())).thenAnswer((call) async {
      cached.add((call.positionalArguments.single as LocalFavoritesCompanion)
          .gid
          .value);
    });
    when(() => db.removeLocalFavorite(any())).thenAnswer((call) async {
      cached.remove(call.positionalArguments.single as int);
    });
    favorites = FavoritesRepository(MockDio(), db);
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    final settings = MockSettings();
    when(() => settings.getHiddenTags()).thenReturn([]);
    GetIt.I.registerSingleton<SettingsRepository>(settings);
  });
  tearDown(() => GetIt.I.reset());

  test('favorites endpoints mark entries even without timestamp markers',
      () async {
    final dio = MockDio();
    when(() => dio.get(any())).thenAnswer((_) async =>
        '<a href="/g/42/abc/"><span class="glink">Gallery</span></a>');
    final home = await GalleryRepository(dio).fetchFavoritesList();
    final cloud = await FavoritesRepository(dio, db).fetchCloudFavorites();
    expect(home.galleries.single.cloudFavorited, isTrue);
    expect(cloud.galleries.single.isFavorited, isTrue);
    // Generic list markup with no marker is unknown, not a removal.
    expect(
        GalleryListParser.parse('<a href="/g/42/abc/">Gallery</a>')
            .single
            .cloudFavorited,
        isNull);
  });

  for (final mode in ['glte', 'gltc', 'gltm', 'gld']) {
    test('parses cloud favorites in $mode without local cache', () {
      for (final style in [
        'background-color:rgba(0,0,0,0.1)',
        'background-color: rgba(240, 0, 0, 0.2)',
        'background-color:rgba(224,128,224,0.1)',
        'background-color: #000',
        '',
        'background-color:rgba(0,0,0,0)',
      ]) {
        final content =
            '<a href="/g/42/abc/"><div class="glink">Title</div></a>'
            '<div id="posted_42" style="$style">2026-09-23 12:00</div>'
            '<div class="cn" style="background-color:rgba(240,0,0,1)">Manga</div>';
        final html = mode == 'gld'
            ? '<div class="itg gld"><div>$content</div></div>'
            : '<table class="itg $mode"><tbody>'
                '${mode == "glte" ? "" : "<tr><th>Header</th></tr>"}'
                '<tr><td>$content</td><td></td><td></td></tr></tbody></table>';
        final result = GalleryListParser.parse(html).single;
        final expected = style.isNotEmpty && !style.endsWith(',0)');
        expect(result.cloudFavorited, expected, reason: style);
        expect(result.isFavorited, expected, reason: style);
      }
      expect(cached, isEmpty);
    });
  }

  test('partial responses merge positives/removals and retain unseen/unknown',
      () async {
    cached.addAll([2, 3, 99]);
    await favorites.cacheFavoriteStates(
        [gallery(1, true), gallery(2, false), gallery(3, null)]);
    expect(cached, {1, 3, 99});
    await favorites.rebuildCache([gallery(4, true)]);
    expect(cached, {1, 3, 4, 99});
    verifyNever(() => db.clearLocalFavorites());
  });

  test('home fetch, return, pagination and remote removal keep correct marks',
      () async {
    final repo = MockGallery();
    var response = GalleryListResult(
        galleries: [gallery(1, true)], totalPages: 2, nextPageUrl: '/?next=1');
    when(() => repo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
        .thenAnswer((_) async => response);
    final bloc = GalleryListBloc(repo);
    addTearDown(bloc.close);
    var next =
        bloc.stream.firstWhere((s) => s.status == GalleryListStatus.loaded);
    bloc.add(const FetchGalleries());
    expect((await next).galleries.single.isFavorited, isTrue);
    expect(cached, {1});
    bloc.add(RefreshFavoriteMarks());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.galleries.single.isFavorited, isTrue);
    response = GalleryListResult(galleries: [gallery(2, true)], totalPages: 2);
    next = bloc.stream.firstWhere((s) => s.galleries.length == 2);
    bloc.add(LoadMoreGalleries());
    expect((await next).galleries.every((g) => g.isFavorited), isTrue);
    expect(cached, {1, 2});
    // A local removal must win over the old cloud marker when returning.
    cached.remove(1);
    next = bloc.stream.firstWhere((s) => !s.galleries.first.isFavorited);
    bloc.add(RefreshFavoriteMarks());
    await next;
    // The next network refresh also observes a removal on another device.
    response = GalleryListResult(galleries: [gallery(2, false)], totalPages: 1);
    next = bloc.stream.firstWhere((s) =>
        s.galleries.singleOrNull?.gid == 2 && !s.galleries.first.isFavorited);
    bloc.add(RefreshGalleries());
    await next;
    expect(cached, isEmpty);
  });

  test('search keeps a remote favorite on return and reconciles refresh',
      () async {
    final repo = MockSearch();
    var cloud = true;
    when(() => repo.getSearchHistory()).thenReturn([]);
    when(() => repo.search(any())).thenAnswer((_) async => SearchResult(
        galleries: [gallery(1, cloud)], totalPages: 1, totalResults: 1));
    final bloc = SearchBloc(repo);
    addTearDown(bloc.close);
    var next = bloc.stream.firstWhere((s) => s.status == SearchStatus.loaded);
    bloc.add(const PerformSearch(SearchFilter(), saveHistory: false));
    expect((await next).results.single.isFavorited, isTrue);
    bloc.add(RefreshSearchFavoriteMarks());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.results.single.isFavorited, isTrue);
    cloud = false;
    next = bloc.stream.firstWhere((s) =>
        s.status == SearchStatus.loaded && !s.results.single.isFavorited);
    bloc.add(const PerformSearch(SearchFilter(), saveHistory: false));
    await next;
    expect(cached, isEmpty);
  });
}
