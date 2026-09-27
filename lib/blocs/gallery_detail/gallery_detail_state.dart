import 'package:equatable/equatable.dart';
import '../../models/gallery_detail.dart';

enum GalleryDetailStatus { initial, loading, loaded, contentWarning, error }

enum CommentPostStatus { idle, sending, success, failure }

class GalleryDetailState extends Equatable {
  final GalleryDetailStatus status;
  final GalleryDetail? detail;
  final String? errorMessage;
  final bool commentsLoading;
  final bool allCommentsLoaded;
  final String? commentsError;
  final Set<int> votingComments;
  final String? voteError;
  final CommentPostStatus postStatus;
  final String? postError;

  const GalleryDetailState({
    this.status = GalleryDetailStatus.initial,
    this.detail,
    this.errorMessage,
    this.commentsLoading = false,
    this.allCommentsLoaded = false,
    this.commentsError,
    this.votingComments = const {},
    this.voteError,
    this.postStatus = CommentPostStatus.idle,
    this.postError,
  });

  GalleryDetailState copyWith({
    GalleryDetailStatus? status,
    GalleryDetail? detail,
    String? errorMessage,
    bool? commentsLoading,
    bool? allCommentsLoaded,
    String? commentsError,
    Set<int>? votingComments,
    String? voteError,
    CommentPostStatus? postStatus,
    String? postError,
    bool clearCommentsError = false,
    bool clearVoteError = false,
    bool clearPostError = false,
  }) {
    return GalleryDetailState(
      status: status ?? this.status,
      detail: detail ?? this.detail,
      errorMessage: errorMessage ?? this.errorMessage,
      commentsLoading: commentsLoading ?? this.commentsLoading,
      allCommentsLoaded: allCommentsLoaded ?? this.allCommentsLoaded,
      commentsError:
          clearCommentsError ? null : commentsError ?? this.commentsError,
      votingComments: votingComments ?? this.votingComments,
      voteError: clearVoteError ? null : voteError ?? this.voteError,
      postStatus: postStatus ?? this.postStatus,
      postError: clearPostError ? null : postError ?? this.postError,
    );
  }

  @override
  List<Object?> get props => [
        status,
        detail,
        errorMessage,
        commentsLoading,
        allCommentsLoaded,
        commentsError,
        votingComments,
        voteError,
        postStatus,
        postError
      ];
}
