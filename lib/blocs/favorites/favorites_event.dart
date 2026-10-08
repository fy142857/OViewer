import 'dart:async';

import 'package:equatable/equatable.dart';
import '../../models/gallery_preview.dart';

abstract class FavoritesEvent extends Equatable {
  const FavoritesEvent();
  @override
  List<Object?> get props => [];
}

class LoadFavorites extends FavoritesEvent {
  const LoadFavorites();
}

class RefreshFavorites extends FavoritesEvent {
  final Completer<void>? completer;
  const RefreshFavorites({this.completer});
  @override
  List<Object?> get props => [];
}

class LoadMoreFavorites extends FavoritesEvent {}

class AddFavorite extends FavoritesEvent {
  final GalleryPreview gallery;
  final int slot;
  const AddFavorite({required this.gallery, this.slot = 0});
  @override
  List<Object?> get props => [gallery, slot];
}

class RemoveFavorite extends FavoritesEvent {
  final int gid;
  final String? token;
  const RemoveFavorite({required this.gid, this.token});
  @override
  List<Object?> get props => [gid];
}

class SelectFavoriteCategory extends FavoritesEvent {
  final int category;
  const SelectFavoriteCategory(this.category);
  @override
  List<Object?> get props => [category];
}

class EnsureFavoritesLoaded extends FavoritesEvent {}

class FavoritesScopeReset extends FavoritesEvent {
  final int generation;
  const FavoritesScopeReset(this.generation);
  @override
  List<Object?> get props => [generation];
}
