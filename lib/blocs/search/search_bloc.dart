import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../models/gallery_preview.dart';
import '../../repositories/favorites_repository.dart';
import '../../repositories/search_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  final SearchRepository _repository;

  SearchBloc(this._repository) : super(const SearchState()) {
    on<PerformSearch>(_onSearch);
    on<LoadMoreSearchResults>(_onLoadMore);
    on<ClearSearch>(_onClear);
    on<LoadSearchHistory>(_onLoadHistory);
    on<ClearSearchHistory>(_onClearHistory);
    on<RemoveSearchHistoryItem>(_onRemoveHistoryItem);
    on<RefreshSearchFavoriteMarks>(_onRefreshFavoriteMarks);
  }

  Future<void> _onSearch(
    PerformSearch event,
    Emitter<SearchState> emit,
  ) async {
    emit(state.copyWith(
      status: SearchStatus.loading,
      filter: event.filter,
    ));

    // Save to history (skip for similar-gallery searches)
    if (event.saveHistory &&
        event.filter.keyword != null &&
        event.filter.keyword!.isNotEmpty) {
      await _repository.addSearchHistory(event.filter.keyword!);
    }

    try {
      final result = await _repository.search(event.filter);
      final marked = await _markFavorites(result.galleries);
      emit(state.copyWith(
        status: SearchStatus.loaded,
        results: marked,
        currentPage: 0,
        totalPages: result.totalPages,
        totalResults: result.totalResults,
        searchHistory: _repository.getSearchHistory(),
        hasReachedEnd: result.galleries.isEmpty || result.nextPageUrl == null,
        nextPageUrl: result.nextPageUrl,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: SearchStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> _onLoadMore(
    LoadMoreSearchResults event,
    Emitter<SearchState> emit,
  ) async {
    if (state.isLoadingMore || state.hasReachedEnd) return;
    if (state.nextPageUrl == null) {
      emit(state.copyWith(hasReachedEnd: true));
      return;
    }

    emit(state.copyWith(isLoadingMore: true));

    try {
      final nextPage = state.currentPage + 1;
      final result = await _repository.search(
        state.filter,
        page: nextPage,
        nextUrl: state.nextPageUrl,
      );
      if (result.galleries.isEmpty) {
        emit(state.copyWith(
          isLoadingMore: false,
          hasReachedEnd: true,
        ));
        return;
      }
      final marked = await _markFavorites(result.galleries);
      emit(state.copyWith(
        results: [...state.results, ...marked],
        currentPage: nextPage,
        isLoadingMore: false,
        nextPageUrl: result.nextPageUrl,
        hasReachedEnd: result.nextPageUrl == null,
      ));
    } catch (_) {
      emit(state.copyWith(isLoadingMore: false));
    }
  }

  void _onClear(ClearSearch event, Emitter<SearchState> emit) {
    emit(const SearchState());
    add(LoadSearchHistory());
  }

  void _onLoadHistory(LoadSearchHistory event, Emitter<SearchState> emit) {
    emit(state.copyWith(searchHistory: _repository.getSearchHistory()));
  }

  Future<void> _onClearHistory(
    ClearSearchHistory event,
    Emitter<SearchState> emit,
  ) async {
    await _repository.clearSearchHistory();
    emit(state.copyWith(searchHistory: []));
  }

  Future<void> _onRemoveHistoryItem(
    RemoveSearchHistoryItem event,
    Emitter<SearchState> emit,
  ) async {
    await _repository.removeSearchHistory(event.keyword);
    emit(state.copyWith(searchHistory: _repository.getSearchHistory()));
  }

  Future<void> _onRefreshFavoriteMarks(
    RefreshSearchFavoriteMarks event,
    Emitter<SearchState> emit,
  ) async {
    if (state.results.isEmpty) return;
    final marked = await _markFavorites(state.results, fromNetwork: false);
    emit(state.copyWith(results: marked));
  }

  Future<List<GalleryPreview>> _markFavorites(List<GalleryPreview> galleries,
      {bool fromNetwork = true}) async {
    final favorites = GetIt.I<FavoritesRepository>();
    if (fromNetwork && galleries.any((g) => g.cloudFavorited != null)) {
      await favorites.cacheFavoriteStates(galleries);
    }
    final favGids = await favorites.getLocalFavoriteGids();
    return galleries
        .map((g) => g.copyWith(
            isFavorited: fromNetwork
                ? g.cloudFavorited ?? (g.isFavorited || favGids.contains(g.gid))
                : favGids.contains(g.gid)))
        .toList();
  }
}
