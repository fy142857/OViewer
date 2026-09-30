import 'package:equatable/equatable.dart';
import '../../models/gallery_preview.dart';
import '../../models/search_filter.dart';

const _sentinel = Object();

enum SearchStatus { initial, loading, loaded, error }

class SearchState extends Equatable {
  final SearchStatus status;
  final SearchStatus ordinaryStatus;
  final SearchStatus gidStatus;
  final int? matchedGid;
  final String? gidError;
  final bool loadMoreFailed;
  final SearchFilter filter;
  final List<GalleryPreview> results;
  final List<String> searchHistory;
  final int currentPage;
  final int totalPages;
  final int totalResults;
  final bool isLoadingMore;
  final bool hasReachedEnd;
  final String? errorMessage;
  final String? nextPageUrl;

  const SearchState({
    this.status = SearchStatus.initial,
    this.ordinaryStatus = SearchStatus.initial,
    this.gidStatus = SearchStatus.initial,
    this.matchedGid,
    this.gidError,
    this.loadMoreFailed = false,
    this.filter = const SearchFilter(),
    this.results = const [],
    this.searchHistory = const [],
    this.currentPage = 0,
    this.totalPages = 0,
    this.totalResults = 0,
    this.isLoadingMore = false,
    this.hasReachedEnd = false,
    this.errorMessage,
    this.nextPageUrl,
  });

  SearchState copyWith({
    SearchStatus? status,
    SearchStatus? ordinaryStatus,
    SearchStatus? gidStatus,
    Object? matchedGid = _sentinel,
    Object? gidError = _sentinel,
    bool? loadMoreFailed,
    SearchFilter? filter,
    List<GalleryPreview>? results,
    List<String>? searchHistory,
    int? currentPage,
    int? totalPages,
    int? totalResults,
    bool? isLoadingMore,
    bool? hasReachedEnd,
    Object? errorMessage = _sentinel,
    Object? nextPageUrl = _sentinel,
  }) {
    return SearchState(
      status: status ?? this.status,
      ordinaryStatus: ordinaryStatus ?? this.ordinaryStatus,
      gidStatus: gidStatus ?? this.gidStatus,
      matchedGid:
          matchedGid == _sentinel ? this.matchedGid : matchedGid as int?,
      gidError: gidError == _sentinel ? this.gidError : gidError as String?,
      loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
      filter: filter ?? this.filter,
      results: results ?? this.results,
      searchHistory: searchHistory ?? this.searchHistory,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      totalResults: totalResults ?? this.totalResults,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasReachedEnd: hasReachedEnd ?? this.hasReachedEnd,
      errorMessage: errorMessage == _sentinel
          ? this.errorMessage
          : errorMessage as String?,
      nextPageUrl:
          nextPageUrl == _sentinel ? this.nextPageUrl : nextPageUrl as String?,
    );
  }

  @override
  List<Object?> get props => [
        status,
        ordinaryStatus,
        gidStatus,
        matchedGid,
        gidError,
        loadMoreFailed,
        errorMessage,
        totalPages,
        totalResults,
        filter,
        results,
        searchHistory,
        currentPage,
        isLoadingMore,
        hasReachedEnd,
        nextPageUrl,
      ];
}
