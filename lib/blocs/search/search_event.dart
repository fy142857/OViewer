import 'package:equatable/equatable.dart';
import '../../models/search_filter.dart';

abstract class SearchEvent extends Equatable {
  const SearchEvent();
  @override
  List<Object?> get props => [];
}

class PerformSearch extends SearchEvent {
  final SearchFilter filter;
  final bool saveHistory;
  const PerformSearch(this.filter, {this.saveHistory = true});
  @override
  List<Object?> get props => [filter, saveHistory];
}

class LoadMoreSearchResults extends SearchEvent {}

enum SearchSource { ordinary, gid }

class RetrySearchSource extends SearchEvent {
  final SearchSource source;
  const RetrySearchSource(this.source);
  @override
  List<Object?> get props => [source];
}

class ClearSearch extends SearchEvent {}

class LoadSearchHistory extends SearchEvent {}

class ClearSearchHistory extends SearchEvent {}

class RemoveSearchHistoryItem extends SearchEvent {
  final String keyword;
  const RemoveSearchHistoryItem(this.keyword);
  @override
  List<Object?> get props => [keyword];
}

class RefreshSearchFavoriteMarks extends SearchEvent {}
