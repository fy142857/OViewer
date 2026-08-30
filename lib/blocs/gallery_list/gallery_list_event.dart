import 'dart:async';

import 'package:equatable/equatable.dart';

abstract class GalleryListEvent extends Equatable {
  const GalleryListEvent();
  @override
  List<Object?> get props => [];
}

class FetchGalleries extends GalleryListEvent {
  final int page;
  final bool clearExisting;
  const FetchGalleries({this.page = 0, this.clearExisting = false});
  @override
  List<Object?> get props => [page, clearExisting];
}

class RefreshGalleries extends GalleryListEvent {
  final Completer<void>? completer;
  RefreshGalleries({this.completer});
  @override
  List<Object?> get props => [];
}

class LoadMoreGalleries extends GalleryListEvent {}

class SwitchGalleryTab extends GalleryListEvent {
  final GalleryTab tab;
  const SwitchGalleryTab(this.tab);
  @override
  List<Object?> get props => [tab];
}

class RefreshFavoriteMarks extends GalleryListEvent {}

enum GalleryTab { latest, popular, watched, favorites }
