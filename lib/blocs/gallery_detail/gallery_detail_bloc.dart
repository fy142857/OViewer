import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/favorites_repository.dart';
import '../../models/gallery_detail.dart';
import '../../models/gallery_preview.dart';
import '../../models/gallery_comment.dart';
import 'gallery_detail_event.dart';
import 'gallery_detail_state.dart';

class GalleryDetailBloc extends Bloc<GalleryDetailEvent, GalleryDetailState> {
  final GalleryRepository _repository;
  final FavoritesRepository _favoritesRepo;
  List<GalleryComment>? _remainingComments;

  GalleryDetailBloc(this._repository, this._favoritesRepo)
      : super(const GalleryDetailState()) {
    on<FetchGalleryDetail>(_onFetch);
    on<ToggleFavorite>(_onToggleFavorite);
    on<RateGallery>(_onRate);
    on<PostComment>(_onPostComment);
    on<VoteComment>(_onVoteComment);
    on<LoadComments>(_onLoadComments);
  }

  Future<void> _onFetch(
    FetchGalleryDetail event,
    Emitter<GalleryDetailState> emit,
  ) async {
    emit(state.copyWith(status: GalleryDetailStatus.loading));
    try {
      final detail =
          await _repository.fetchGalleryDetail(event.gid, event.token);
      _remainingComments = null;
      emit(state.copyWith(
        status: GalleryDetailStatus.loaded,
        detail: detail,
        allCommentsLoaded: detail.commentCount <= detail.comments.length,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: GalleryDetailStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> _onToggleFavorite(
    ToggleFavorite event,
    Emitter<GalleryDetailState> emit,
  ) async {
    if (state.detail == null) return;
    final detail = state.detail!;
    final wasFavorited = detail.isFavorited;

    // Optimistic UI update
    final updatedDetail = GalleryDetail(
      gid: detail.gid,
      token: detail.token,
      title: detail.title,
      titleJpn: detail.titleJpn,
      thumbUrl: detail.thumbUrl,
      category: detail.category,
      uploader: detail.uploader,
      postedAt: detail.postedAt,
      parent: detail.parent,
      visible: detail.visible,
      language: detail.language,
      fileCount: detail.fileCount,
      fileSize: detail.fileSize,
      rating: detail.rating,
      ratingCount: detail.ratingCount,
      favoriteCount: detail.favoriteCount,
      favoritedSlot: wasFavorited ? null : (event.slot ?? 0),
      tags: detail.tags,
      comments: detail.comments,
      totalCommentCount: detail.totalCommentCount,
      thumbnails: detail.thumbnails,
      archiveUrl: detail.archiveUrl,
    );
    emit(state.copyWith(detail: updatedDetail));

    try {
      if (wasFavorited) {
        await _favoritesRepo.removeCloudFavorite(event.gid, event.token);
      } else {
        final slot = event.slot ?? 0;
        await _favoritesRepo.addCloudFavorite(
          event.gid,
          event.token,
          slot: slot,
          preview: GalleryPreview(
            gid: detail.gid,
            token: detail.token,
            title: detail.title,
            thumbUrl: detail.thumbUrl,
            category: detail.category,
            rating: detail.rating,
            uploader: detail.uploader,
            fileCount: detail.fileCount,
            postedAt: detail.postedAt,
          ),
        );
      }
    } catch (_) {
      // Revert on failure
      emit(state.copyWith(detail: detail));
    }
  }

  Future<void> _onRate(
    RateGallery event,
    Emitter<GalleryDetailState> emit,
  ) async {
    try {
      final result =
          await _repository.rateGallery(event.gid, event.token, event.rating);
      // Update the detail with new rating
      if (state.detail != null) {
        final updated = GalleryDetail(
          gid: state.detail!.gid,
          token: state.detail!.token,
          title: state.detail!.title,
          titleJpn: state.detail!.titleJpn,
          thumbUrl: state.detail!.thumbUrl,
          category: state.detail!.category,
          uploader: state.detail!.uploader,
          postedAt: state.detail!.postedAt,
          parent: state.detail!.parent,
          visible: state.detail!.visible,
          language: state.detail!.language,
          fileCount: state.detail!.fileCount,
          fileSize: state.detail!.fileSize,
          rating: result.averageRating,
          ratingCount: result.ratingCount,
          favoriteCount: state.detail!.favoriteCount,
          favoritedSlot: state.detail!.favoritedSlot,
          tags: state.detail!.tags,
          comments: state.detail!.comments,
          totalCommentCount: state.detail!.totalCommentCount,
          thumbnails: state.detail!.thumbnails,
          archiveUrl: state.detail!.archiveUrl,
        );
        emit(state.copyWith(detail: updated));
      }
    } catch (_) {
      // Rating failed silently
    }
  }

  Future<void> _onPostComment(
    PostComment event,
    Emitter<GalleryDetailState> emit,
  ) async {
    if (state.postStatus == CommentPostStatus.sending ||
        state.commentsLoading ||
        state.votingComments.isNotEmpty ||
        event.comment.trim().isEmpty) return;
    emit(state.copyWith(
        postStatus: CommentPostStatus.sending, clearPostError: true));
    try {
      final comments =
          await _repository.postComment(event.gid, event.token, event.comment);
      // Refresh in site order, retaining the visible quota instead of expanding
      // every hidden comment after posting.
      final visibleCount = state.detail!.comments.length < 20
          ? 20
          : state.detail!.comments.length;
      final visible = comments.take(visibleCount).toList();
      _remainingComments = comments.skip(visibleCount).toList();
      emit(state.copyWith(
        detail:
            state.detail?.withComments(visible, totalCount: comments.length),
        allCommentsLoaded: _remainingComments!.isEmpty,
        clearCommentsError: true,
        postStatus: CommentPostStatus.success,
      ));
    } catch (e) {
      emit(state.copyWith(
          postStatus: CommentPostStatus.failure, postError: e.toString()));
    }
  }

  Future<void> _onLoadComments(
      LoadComments event, Emitter<GalleryDetailState> emit) async {
    if (state.commentsLoading ||
        state.allCommentsLoaded ||
        state.detail == null ||
        state.postStatus == CommentPostStatus.sending ||
        state.votingComments.isNotEmpty) return;
    emit(state.copyWith(commentsLoading: true, clearCommentsError: true));
    try {
      if (_remainingComments == null) {
        final comments =
            await _repository.fetchComments(event.gid, event.token);
        final seen = state.detail!.comments.map((c) => c.id).toSet();
        _remainingComments = comments.where((c) => seen.add(c.id)).toList();
      }
      final comments = [...state.detail!.comments, ..._remainingComments!];
      _remainingComments = [];
      emit(state.copyWith(
          detail: state.detail?.withComments(comments, all: true),
          commentsLoading: false,
          allCommentsLoaded: true));
    } catch (e) {
      emit(state.copyWith(commentsLoading: false, commentsError: e.toString()));
    }
  }

  Future<void> _onVoteComment(
    VoteComment event,
    Emitter<GalleryDetailState> emit,
  ) async {
    if (event.commentId <= 0 ||
        state.votingComments.contains(event.commentId) ||
        state.commentsLoading ||
        state.postStatus == CommentPostStatus.sending) return;
    emit(state.copyWith(
        votingComments: {...state.votingComments, event.commentId},
        clearVoteError: true));
    try {
      final result = await _repository.voteComment(
          event.gid, event.token, event.commentId, event.isUpvote);
      final detail = state.detail;
      emit(state.copyWith(
        detail: detail?.withComments(detail.comments
            .map((c) => c.id == event.commentId
                ? c.withVote(result.score, result.vote)
                : c)
            .toList()),
        votingComments: {...state.votingComments}..remove(event.commentId),
      ));
    } catch (e) {
      emit(state.copyWith(
          votingComments: {...state.votingComments}..remove(event.commentId),
          voteError: e.toString()));
    }
  }
}
