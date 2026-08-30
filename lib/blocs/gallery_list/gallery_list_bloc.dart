import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import '../../core/constants/api_endpoints.dart';
import '../../models/gallery_preview.dart';
import '../../repositories/favorites_repository.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/settings_repository.dart';
import 'gallery_list_event.dart';
import 'gallery_list_state.dart';

class GalleryListBloc extends Bloc<GalleryListEvent, GalleryListState> {
  static final _log = Logger();
  final GalleryRepository _repository;

  /// Max consecutive duplicate-only pages before giving up.
  static const _maxDuplicateRetries = 5;

  GalleryListBloc(this._repository) : super(const GalleryListState()) {
    on<FetchGalleries>(_onFetchGalleries);
    on<RefreshGalleries>(_onRefreshGalleries);
    on<LoadMoreGalleries>(_onLoadMoreGalleries);
    on<SwitchGalleryTab>(_onSwitchTab);
    on<RefreshFavoriteMarks>(_onRefreshFavoriteMarks);
  }

  Future<void> _onFetchGalleries(
    FetchGalleries event,
    Emitter<GalleryListState> emit,
  ) async {
    if (event.clearExisting) {
      emit(state.copyWith(
        status: GalleryListStatus.loading,
        galleries: const [],
        currentPage: 0,
        totalPages: 1,
        hasReachedEnd: false,
        nextPageUrl: null,
      ));
    } else {
      emit(state.copyWith(status: GalleryListStatus.loading));
    }
    try {
      final result = await _fetchForTab(state.currentTab);
      _log.i('[FetchGalleries] tab=${state.currentTab} '
          'got=${result.galleries.length} '
          'pages=${result.totalPages} '
          'nextUrl=${result.nextPageUrl ?? "null"}');

      final filtered = _filterHiddenTags(result.galleries);
      final marked = await _markFavorites(filtered);

      // If parser found galleries but no nextPageUrl, construct fallback
      final nextUrl = result.nextPageUrl ?? _buildFallbackNextUrl(0);

      emit(state.copyWith(
        status: GalleryListStatus.loaded,
        galleries: marked,
        currentPage: 0,
        totalPages: result.totalPages,
        hasReachedEnd: result.galleries.isEmpty && result.nextPageUrl == null,
        nextPageUrl: nextUrl,
        errorMessage: null,
      ));
    } catch (e) {
      _log.e('[FetchGalleries] error: $e');
      emit(state.copyWith(
        status: GalleryListStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> _onRefreshGalleries(
    RefreshGalleries event,
    Emitter<GalleryListState> emit,
  ) async {
    try {
      final result = await _fetchForTab(state.currentTab);
      final filtered = _filterHiddenTags(result.galleries);
      final marked = await _markFavorites(filtered);
      final nextUrl = result.nextPageUrl ?? _buildFallbackNextUrl(0);

      emit(state.copyWith(
        status: GalleryListStatus.loaded,
        galleries: marked,
        currentPage: 0,
        totalPages: result.totalPages,
        hasReachedEnd: result.galleries.isEmpty && result.nextPageUrl == null,
        nextPageUrl: nextUrl,
        errorMessage: null,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: GalleryListStatus.error,
        errorMessage: e.toString(),
      ));
    } finally {
      event.completer?.complete();
    }
  }

  Future<void> _onLoadMoreGalleries(
    LoadMoreGalleries event,
    Emitter<GalleryListState> emit,
  ) async {
    if (state.isLoadingMore || state.hasReachedEnd) return;

    // No next URL and no way to construct one — we're done
    if (state.nextPageUrl == null) {
      final fallback = _buildFallbackNextUrl(state.currentPage);
      if (fallback == null) {
        emit(state.copyWith(hasReachedEnd: true));
        return;
      }
      // Use fallback URL
      emit(state.copyWith(nextPageUrl: fallback));
    }

    emit(state.copyWith(isLoadingMore: true, errorMessage: null));

    int duplicateRetries = 0;
    int page = state.currentPage;
    String? currentNextUrl = state.nextPageUrl;
    List<GalleryPreview> accumulated = [];

    // Loop to skip all-duplicate pages automatically
    while (duplicateRetries < _maxDuplicateRetries) {
      try {
        page = page + 1;
        _log.i('[LoadMore] fetching page $page via $currentNextUrl');
        final result = await _fetchForTab(
          state.currentTab,
          nextUrl: currentNextUrl,
        );
        final newGalleries = result.galleries;
        _log.i('[LoadMore] got ${newGalleries.length} galleries, '
            'nextUrl=${result.nextPageUrl ?? "null"}');

        if (newGalleries.isEmpty) {
          // Truly empty page — we're at the end
          emit(state.copyWith(
            currentPage: page,
            isLoadingMore: false,
            hasReachedEnd: true,
            nextPageUrl: null,
          ));
          return;
        }

        // Deduplicate by gid
        final existingGids = state.galleries.map((g) => g.gid).toSet();
        for (final g in accumulated) {
          existingGids.add(g.gid);
        }
        final unique =
            newGalleries.where((g) => !existingGids.contains(g.gid)).toList();
        final filtered = _filterHiddenTags(unique);
        _log.i('[LoadMore] after dedup: ${unique.length} new '
            '(${newGalleries.length - unique.length} duplicates)');

        accumulated.addAll(filtered);

        // Determine next URL with fallback
        final nextUrl = result.nextPageUrl ?? _buildFallbackNextUrl(page);
        final reachedEnd = nextUrl == null;

        if (unique.isNotEmpty || reachedEnd) {
          // Got new items or reached the end — emit and stop
          emit(state.copyWith(
            galleries: [...state.galleries, ...accumulated],
            currentPage: page,
            totalPages: result.totalPages,
            isLoadingMore: false,
            nextPageUrl: nextUrl,
            hasReachedEnd: reachedEnd,
            errorMessage: null,
          ));
          return;
        }

        // All duplicates on this page — advance and retry
        currentNextUrl = nextUrl;
        duplicateRetries++;
        _log.i('[LoadMore] all duplicates, auto-retrying '
            '($duplicateRetries/$_maxDuplicateRetries)');
      } catch (e) {
        _log.e('[LoadMore] error on page $page: $e');
        emit(state.copyWith(
          galleries: accumulated.isNotEmpty
              ? [...state.galleries, ...accumulated]
              : null,
          currentPage: page,
          isLoadingMore: false,
          nextPageUrl: currentNextUrl,
          errorMessage: e.toString(),
        ));
        return;
      }
    }

    // Exhausted duplicate retries — emit what we have
    _log.w('[LoadMore] exhausted $duplicateRetries duplicate retries');
    emit(state.copyWith(
      galleries:
          accumulated.isNotEmpty ? [...state.galleries, ...accumulated] : null,
      currentPage: page,
      isLoadingMore: false,
      nextPageUrl: currentNextUrl,
      hasReachedEnd: true,
    ));
  }

  Future<void> _onRefreshFavoriteMarks(
    RefreshFavoriteMarks event,
    Emitter<GalleryListState> emit,
  ) async {
    if (state.galleries.isEmpty) return;
    final marked = await _markFavorites(
      state.galleries.map((g) => g.copyWith(isFavorited: false)).toList(),
    );
    emit(state.copyWith(galleries: marked));
  }

  Future<void> _onSwitchTab(
    SwitchGalleryTab event,
    Emitter<GalleryListState> emit,
  ) async {
    emit(GalleryListState(currentTab: event.tab));
    // The watched tab now displays local history; skip network fetch.
    if (event.tab == GalleryTab.watched) return;
    add(const FetchGalleries());
  }

  /// Mark galleries that are in local favorites.
  Future<List<GalleryPreview>> _markFavorites(
      List<GalleryPreview> galleries) async {
    final favGids = await GetIt.I<FavoritesRepository>().getLocalFavoriteGids();
    if (favGids.isEmpty) return galleries;
    return galleries
        .map((g) => favGids.contains(g.gid) ? g.copyWith(isFavorited: true) : g)
        .toList();
  }

  /// Filter galleries by removing those whose tags intersect with hidden tags.
  List<GalleryPreview> _filterHiddenTags(List<GalleryPreview> galleries) {
    final settingsRepo = GetIt.I<SettingsRepository>();
    final hiddenTags = settingsRepo.getHiddenTags();
    if (hiddenTags.isEmpty) return galleries;
    final hiddenSet = hiddenTags.toSet();
    return galleries
        .where((g) => g.tags.every((t) => !hiddenSet.contains(t)))
        .toList();
  }

  /// Build a fallback next-page URL from page number when the parser
  /// fails to extract a next URL from the HTML.
  String? _buildFallbackNextUrl(int currentPage) {
    switch (state.currentTab) {
      case GalleryTab.popular:
        return null; // Popular has no pagination
      case GalleryTab.latest:
        return ApiEndpoints.galleryList(page: currentPage + 1);
      case GalleryTab.watched:
        return ApiEndpoints.watched(page: currentPage + 1);
      case GalleryTab.favorites:
        return ApiEndpoints.favorites(page: currentPage + 1);
    }
  }

  /// Fetch gallery list for a tab. When [nextUrl] is provided it is used
  /// for cursor-based pagination; otherwise the first page is fetched.
  Future<GalleryListResult> _fetchForTab(
    GalleryTab tab, {
    String? nextUrl,
  }) {
    switch (tab) {
      case GalleryTab.popular:
        return _repository.fetchPopularList();
      case GalleryTab.watched:
        return _repository.fetchWatched(nextUrl: nextUrl);
      case GalleryTab.favorites:
        return _repository.fetchFavoritesList(nextUrl: nextUrl);
      case GalleryTab.latest:
      default:
        return _repository.fetchGalleryList(nextUrl: nextUrl);
    }
  }
}
