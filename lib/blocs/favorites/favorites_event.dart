import 'dart:async';

import 'package:equatable/equatable.dart';
import '../../models/gallery_preview.dart';
import 'favorites_entry.dart';
export 'favorites_entry.dart';

abstract class FavoritesEvent extends Equatable {
  final FavoritesEntry entry;
  const FavoritesEvent({this.entry = FavoritesEntry.home});
  @override
  List<Object?> get props => [];
}

class LoadFavorites extends FavoritesEvent {
  const LoadFavorites({super.entry});
}

class RefreshFavorites extends FavoritesEvent {
  final Completer<void>? completer;
  const RefreshFavorites({this.completer, super.entry});
  @override
  List<Object?> get props => [];
}

class LoadMoreFavorites extends FavoritesEvent {
  const LoadMoreFavorites({super.entry});
}

class AddFavorite extends FavoritesEvent {
  final GalleryPreview gallery;
  final int slot;
  const AddFavorite({required this.gallery, this.slot = 0, super.entry});
  @override
  List<Object?> get props => [gallery, slot];
}

class RemoveFavorite extends FavoritesEvent {
  final int gid;
  final String? token;
  const RemoveFavorite({required this.gid, this.token, super.entry});
  @override
  List<Object?> get props => [gid];
}

class SelectFavoriteCategory extends FavoritesEvent {
  final int category;
  const SelectFavoriteCategory(this.category, {super.entry});
  @override
  List<Object?> get props => [category];
}

class EnsureFavoritesLoaded extends FavoritesEvent {}

class FavoritesScopeReset extends FavoritesEvent {
  final int generation;
  final bool clearKeyword;
  const FavoritesScopeReset(this.generation, {this.clearKeyword = true});
  @override
  List<Object?> get props => [generation];
}

class SearchFavorites extends FavoritesEvent {
  final String keyword;
  const SearchFavorites(this.keyword, {super.entry});
  @override
  List<Object?> get props => [keyword, entry];
}

class FavoritesInvalidated extends FavoritesEvent {}
