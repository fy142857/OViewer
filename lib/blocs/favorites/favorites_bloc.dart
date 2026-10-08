import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../models/gallery_preview.dart';
import '../../repositories/favorites_repository.dart';
import '../../repositories/settings_repository.dart';
import 'favorites_event.dart';
import 'favorites_state.dart';

class FavoritesBloc extends Bloc<FavoritesEvent, FavoritesState> {
  final FavoritesRepository _repository;
  final SettingsRepository? _settings;
  int _generation = 0, _views = 0, _choice = 0;
  Object? _scope;
  bool _signedIn = false;
  bool _closing = false;
  CancelToken? _request;
  Future<void> _cacheReady = Future.value();
  Future<void> _preferences = Future.value();
  final _visited = <String>{};

  static int _saved(SettingsRepository? settings) {
    final value = settings?.getFavoriteCategory() ?? -1;
    return value >= -1 && value <= 9 ? value : -1;
  }

  FavoritesBloc(this._repository, {SettingsRepository? settings})
      : _settings = settings,
        super(FavoritesState(category: _saved(settings))) {
    _repository.changes?.addListener(_favoritesChanged);
    on<FavoritesScopeReset>((event, emit) {
      if (event.generation != _generation) return;
      emit(FavoritesState(
          category: state.category, scopeRevision: state.scopeRevision + 1));
      if (_views > 0 && _signedIn) add(EnsureFavoritesLoaded());
    });
    on<LoadFavorites>((event, emit) => _load(emit));
    on<EnsureFavoritesLoaded>((event, emit) async {
      if (state.status == FavoritesStatus.initial) await _load(emit);
    });
    on<RefreshFavorites>((event, emit) async {
      try {
        await _load(emit);
      } finally {
        if (event.completer?.isCompleted == false) event.completer!.complete();
      }
    });
    on<LoadMoreFavorites>(_more);
    on<SelectFavoriteCategory>(_select);
    on<AddFavorite>((event, emit) async {
      final generation = _generation;
      try {
        await _repository.addCloudFavorite(
            event.gallery.gid, event.gallery.token,
            slot: event.slot, preview: event.gallery);
      } catch (_) {
        if (_current(generation)) {
          emit(state.copyWith(errorMessage: 'favoriteActionFailed'));
        }
      }
      if (_current(generation) && _repository.changes == null) {
        await _load(emit);
      }
    });
    on<RemoveFavorite>((event, emit) async {
      if (event.token == null) return;
      final generation = _generation;
      try {
        await _repository.removeCloudFavorite(event.gid, event.token!);
      } catch (_) {
        if (_current(generation)) {
          emit(state.copyWith(errorMessage: 'favoriteActionFailed'));
        }
        return;
      }
      if (_current(generation) && _repository.changes == null) {
        await _load(emit);
      }
    });
  }

  void _favoritesChanged() {
    if (!_closing &&
        !isClosed &&
        _signedIn &&
        state.status != FavoritesStatus.initial) {
      add(const LoadFavorites());
    }
  }

  /// Called from the app's auth/site listeners; cancel before queued work can emit.
  void syncSession(
      {required String site,
      required bool signedIn,
      required int revision,
      String? account}) {
    final next = (site, signedIn, revision, account);
    if (_scope == next || isClosed || _closing) return;
    final previous = _scope;
    _scope = next;
    _signedIn = signedIn;
    _generation++;
    _request?.cancel('Favorites session changed');
    _visited.clear();
    if (previous != null) {
      _cacheReady = Future<void>.sync(_repository.clearConfirmationCache);
      // Observe errors immediately; _load still awaits and reports a failed clear.
      unawaited(_cacheReady.catchError((Object _) {}));
    }
    add(FavoritesScopeReset(_generation));
  }

  void attachView() {
    _views++;
    if (!isClosed && !_closing) add(EnsureFavoritesLoaded());
  }

  void detachView() {
    if (_views > 0) _views--;
  }

  bool _current(int generation) =>
      !_closing && !isClosed && _signedIn && generation == _generation;

