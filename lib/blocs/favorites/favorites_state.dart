import 'package:equatable/equatable.dart';
import '../../models/gallery_preview.dart';

enum FavoritesStatus { initial, loading, loaded, error }

const _unset = Object();

class FavoritesState extends Equatable {
  final String keyword;
  final FavoritesStatus status;
  final List<GalleryPreview> favorites;
  final int category, currentPage, totalPages, scopeRevision;
  final bool isLoadingMore, hasReachedEnd, loadMoreFailed, savingCategory;
  final String? nextPageUrl, errorMessage;
  const FavoritesState(
      {this.keyword = '',
      this.status = FavoritesStatus.initial,
      this.favorites = const [],
      this.category = -1,
      this.currentPage = 0,
      this.totalPages = 1,
      this.scopeRevision = 0,
      this.isLoadingMore = false,
      this.hasReachedEnd = false,
      this.loadMoreFailed = false,
      this.savingCategory = false,
      this.nextPageUrl,
      this.errorMessage});
  FavoritesState copyWith(
          {String? keyword,
          FavoritesStatus? status,
          List<GalleryPreview>? favorites,
          int? category,
          int? currentPage,
          int? totalPages,
          int? scopeRevision,
          bool? isLoadingMore,
          bool? hasReachedEnd,
          bool? loadMoreFailed,
          bool? savingCategory,
          Object? nextPageUrl = _unset,
          Object? errorMessage = _unset}) =>
      FavoritesState(
          keyword: keyword ?? this.keyword,
          status: status ?? this.status,
          favorites: favorites ?? this.favorites,
          category: category ?? this.category,
          currentPage: currentPage ?? this.currentPage,
          totalPages: totalPages ?? this.totalPages,
          scopeRevision: scopeRevision ?? this.scopeRevision,
          isLoadingMore: isLoadingMore ?? this.isLoadingMore,
          hasReachedEnd: hasReachedEnd ?? this.hasReachedEnd,
          loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
          savingCategory: savingCategory ?? this.savingCategory,
          nextPageUrl: identical(nextPageUrl, _unset)
              ? this.nextPageUrl
              : nextPageUrl as String?,
          errorMessage: identical(errorMessage, _unset)
              ? this.errorMessage
              : errorMessage as String?);
  @override
  List<Object?> get props => [
        keyword,
        status,
        favorites,
        category,
        currentPage,
        totalPages,
        scopeRevision,
        isLoadingMore,
        hasReachedEnd,
        loadMoreFailed,
        savingCategory,
        nextPageUrl,
        errorMessage
      ];
}
