import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/favorites_repository.dart';
import 'favorites_event.dart';
import 'favorites_state.dart';

class FavoritesBloc extends Bloc<FavoritesEvent, FavoritesState> {
  final FavoritesRepository _repository;

  FavoritesBloc(this._repository) : super(const FavoritesState()) {
    on<LoadFavorites>(_onLoad);
    on<RefreshFavorites>(_onRefresh);
    on<LoadMoreFavorites>(_onLoadMore);
    on<AddFavorite>(_onAdd);
    on<RemoveFavorite>(_onRemove);
  }

  Future<void> _onLoad(
    LoadFavorites event,
    Emitter<FavoritesState> emit,
  ) async {
    emit(state.copyWith(status: FavoritesStatus.loading));
    try {
      final result = await _repository.fetchCloudFavorites();
      // Merge this page; unseen favorites may be on later pages.
      await _repository.rebuildCache(result.galleries);
      emit(state.copyWith(
        status: FavoritesStatus.loaded,
        favorites: result.galleries,
        totalPages: result.totalPages,
        currentPage: 0,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: FavoritesStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> _onRefresh(
    RefreshFavorites event,
    Emitter<FavoritesState> emit,
  ) async {
    try {
      final result = await _repository.fetchCloudFavorites();
      await _repository.rebuildCache(result.galleries);
      emit(state.copyWith(
        status: FavoritesStatus.loaded,
        favorites: result.galleries,
        totalPages: result.totalPages,
        currentPage: 0,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: FavoritesStatus.error,
        errorMessage: e.toString(),
      ));
    } finally {
      event.completer?.complete();
    }
  }

  Future<void> _onLoadMore(
    LoadMoreFavorites event,
    Emitter<FavoritesState> emit,
  ) async {
    if (state.isLoadingMore) return;
    emit(state.copyWith(isLoadingMore: true));
    try {
      final nextPage = state.currentPage + 1;
      final result = await _repository.fetchCloudFavorites(page: nextPage);
      await _repository.rebuildCache(result.galleries);
      emit(state.copyWith(
        favorites: [...state.favorites, ...result.galleries],
        currentPage: nextPage,
        isLoadingMore: false,
      ));
    } catch (_) {
      emit(state.copyWith(isLoadingMore: false));
    }
  }

  Future<void> _onAdd(
    AddFavorite event,
    Emitter<FavoritesState> emit,
  ) async {
    try {
      await _repository.addCloudFavorite(
        event.gallery.gid,
        event.gallery.token,
        slot: event.slot,
        preview: event.gallery,
      );
    } catch (_) {
      // Cloud add failed silently
    }
    add(const LoadFavorites());
  }

  Future<void> _onRemove(
    RemoveFavorite event,
    Emitter<FavoritesState> emit,
  ) async {
    if (event.token != null) {
      try {
        await _repository.removeCloudFavorite(event.gid, event.token!);
      } catch (_) {
        // Cloud removal failed silently
      }
    }
    add(const LoadFavorites());
  }
}
