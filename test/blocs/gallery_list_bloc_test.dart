import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/gallery_list/gallery_list_bloc.dart';
import 'package:oviewer/blocs/gallery_list/gallery_list_event.dart';
import 'package:oviewer/blocs/gallery_list/gallery_list_state.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/models/gallery_preview.dart';

class MockGalleryRepository extends Mock implements GalleryRepository {}

class MockFavoritesRepository extends Mock implements FavoritesRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

void main() {
  late MockGalleryRepository mockRepo;
  late MockFavoritesRepository mockFavoritesRepo;
  late MockSettingsRepository mockSettingsRepo;

  setUp(() {
    mockRepo = MockGalleryRepository();
    mockFavoritesRepo = MockFavoritesRepository();
    mockSettingsRepo = MockSettingsRepository();
    when(() => mockSettingsRepo.getHiddenTags()).thenReturn([]);
    when(() => mockFavoritesRepo.getLocalFavoriteGids())
        .thenAnswer((_) async => <int>{});

    final sl = GetIt.instance;
    if (sl.isRegistered<SettingsRepository>()) {
      sl.unregister<SettingsRepository>();
    }
    sl.registerSingleton<SettingsRepository>(mockSettingsRepo);
    sl.registerSingleton<FavoritesRepository>(mockFavoritesRepo);
  });

  tearDown(() {
    GetIt.instance.reset();
  });

  final testGallery = GalleryPreview(
    gid: 1,
    token: 'abc',
    title: 'Test',
    thumbUrl: 'https://thumb.jpg',
    category: 'Manga',
    rating: 4.0,
    uploader: 'user',
    fileCount: 10,
    postedAt: DateTime(2024, 1, 1),
  );

  final testGallery2 = GalleryPreview(
    gid: 2,
    token: 'def',
    title: 'Test 2',
    thumbUrl: 'https://thumb2.jpg',
    category: 'Manga',
    rating: 3.5,
    uploader: 'user2',
    fileCount: 20,
    postedAt: DateTime(2024, 1, 2),
  );

  const nextUrl = 'https://e-hentai.org/?next=1';
  const nextUrl2 = 'https://e-hentai.org/?next=2';

  group('GalleryListBloc', () {
    blocTest<GalleryListBloc, GalleryListState>(
      'emits [loading, loaded] when FetchGalleries succeeds',
      setUp: () {
        when(() => mockRepo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
            .thenAnswer(
          (_) async => GalleryListResult(
            galleries: [testGallery],
            totalPages: 5,
            nextPageUrl: nextUrl,
          ),
        );
      },
      build: () => GalleryListBloc(mockRepo),
      act: (bloc) => bloc.add(const FetchGalleries()),
      expect: () => [
        const GalleryListState(status: GalleryListStatus.loading),
        GalleryListState(
          status: GalleryListStatus.loaded,
          galleries: [testGallery],
          currentPage: 0,
          totalPages: 5,
          nextPageUrl: nextUrl,
        ),
      ],
    );

    blocTest<GalleryListBloc, GalleryListState>(
      'clears stale galleries before reloading after a site switch',
      setUp: () {
        when(() => mockRepo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
            .thenAnswer(
          (_) async => GalleryListResult(
            galleries: [testGallery2],
            totalPages: 1,
          ),
        );
      },
      build: () => GalleryListBloc(mockRepo),
      seed: () => GalleryListState(
        status: GalleryListStatus.loaded,
        galleries: [testGallery],
        currentPage: 2,
        totalPages: 5,
        nextPageUrl: nextUrl,
      ),
      act: (bloc) => bloc.add(const FetchGalleries(clearExisting: true)),
      expect: () => [
        const GalleryListState(status: GalleryListStatus.loading),
        GalleryListState(
          status: GalleryListStatus.loaded,
          galleries: [testGallery2],
          currentPage: 0,
          totalPages: 1,
          nextPageUrl: 'https://e-hentai.org/?page=1',
        ),
      ],
    );

    blocTest<GalleryListBloc, GalleryListState>(
      'emits [loading, error] when FetchGalleries fails',
      setUp: () {
        when(() => mockRepo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
            .thenThrow(Exception('Network error'));
      },
      build: () => GalleryListBloc(mockRepo),
      act: (bloc) => bloc.add(const FetchGalleries()),
      expect: () => [
        const GalleryListState(status: GalleryListStatus.loading),
        isA<GalleryListState>()
            .having((s) => s.status, 'status', GalleryListStatus.error)
            .having((s) => s.errorMessage, 'errorMessage', isNotNull),
      ],
    );

    blocTest<GalleryListBloc, GalleryListState>(
      'LoadMoreGalleries appends results via cursor pagination',
      setUp: () {
        when(() => mockRepo.fetchGalleryList(nextUrl: nextUrl)).thenAnswer(
          (_) async => GalleryListResult(
            galleries: [testGallery2],
            totalPages: 5,
            nextPageUrl: nextUrl2,
          ),
        );
      },
      build: () => GalleryListBloc(mockRepo),
      seed: () => GalleryListState(
        status: GalleryListStatus.loaded,
        galleries: [testGallery],
        currentPage: 0,
        totalPages: 5,
        nextPageUrl: nextUrl,
      ),
      act: (bloc) => bloc.add(LoadMoreGalleries()),
      expect: () => [
        isA<GalleryListState>()
            .having((s) => s.isLoadingMore, 'isLoadingMore', true),
        isA<GalleryListState>()
            .having((s) => s.galleries.length, 'galleries.length', 2)
            .having((s) => s.currentPage, 'currentPage', 1)
            .having((s) => s.isLoadingMore, 'isLoadingMore', false)
            .having((s) => s.nextPageUrl, 'nextPageUrl', nextUrl2),
      ],
    );

    blocTest<GalleryListBloc, GalleryListState>(
      'does not load more when already at end',
      build: () => GalleryListBloc(mockRepo),
      seed: () => GalleryListState(
        status: GalleryListStatus.loaded,
        galleries: [testGallery],
        currentPage: 4,
        totalPages: 5,
        hasReachedEnd: true,
      ),
      act: (bloc) => bloc.add(LoadMoreGalleries()),
      expect: () => [],
    );

    blocTest<GalleryListBloc, GalleryListState>(
      'sets hasReachedEnd when nextPageUrl is null',
      setUp: () {
        when(() => mockRepo.fetchGalleryList(nextUrl: any(named: 'nextUrl')))
            .thenAnswer(
          (_) async => const GalleryListResult(
            galleries: [],
            totalPages: 1,
            nextPageUrl: null,
          ),
        );
      },
      build: () => GalleryListBloc(mockRepo),
      act: (bloc) => bloc.add(const FetchGalleries()),
      expect: () => [
        const GalleryListState(status: GalleryListStatus.loading),
        isA<GalleryListState>()
            .having((s) => s.hasReachedEnd, 'hasReachedEnd', true),
      ],
    );
  });
}
