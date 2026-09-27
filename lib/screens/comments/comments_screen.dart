import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../blocs/auth/auth_bloc.dart';
import '../../blocs/gallery_detail/gallery_detail_bloc.dart';
import '../../blocs/gallery_detail/gallery_detail_event.dart';
import '../../blocs/gallery_detail/gallery_detail_state.dart';
import '../../core/l10n/s.dart';
import '../../widgets/comment_card.dart';

class CommentsScreen extends StatefulWidget {
  final int gid;
  final String token;
  const CommentsScreen({super.key, required this.gid, required this.token});
  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
  String _draft = '';
  bool _loadedDuringScroll = false;

  void _load() => context
      .read<GalleryDetailBloc>()
      .add(LoadComments(gid: widget.gid, token: widget.token));

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) _loadedDuringScroll = false;
    final movingDown = notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) > 0 ||
        notification is OverscrollNotification && notification.overscroll > 0;
    final state = context.read<GalleryDetailBloc>().state;
    if (movingDown &&
        notification.metrics.extentAfter <= 64 &&
        !_loadedDuringScroll &&
        !state.allCommentsLoaded &&
        !state.commentsLoading &&
        state.commentsError == null &&
        state.postStatus != CommentPostStatus.sending &&
        state.votingComments.isEmpty) {
      _loadedDuringScroll = true;
      _load();
    }
    return false;
  }

  Future<void> _compose() async {
    final s = S.of(context);
    if (!context.read<AuthBloc>().state.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.loginToComment)));
      return;
    }
    final bloc = context.read<GalleryDetailBloc>();
    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BlocProvider.value(
          value: bloc,
          child: _CommentDialog(
              gid: widget.gid,
              token: widget.token,
              draft: _draft,
              onChanged: (value) => _draft = value)),
    );
    if (sent == true) _draft = '';
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocConsumer<GalleryDetailBloc, GalleryDetailState>(
      listenWhen: (before, after) =>
          before.voteError != after.voteError && after.voteError != null,
      listener: (context, state) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(state.voteError!)));
        }
      },
      builder: (context, state) {
        final comments = state.detail?.comments ?? [];
        final remaining = (state.detail?.commentCount ?? 0) - comments.length;
        final busy = state.commentsLoading ||
            state.votingComments.isNotEmpty ||
            state.postStatus == CommentPostStatus.sending;
        return Scaffold(
          appBar:
              AppBar(title: Text(s.comments(state.detail?.commentCount ?? 0))),
          body: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: ListView.builder(
                key: const PageStorageKey('comments-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                itemCount: comments.length + 1,
                itemBuilder: (context, index) {
                  if (index < comments.length) {
                    return CommentCard(
                        key: ValueKey('comment-${comments[index].id}'),
                        comment: comments[index],
                        gid: widget.gid,
                        token: widget.token);
                  }
                  if (state.commentsLoading) {
                    return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()));
                  }
                  if (state.commentsError != null) {
                    return Column(children: [
                      Text(state.commentsError!),
                      TextButton(
                          onPressed: busy ? null : _load, child: Text(s.retry))
                    ]);
                  }
                  if (!state.allCommentsLoaded && remaining > 0) {
                    return TextButton(
                        key: const ValueKey('more-comments'),
                        onPressed: busy ? null : _load,
                        child: Text(s.moreComments(remaining),
                            textAlign: TextAlign.center));
                  }
                  return comments.isEmpty
                      ? Center(child: Text(s.noComments))
                      : const SizedBox.shrink();
                },
              )),
          floatingActionButton: FloatingActionButton(
              key: const ValueKey('write-comment'),
              tooltip: s.writeComment,
              onPressed: busy ? null : _compose,
              child: const Icon(Icons.edit)),
        );
      },
    );
  }
}

class _CommentDialog extends StatefulWidget {
  final int gid;
  final String token;
  final String draft;
  final ValueChanged<String> onChanged;
  const _CommentDialog(
      {required this.gid,
      required this.token,
      required this.draft,
      required this.onChanged});
  @override
  State<_CommentDialog> createState() => _CommentDialogState();
}

class _CommentDialogState extends State<_CommentDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.draft);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocConsumer<GalleryDetailBloc, GalleryDetailState>(
      listenWhen: (before, after) =>
          before.postStatus != after.postStatus &&
          after.postStatus == CommentPostStatus.success,
      listener: (context, state) => Navigator.pop(context, true),
      builder: (context, state) {
        final sending = state.postStatus == CommentPostStatus.sending;
        return WillPopScope(
            onWillPop: () async => !sending,
            child: AlertDialog(
              title: Text(s.writeComment),
              content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    key: const ValueKey('comment-input'),
                    controller: _controller,
                    autofocus: true,
                    enabled: !sending,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(hintText: s.commentHint),
                    onChanged: (value) {
                      widget.onChanged(value);
                      setState(() {});
                    }),
                if (state.postStatus == CommentPostStatus.failure)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(state.postError ?? s.failedToLoad)),
                if (sending) const LinearProgressIndicator(),
              ])),
              actions: [
                TextButton(
                    onPressed: sending ? null : () => Navigator.pop(context),
                    child: Text(s.cancel)),
                TextButton(
                    key: const ValueKey('send-comment'),
                    onPressed: sending || _controller.text.trim().isEmpty
                        ? null
                        : () {
                            context.read<GalleryDetailBloc>().add(PostComment(
                                gid: widget.gid,
                                token: widget.token,
                                comment: _controller.text.trim()));
                          },
                    child: Text(s.sendComment)),
              ],
            ));
      },
    );
  }
}