  Future<void> _select(
      SelectFavoriteCategory event, Emitter<FavoritesState> emit) async {
    if (event.category < -1 || event.category > 9 || !_signedIn) return;
    if (event.category == state.category && !state.savingCategory) return;
    final choice = ++_choice;
    emit(state.copyWith(savingCategory: true, errorMessage: null));
    final saved = _preferences
        .then((_) => _settings?.setFavoriteCategory(event.category));
    _preferences =
        saved.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    try {
      await saved;
      if (isClosed || _closing || choice != _choice) return;
      _generation++;
      _request?.cancel('Favorite category changed');
      _visited.clear();
      emit(FavoritesState(
          category: event.category, scopeRevision: state.scopeRevision + 1));
      if (_signedIn) await _load(emit);
    } catch (_) {
      if (!isClosed && choice == _choice) {
        emit(state.copyWith(
            savingCategory: false, errorMessage: 'favoriteFilterSaveFailed'));
      }
    }
  }

  Future<void> _load(Emitter<FavoritesState> emit) async {
    if (!_signedIn || _closing) return;
    final generation = ++_generation;
    _request?.cancel('Favorites refreshed');
    final request = _request = CancelToken();
    final category = state.category;
    emit(state.copyWith(
        status: FavoritesStatus.loading,
        isLoadingMore: false,
        loadMoreFailed: false,
        errorMessage: null));
    try {
      try {
        await _cacheReady;
      } catch (_) {
        if (!_current(generation)) return;
        _cacheReady = Future<void>.sync(_repository.clearConfirmationCache);
        await _cacheReady;
      }
      if (!_current(generation)) return;
      final result = await _repository.fetchCloudFavorites(
          cat: category, cancelToken: request);
      if (!_current(generation)) return;
      await _repository.rebuildCache(result.galleries,
          isCurrent: () => _current(generation));
      if (!_current(generation)) return;
      _visited
        ..clear()
        ..addAll([if (result.requestUrl != null) result.requestUrl!]);
      final seen = <int>{};
      emit(state.copyWith(
          status: FavoritesStatus.loaded,
          favorites: result.galleries.where((g) => seen.add(g.gid)).toList(),
          currentPage: 0,
          totalPages: result.totalPages,
          nextPageUrl: result.nextPageUrl,
          hasReachedEnd: result.nextPageUrl == null,
          errorMessage: null));
    } catch (error) {
      if (kDebugMode) debugPrint('[favorites] load error: $error');
      if (_current(generation)) {
        emit(state.copyWith(
            status: FavoritesStatus.error, errorMessage: 'favoriteLoadFailed'));
      }
    }
  }

  Future<void> _more(
      LoadMoreFavorites event, Emitter<FavoritesState> emit) async {
    if (!_signedIn ||
        state.isLoadingMore ||
        state.status != FavoritesStatus.loaded ||
        state.hasReachedEnd) return;
    final generation = _generation;
    final request = _request ??= CancelToken();
    final category = state.category;
    var url = state.nextPageUrl;
    var page = state.currentPage;
    final visited = {..._visited};
    final ids = state.favorites.map((g) => g.gid).toSet();
    final added = <GalleryPreview>[];
    emit(state.copyWith(
        isLoadingMore: true, loadMoreFailed: false, errorMessage: null));
    try {
      while (url != null && added.isEmpty) {
        if (!visited.add(url)) {
          throw const FormatException('Repeated favorites cursor');
        }
        final result = await _repository.fetchCloudFavorites(
            cat: category, page: page + 1, nextUrl: url, cancelToken: request);
        if (!_current(generation)) return;
        if (result.requestUrl != null &&
            result.requestUrl != url &&
            !visited.add(result.requestUrl!)) {
          throw const FormatException('Repeated favorites page');
        }
        await _repository.rebuildCache(result.galleries,
            isCurrent: () => _current(generation));
        if (!_current(generation)) return;
        added.addAll(result.galleries.where((g) => ids.add(g.gid)));
        url = result.nextPageUrl;
        page++;
      }
      if (!_current(generation)) return;
      _visited
        ..clear()
        ..addAll(visited);
      emit(state.copyWith(
          favorites: [...state.favorites, ...added],
          currentPage: page,
          nextPageUrl: url,
          hasReachedEnd: url == null,
          isLoadingMore: false));
    } catch (_) {
      if (_current(generation)) {
        emit(state.copyWith(isLoadingMore: false, loadMoreFailed: true));
      }
    }
  }

  @override
  Future<void> close() {
    _closing = true;
    _choice++;
    _generation++;
    _repository.changes?.removeListener(_favoritesChanged);
    _request?.cancel('Favorites closed');
    return super.close();
  }
}
