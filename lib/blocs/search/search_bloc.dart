import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../models/gallery_preview.dart';
import '../../core/constants/app_constants.dart';
import '../../repositories/favorites_repository.dart';
import '../../repositories/search_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  final SearchRepository _repository;
  int _generation = 0;
  String? _site;

  SearchBloc(this._repository) : super(const SearchState()) {
    on<PerformSearch>(_onSearch);
    on<RetrySearchSource>(_onRetry);
    on<LoadMoreSearchResults>(_onLoadMore);
    on<ClearSearch>(_onClear);
    on<LoadSearchHistory>(_onLoadHistory);
    on<ClearSearchHistory>(_onClearHistory);
    on<RemoveSearchHistoryItem>(_onRemoveHistoryItem);
    on<RefreshSearchFavoriteMarks>(_onRefreshFavoriteMarks);
  }

  bool _active(int generation, Emitter<SearchState> emit) =>
      generation == _generation &&
      !emit.isDone &&
      !isClosed &&
      _site == AppConstants.baseUrl;

  void _publish(SearchState next, Emitter<SearchState> emit) {
    final pending = next.ordinaryStatus == SearchStatus.loading ||
        next.gidStatus == SearchStatus.loading;
    final failed = next.ordinaryStatus == SearchStatus.error ||
        next.gidStatus == SearchStatus.error;
    emit(next.copyWith(
        status: pending
            ? SearchStatus.loading
            : failed && next.results.isEmpty
                ? SearchStatus.error
                : SearchStatus.loaded));
  }

  List<GalleryPreview> _unique(Iterable<GalleryPreview> galleries) {
    final seen = <int>{};
    return galleries.where((g) => seen.add(g.gid)).toList();
  }

  Future<void> _onSearch(PerformSearch event, Emitter<SearchState> emit) async {
    final generation = ++_generation;
    _site = AppConstants.baseUrl;
    final gid = SearchRepository.parseGid(event.filter.keyword ?? '');
    emit(SearchState(
      status: SearchStatus.loading,
      ordinaryStatus: SearchStatus.loading,
      gidStatus: gid == null ? SearchStatus.initial : SearchStatus.loading,
      filter: event.filter,
      searchHistory: state.searchHistory,
    ));
    // Start both network paths before waiting on history or either response.
    await Future.wait([
      _ordinary(generation, emit),
      if (gid != null) _gid(gid, generation, emit),
      _saveHistory(event, generation, emit),
    ]);
  }

  Future<void> _saveHistory(
      PerformSearch event, int generation, Emitter<SearchState> emit) async {
    try {
      final keyword = event.filter.keyword;
      if (event.saveHistory && keyword != null && keyword.isNotEmpty) {
        await _repository.addSearchHistory(keyword);
      }
      if (_active(generation, emit)) {
        emit(state.copyWith(searchHistory: _repository.getSearchHistory()));
      }
    } catch (_) {
      // History persistence must not discard successful network results.
    }
  }

  Future<void> _ordinary(int generation, Emitter<SearchState> emit) async {
    final filter = state.filter;
    try {
      final result = await _repository.search(filter);
      if (!_active(generation, emit)) return;
      final marked = await _markFavorites(result.galleries);
      if (!_active(generation, emit)) return;
      _publish(
          state.copyWith(
            ordinaryStatus: SearchStatus.loaded,
            errorMessage: null,
            results: _unique([
              ...state.results.where((g) => g.gid == state.matchedGid),
              ...marked
            ]),
            currentPage: 0,
            totalPages: result.totalPages,
            totalResults: result.totalResults,
            hasReachedEnd: result.nextPageUrl == null,
            nextPageUrl: result.nextPageUrl,
          ),
          emit);
    } catch (e) {
      if (_active(generation, emit)) {
        _publish(
            state.copyWith(
                ordinaryStatus: SearchStatus.error, errorMessage: e.toString()),
            emit);
      }
    }
  }

  Future<void> _gid(int gid, int generation, Emitter<SearchState> emit) async {
    try {
      final result = await _repository.searchByGid(gid);
      if (!_active(generation, emit)) return;
      final marked =
          result == null ? <GalleryPreview>[] : await _markFavorites([result]);
      if (!_active(generation, emit)) return;
      _publish(
          state.copyWith(
            gidStatus: SearchStatus.loaded,
            gidError: null,
            matchedGid: result?.gid,
            results: _unique([...marked, ...state.results]),
          ),
          emit);
    } catch (e) {
      if (_active(generation, emit)) {
        _publish(
            state.copyWith(
                gidStatus: SearchStatus.error, gidError: e.toString()),
            emit);
      }
    }
  }

  Future<void> _onRetry(
      RetrySearchSource event, Emitter<SearchState> emit) async {
    final generation = _generation;
    if (!_active(generation, emit)) return;
    if (event.source == SearchSource.gid &&
        state.gidStatus == SearchStatus.error) {
      final gid = SearchRepository.parseGid(state.filter.keyword ?? '');
      if (gid == null) return;
      _publish(state.copyWith(gidStatus: SearchStatus.loading, gidError: null),
          emit);
      await _gid(gid, generation, emit);
    } else if (event.source == SearchSource.ordinary &&
        state.ordinaryStatus == SearchStatus.error) {
      _publish(
          state.copyWith(
              ordinaryStatus: SearchStatus.loading, errorMessage: null),
          emit);
      await _ordinary(generation, emit);
    }
  }

  Future<void> _onLoadMore(
      LoadMoreSearchResults event, Emitter<SearchState> emit) async {
    if (state.ordinaryStatus != SearchStatus.loaded ||
        state.isLoadingMore ||
        state.hasReachedEnd ||
        state.nextPageUrl == null) return;
    final generation = _generation;
    final filter = state.filter;
    var cursor = state.nextPageUrl;
    var page = state.currentPage;
    final visited = <String>{};
    emit(state.copyWith(isLoadingMore: true, loadMoreFailed: false));
    try {
      // Skip duplicate-only pages without ending a still-live result stream.
      while (cursor != null) {
        if (!visited.add(cursor))
          throw const FormatException('Repeated search cursor');
        final result =
            await _repository.search(filter, page: ++page, nextUrl: cursor);
        if (!_active(generation, emit)) return;
        final marked = await _markFavorites(result.galleries);
        if (!_active(generation, emit)) return;
        final merged = _unique([...state.results, ...marked]);
        cursor = result.nextPageUrl;
        if (merged.length > state.results.length || cursor == null) {
          emit(state.copyWith(
              results: merged,
              currentPage: page,
              isLoadingMore: false,
              nextPageUrl: cursor,
              hasReachedEnd: cursor == null));
          return;
        }
      }
    } catch (_) {
      if (_active(generation, emit)) {
        emit(state.copyWith(isLoadingMore: false, loadMoreFailed: true));
      }
    }
  }

  void _onClear(ClearSearch event, Emitter<SearchState> emit) {
    ++_generation;
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
    final generation = _generation;
    final original = state.results;
    final marked = await _markFavorites(original, fromNetwork: false);
    if (_active(generation, emit) && identical(original, state.results)) {
      emit(state.copyWith(results: marked));
    }
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
