import 'package:equatable/equatable.dart';
import 'gallery_tag.dart';
import 'gallery_comment.dart';
import 'gallery_source.dart';
import '../core/parser/gallery_detail_parser.dart';

class GalleryDetail extends Equatable {
  final GallerySource? source;
  final int gid;
  final String token;
  final String title;
  final String? titleJpn;
  final String thumbUrl;
  final String category;
  final String uploader;
  final DateTime postedAt;
  final String? parent;
  final bool visible;
  final String language;
  final int fileCount;
  final int fileSize;
  final double rating;
  final int ratingCount;
  final int favoriteCount;

  /// null: not favorited; -1: favorited but the server slot is unknown.
  final int? favoritedSlot;
  final List<GalleryTag> tags;
  final List<GalleryComment> comments;
  final int? totalCommentCount;
  int get commentCount => totalCommentCount ?? comments.length;
  final List<ThumbnailInfo> thumbnails;
  final String? archiveUrl;

  const GalleryDetail({
    this.source,
    required this.gid,
    required this.token,
    required this.title,
    this.titleJpn,
    required this.thumbUrl,
    required this.category,
    required this.uploader,
    required this.postedAt,
    this.parent,
    this.visible = true,
    this.language = 'Japanese',
    required this.fileCount,
    this.fileSize = 0,
    required this.rating,
    this.ratingCount = 0,
    this.favoriteCount = 0,
    this.favoritedSlot,
    this.tags = const [],
    this.comments = const [],
    this.totalCommentCount,
    this.thumbnails = const [],
    this.archiveUrl,
  });

  bool get isFavorited => favoritedSlot != null;

  GalleryDetail withFavoriteSlot(int? slot) => GalleryDetail(
        source: source,
        gid: gid,
        token: token,
        title: title,
        titleJpn: titleJpn,
        thumbUrl: thumbUrl,
        category: category,
        uploader: uploader,
        postedAt: postedAt,
        parent: parent,
        visible: visible,
        language: language,
        fileCount: fileCount,
        fileSize: fileSize,
        rating: rating,
        ratingCount: ratingCount,
        favoriteCount: favoriteCount,
        favoritedSlot: slot,
        tags: tags,
        comments: comments,
        totalCommentCount: totalCommentCount,
        thumbnails: thumbnails,
        archiveUrl: archiveUrl,
      );

  GalleryDetail withComments(List<GalleryComment> updated,
          {bool all = false, int? totalCount, GallerySource? source}) =>
      GalleryDetail(
        source: source ?? this.source,
        gid: gid,
        token: token,
        title: title,
        titleJpn: titleJpn,
        thumbUrl: thumbUrl,
        category: category,
        uploader: uploader,
        postedAt: postedAt,
        parent: parent,
        visible: visible,
        language: language,
        fileCount: fileCount,
        fileSize: fileSize,
        rating: rating,
        ratingCount: ratingCount,
        favoriteCount: favoriteCount,
        favoritedSlot: favoritedSlot,
        tags: tags,
        comments: updated,
        totalCommentCount:
            totalCount ?? (all ? updated.length : totalCommentCount),
        thumbnails: thumbnails,
        archiveUrl: archiveUrl,
      );

  @override
  List<Object?> get props => [
        source,
        gid,
        token,
        title,
        titleJpn,
        thumbUrl,
        category,
        rating,
        ratingCount,
        favoriteCount,
        favoritedSlot,
        tags,
        comments,
        totalCommentCount,
        thumbnails,
      ];
}
