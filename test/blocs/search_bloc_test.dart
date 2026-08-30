import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/search/search_bloc.dart';
import 'package:oviewer/blocs/search/search_event.dart';
import 'package:oviewer/blocs/search/search_state.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/models/search_filter.dart';

class MockSearchRepository extends Mock implements SearchRepository {}

class MockFavoritesRepository extends Mock implements FavoritesRepository {}

void main() {
  late MockSearchRepository mockRepo;
  late MockFavoritesRepository mockFavoritesRepo;

  setUp(() async {
    await GetIt.instance.reset();
    mockRepo = MockSearchRepository();
    mockFavoritesRepo = MockFavoritesRepository();
    registerFallbackValue(const SearchFilter());
    when(() => mockFavoritesRepo.getLocalFavoriteGids())
        .thenAnswer((_) async => <int>{});
    GetIt.instance.registerSingleton<FavoritesRepository>(mockFavoritesRepo);
  });

  tearDown(() => GetIt.instance.reset());

  final testGallery = GalleryPreview(
    gid: 1,
    token: 'abc',
    title: 'Search Result',
    thumbUrl: 'https://thumb.jpg',
    category: 'Doujinshi',
    rating: 3.5,
    uploader: 'user',
    fileCount: 20,
    postedAt: DateTime(2024, 1, 1),
  );

  group('SearchBloc', () {
    blocTest<SearchBloc, SearchState>(
      'PerformSearch emits [loading, loaded] on success',
      setUp: () {
        when(() => mockRepo.search(any())).thenAnswer(
          (_) async => SearchResult(
            galleries: [testGallery],
            totalPages: 3,
            totalResults: 50,
          ),
        );
        when(() => mockRepo.addSearchHistory(any())).thenAnswer((_) async {});
        when(() => mockRepo.getSearchHistory()).thenReturn(['test']);
      },
      build: () => SearchBloc(mockRepo),
      act: (bloc) => bloc.add(
        const PerformSearch(SearchFilter(keyword: 'test')),
      ),
      expect: () => [
        isA<SearchState>()
            .having((s) => s.status, 'status', SearchStatus.loading),
        isA<SearchState>()
            .having((s) => s.status, 'status', SearchStatus.loaded)
            .having((s) => s.results.length, 'results', 1)
            .having((s) => s.totalResults, 'totalResults', 50),
      ],
    );

    blocTest<SearchBloc, SearchState>(
      'ClearSearch resets state and loads history',
      setUp: () {
        when(() => mockRepo.getSearchHistory()).thenReturn(['a', 'b']);
      },
      build: () => SearchBloc(mockRepo),
      seed: () => SearchState(
        status: SearchStatus.loaded,
        results: [testGallery],
      ),
      act: (bloc) => bloc.add(ClearSearch()),
      expect: () => [
        const SearchState(), // reset
        isA<SearchState>().having((s) => s.searchHistory.length, 'history', 2),
      ],
    );

    blocTest<SearchBloc, SearchState>(
      'ClearSearchHistory empties history list',
      setUp: () {
        when(() => mockRepo.clearSearchHistory()).thenAnswer((_) async {});
      },
      build: () => SearchBloc(mockRepo),
      seed: () => const SearchState(searchHistory: ['a', 'b']),
      act: (bloc) => bloc.add(ClearSearchHistory()),
      expect: () => [
        isA<SearchState>().having((s) => s.searchHistory, 'history', isEmpty),
      ],
    );
  });
}
