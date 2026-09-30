import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/search/search_bloc.dart';
import 'package:oviewer/blocs/search/search_event.dart';
import 'package:oviewer/blocs/search/search_state.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/models/search_filter.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';

class MockSearch extends Mock implements SearchRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

GalleryPreview gallery(int gid) => GalleryPreview(
    gid: gid,
    token: 'abcdef1234',
    title: 'Gallery $gid',
    thumbUrl: '',
    category: 'Manga',
    rating: 4,
    uploader: 'test',
    fileCount: 20,
    postedAt: DateTime(2026));
SearchResult results(List<int> ids, {String? next}) => SearchResult(
    galleries: ids.map(gallery).toList(),
    totalPages: 1,
    totalResults: ids.length,
    nextPageUrl: next);
Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late MockSearch repo;
  late SearchBloc bloc;
  setUpAll(() => registerFallbackValue(const SearchFilter()));
  setUp(() {
    repo = MockSearch();
    final favorites = MockFavorites();
    when(() => favorites.getLocalFavoriteGids()).thenAnswer((_) async => {42});
    GetIt.I.registerSingleton<FavoritesRepository>(favorites);
    when(() => repo.getSearchHistory()).thenReturn([]);
    when(() => repo.addSearchHistory(any())).thenAnswer((_) async {});
    bloc = SearchBloc(repo);
  });
  tearDown(() async {
    await bloc.close();
    await GetIt.I.reset();
  });

  for (final gidFirst in [false, true]) {
    test(
        'requests start together and merge independently (gid first: $gidFirst)',
        () async {
      final ordinary = Completer<SearchResult>();
      final exact = Completer<GalleryPreview?>();
      when(() => repo.search(any())).thenAnswer((_) => ordinary.future);
      when(() => repo.searchByGid(42)).thenAnswer((_) => exact.future);
      const filter =
          SearchFilter(keyword: '00042', categories: ['Manga'], minRating: 5);
      bloc.add(const PerformSearch(filter));
      await flush();
      verify(() => repo.search(filter)).called(1);
      verify(() => repo.searchByGid(42)).called(1);
      if (gidFirst) {
        exact.complete(gallery(42));
      } else {
        ordinary.complete(results([50, 42, 40]));
      }
      await flush();
      expect(bloc.state.status, SearchStatus.loading);
      expect(
          bloc.state.results.map((g) => g.gid), gidFirst ? [42] : [50, 42, 40]);
      if (gidFirst) {
        ordinary.complete(results([50, 42, 40]));
      } else {
        exact.complete(gallery(42));
      }
      await flush();
      expect(bloc.state.status, SearchStatus.loaded);
      expect(bloc.state.results.map((g) => g.gid), [42, 50, 40]);
      expect(bloc.state.results.first.isFavorited, isTrue);
      expect(bloc.state.matchedGid, 42);
      verify(() => repo.addSearchHistory('00042')).called(1);
    });
  }

  for (final failedSource in SearchSource.values) {
    test('partial failure retains results and retries only $failedSource',
        () async {
      when(() => repo.search(any())).thenAnswer((_) async {
        if (failedSource == SearchSource.ordinary) throw Exception('offline');
        return results([50]);
      });
      when(() => repo.searchByGid(42)).thenAnswer((_) async {
        if (failedSource == SearchSource.gid) throw Exception('offline');
        return gallery(42);
      });
      bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
      await flush();
      expect(bloc.state.results, hasLength(1));
      expect(bloc.state.status, SearchStatus.loaded);
      when(() => repo.search(any())).thenAnswer((_) async => results([50]));
      when(() => repo.searchByGid(42)).thenAnswer((_) async => gallery(42));
      bloc.add(RetrySearchSource(failedSource));
      await flush();
      expect(bloc.state.results.map((g) => g.gid), [42, 50]);
      expect(bloc.state.errorMessage, isNull);
      expect(bloc.state.gidError, isNull);
      verify(() => repo.search(any()))
          .called(failedSource == SearchSource.ordinary ? 2 : 1);
      verify(() => repo.searchByGid(42))
          .called(failedSource == SearchSource.gid ? 2 : 1);
      verify(() => repo.addSearchHistory('42')).called(1);
    });
  }

  test(
      'empty results wait for both branches; two failures are not an empty success',
      () async {
    final exact = Completer<GalleryPreview?>();
    when(() => repo.search(any())).thenAnswer((_) async => results([]));
    when(() => repo.searchByGid(42)).thenAnswer((_) => exact.future);
    bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
    await flush();
    expect(bloc.state.status, SearchStatus.loading);
    exact.complete(null);
    await flush();
    expect(bloc.state.status, SearchStatus.loaded);
    expect(bloc.state.results, isEmpty);
    when(() => repo.search(any())).thenThrow(Exception('offline'));
    when(() => repo.searchByGid(42)).thenThrow(Exception('offline'));
    bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
    await flush();
    expect(bloc.state.status, SearchStatus.error);
    expect(bloc.state.ordinaryStatus, SearchStatus.error);
    expect(bloc.state.gidStatus, SearchStatus.error);
  });

  for (final clear in [false, true]) {
    test('late results cannot overwrite ${clear ? 'clear' : 'new search'}',
        () async {
      final old = Completer<SearchResult>();
      final exact = Completer<GalleryPreview?>();
      when(() => repo.search(any())).thenAnswer((_) => old.future);
      when(() => repo.searchByGid(42)).thenAnswer((_) => exact.future);
      bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
      await flush();
      when(() => repo.search(any())).thenAnswer((_) async => results([99]));
      bloc.add(clear
          ? ClearSearch()
          : const PerformSearch(SearchFilter(keyword: 'new')));
      await flush();
      old.complete(results([42]));
      exact.complete(gallery(42));
      await flush();
      expect(bloc.state.results.map((g) => g.gid), clear ? [] : [99]);
      expect(bloc.state.matchedGid, isNull);
    });
  }

  test(
      'pagination skips duplicate pages, preserves cursor on failure and deduplicates retry',
      () async {
    when(() => repo.search(any()))
        .thenAnswer((_) async => results([50], next: 'p1'));
    when(() => repo.searchByGid(42)).thenAnswer((_) async => gallery(42));
    when(() => repo.search(any(), page: 1, nextUrl: 'p1'))
        .thenAnswer((_) async => results([42, 50], next: 'p2'));
    when(() => repo.search(any(), page: 2, nextUrl: 'p2'))
        .thenThrow(Exception('offline'));
    bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
    await flush();
    bloc.add(LoadMoreSearchResults());
    await flush();
    expect(bloc.state.results.map((g) => g.gid), [42, 50]);
    expect(bloc.state.nextPageUrl, 'p1');
    expect(bloc.state.loadMoreFailed, isTrue);
    when(() => repo.search(any(), page: 2, nextUrl: 'p2'))
        .thenAnswer((_) async => results([42, 40, 40]));
    bloc.add(LoadMoreSearchResults());
    await flush();
    expect(bloc.state.results.map((g) => g.gid), [42, 50, 40]);
    expect(bloc.state.nextPageUrl, isNull);
    expect(bloc.state.hasReachedEnd, isTrue);
    expect(bloc.state.loadMoreFailed, isFalse);
    verify(() => repo.searchByGid(42)).called(1);
  });

  test('close with pending requests emits no late state', () async {
    final old = Completer<SearchResult>();
    final exact = Completer<GalleryPreview?>();
    when(() => repo.search(any())).thenAnswer((_) => old.future);
    when(() => repo.searchByGid(42)).thenAnswer((_) => exact.future);
    bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
    await flush();
    final close = bloc.close();
    old.complete(results([42]));
    exact.complete(gallery(42));
    await close;
    expect(bloc.state.results, isEmpty);
  });

  test('refresh reruns both sources and ignores an older pending page',
      () async {
    final page = Completer<SearchResult>();
    when(() => repo.search(any()))
        .thenAnswer((_) async => results([50], next: 'p1'));
    when(() => repo.searchByGid(42)).thenAnswer((_) async => gallery(42));
    when(() => repo.search(any(), page: 1, nextUrl: 'p1'))
        .thenAnswer((_) => page.future);
    bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
    await flush();
    bloc.add(LoadMoreSearchResults());
    await flush();
    when(() => repo.search(any())).thenAnswer((_) async => results([99]));
    bloc.add(const PerformSearch(SearchFilter(keyword: '42')));
    await flush();
    page.complete(results([40]));
    await flush();
    expect(bloc.state.results.map((g) => g.gid), [42, 99]);
    expect(bloc.state.isLoadingMore, isFalse);
    expect(bloc.state.nextPageUrl, isNull);
    verify(() => repo.searchByGid(42)).called(2);
  });

  test('copyWith clears nullable fields and equality includes source progress',
      () {
    const state = SearchState(
        errorMessage: 'failure',
        nextPageUrl: 'next',
        gidError: 'failure',
        matchedGid: 42);
    final clean = state.copyWith(
        errorMessage: null,
        nextPageUrl: null,
        gidError: null,
        matchedGid: null);
    expect(clean.errorMessage, isNull);
    expect(clean.nextPageUrl, isNull);
    expect(clean.gidError, isNull);
    expect(clean.matchedGid, isNull);
    expect(clean, isNot(clean.copyWith(gidStatus: SearchStatus.loading)));
  });
}
