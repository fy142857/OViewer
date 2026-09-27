import 'package:equatable/equatable.dart';

abstract class GalleryDetailEvent extends Equatable {
  const GalleryDetailEvent();
  @override
  List<Object?> get props => [];
}

class FetchGalleryDetail extends GalleryDetailEvent {
  final int gid;
  final String token;
  const FetchGalleryDetail({required this.gid, required this.token});
  @override
  List<Object?> get props => [gid, token];
}

class ToggleFavorite extends GalleryDetailEvent {
  final int gid;
  final String token;
  final int? slot;
  const ToggleFavorite({required this.gid, required this.token, this.slot});
  @override
  List<Object?> get props => [gid, token, slot];
}

class RateGallery extends GalleryDetailEvent {
  final int gid;
  final String token;
  final double rating;
  const RateGallery(
      {required this.gid, required this.token, required this.rating});
  @override
  List<Object?> get props => [gid, token, rating];
}

class PostComment extends GalleryDetailEvent {
  final int gid;
  final String token;
  final String comment;
  const PostComment(
      {required this.gid, required this.token, required this.comment});
  @override
  List<Object?> get props => [gid, token, comment];
}

class LoadComments extends GalleryDetailEvent {
  final int gid;
  final String token;
  const LoadComments({required this.gid, required this.token});
  @override
  List<Object?> get props => [gid, token];
}

class VoteComment extends GalleryDetailEvent {
  final int gid;
  final String token;
  final int commentId;
  final bool isUpvote;
  const VoteComment({
    required this.gid,
    required this.token,
    required this.commentId,
    required this.isUpvote,
  });
  @override
  List<Object?> get props => [gid, token, commentId, isUpvote];
}
