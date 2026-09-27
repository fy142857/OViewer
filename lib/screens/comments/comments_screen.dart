import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../blocs/auth/auth_bloc.dart';
import '../../blocs/gallery_detail/gallery_detail_bloc.dart';
import '../../blocs/gallery_detail/gallery_detail_event.dart';
import '../../blocs/gallery_detail/gallery_detail_state.dart';
import '../../core/l10n/s.dart';
import '../../models/gallery_comment.dart';
import '../../widgets/comment_card.dart';

enum CommentSort { time, score }

List<GalleryComment> sortComments(
    List<GalleryComment> comments, CommentSort sort, bool descending) {
  final sorted = List<GalleryComment>.of(comments);
  sorted.sort((a, b) {
    if (sort == CommentSort.time) {
      if (a.postedAt == null && b.postedAt != null) return 1;
      if (b.postedAt == null && a.postedAt != null) return -1;
    }
    var result = sort == CommentSort.score ? a.score.compareTo(b.score) : 0;
    if (result == 0 && a.postedAt != null && b.postedAt != null) {
      result = a.postedAt!.compareTo(b.postedAt!);
    }
    if (result == 0) result = a.id.compareTo(b.id);
    return descending ? -result : result;
  });
  return sorted;
}

class CommentsScreen extends StatefulWidget {
  final int gid;
  final String token;
  const CommentsScreen({super.key, required this.gid, required this.token});
  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
  CommentSort _sort = CommentSort.time;
  bool _descending = true;
  String _draft = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => context
      .read<GalleryDetailBloc>()
      .add(LoadComments(gid: widget.gid, token: widget.token));

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
        final comments =
            sortComments(state.detail?.comments ?? [], _sort, _descending);
        final busy = state.commentsLoading ||
            state.votingComments.isNotEmpty ||
            state.postStatus == CommentPostStatus.sending;
        return Scaffold(
          appBar: AppBar(
              title: Text(s.comments(state.detail?.commentCount ?? 0)),
              actions: [
                DropdownButtonHideUnderline(
                    child: DropdownButton<CommentSort>(
                  key: const ValueKey('comment-sort'),
                  value: _sort,
                  items: [
                    DropdownMenuItem(
                        value: CommentSort.time,
                        child: Text(s.commentSortTime)),
                    DropdownMenuItem(
                        value: CommentSort.score,
                        child: Text(s.commentSortScore)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _sort = value);
                  },
                )),
                IconButton(
                    key: const ValueKey('comment-order'),
                    tooltip: _descending ? s.descending : s.ascending,
                    icon: Icon(_descending
                        ? Icons.arrow_downward
                        : Icons.arrow_upward),
                    onPressed: () =>
                        setState(() => _descending = !_descending)),
              ]),
          body: Column(children: [
            if (state.commentsLoading) const LinearProgressIndicator(),
            if (state.commentsError != null)
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    Text(state.commentsError!),
                    TextButton(
                        onPressed: busy ? null : _load, child: Text(s.retry))
                  ])),
            Expanded(
                child: comments.isEmpty
                    ? Center(child: Text(s.noComments))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                        itemCount: comments.length,
                        itemBuilder: (context, index) => CommentCard(
                            key: ValueKey('comment-${comments[index].id}'),
                            comment: comments[index],
                            gid: widget.gid,
                            token: widget.token))),
          ]),
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
