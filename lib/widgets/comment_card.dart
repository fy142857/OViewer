import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/gallery_detail/gallery_detail_bloc.dart';
import '../blocs/gallery_detail/gallery_detail_event.dart';
import '../blocs/gallery_detail/gallery_detail_state.dart';
import '../core/l10n/s.dart';
import '../core/utils/eh_url_parser.dart';
import '../models/gallery_comment.dart';

class CommentCard extends StatefulWidget {
  final GalleryComment comment;
  final int gid;
  final String token;
  const CommentCard(
      {super.key,
      required this.comment,
      required this.gid,
      required this.token});

  @override
  State<CommentCard> createState() => _CommentCardState();
}

class _CommentCardState extends State<CommentCard> {
  GalleryComment get comment => widget.comment;
  int get gid => widget.gid;
  String get token => widget.token;
  final _recognizers = <TapGestureRecognizer>[];

  void _clearRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _vote(BuildContext context, bool up) {
    if (!context.read<AuthBloc>().state.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.of(context).loginToComment)));
      return;
    }
    context.read<GalleryDetailBloc>().add(VoteComment(
        gid: gid, token: token, commentId: comment.id, isUpvote: up));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final state = context.watch<GalleryDetailBloc>().state;
    final busy = state.commentsLoading ||
        state.postStatus == CommentPostStatus.sending ||
        state.votingComments.contains(comment.id);
    final date = comment.postedAt?.toLocal();
    final dateText = date == null
        ? s.unknownCommentTime
        : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
            '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(comment.author,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: comment.isUploader
                                ? Theme.of(context).colorScheme.primary
                                : null))),
                if (comment.isUploader)
                  Container(
                      key: const ValueKey('uploader-badge'),
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(3)),
                      child: Text(s.uploaderBadge,
                          style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer))),
                const SizedBox(width: 8),
                Text(
                    comment.score > 0
                        ? '+${comment.score}'
                        : '${comment.score}',
                    style: TextStyle(
                        color: comment.score > 0
                            ? Colors.green
                            : comment.score < 0
                                ? Colors.red
                                : null),
                    key: ValueKey('comment-score-${comment.id}')),
              ]),
              const SizedBox(height: 6),
              _buildCommentContent(context, comment.content),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                    child: Text(dateText,
                        style: Theme.of(context).textTheme.labelSmall)),
                if (!comment.isUploader && comment.id > 0) ...[
                  IconButton(
                      key: ValueKey('comment-up-${comment.id}'),
                      tooltip: s.upvoteComment,
                      onPressed: busy ? null : () => _vote(context, true),
                      icon: Icon(
                          comment.isVotedUp
                              ? Icons.thumb_up
                              : Icons.thumb_up_outlined,
                          size: 18,
                          color: comment.isVotedUp
                              ? Theme.of(context).colorScheme.primary
                              : null)),
                  IconButton(
                      key: ValueKey('comment-down-${comment.id}'),
                      tooltip: s.downvoteComment,
                      onPressed: busy ? null : () => _vote(context, false),
                      icon: Icon(
                          comment.isVotedDown
                              ? Icons.thumb_down
                              : Icons.thumb_down_outlined,
                          size: 18,
                          color: comment.isVotedDown
                              ? Theme.of(context).colorScheme.primary
                              : null)),
                ],
              ]),
            ],
          )),
    );
  }

  Widget _buildCommentContent(BuildContext context, String html) {
    _clearRecognizers();
    final plainText = _stripHtml(html);
    final style = Theme.of(context).textTheme.bodyMedium!;
    final linkStyle = style.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );

    final urlRegex = RegExp(
      r'https?://(?:e-hentai|exhentai)\.org/g/\d+/[a-f0-9]+/?',
    );

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in urlRegex.allMatches(plainText)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: plainText.substring(lastEnd, match.start)));
      }
      final url = match.group(0)!;
      final parsed = EhUrlParser.parseGalleryUrl(url);
      final recognizer = parsed == null ? null : TapGestureRecognizer();
      if (recognizer != null) _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: url,
        style: linkStyle,
        recognizer: recognizer != null
            ? (recognizer
              ..onTap = () {
                Navigator.pushNamed(context, '/gallery', arguments: {
                  'gid': parsed!.$1,
                  'token': parsed.$2,
                });
              })
            : null,
      ));
      lastEnd = match.end;
    }

    if (lastEnd < plainText.length) {
      spans.add(TextSpan(text: plainText.substring(lastEnd)));
    }

    if (spans.isEmpty) {
      return Text(plainText, style: style);
    }

    return RichText(
      text: TextSpan(style: style, children: spans),
    );
  }

  String _stripHtml(String html) {
    final withLinks = html.replaceAllMapped(
      RegExp(
          r'<a\s[^>]*href="(https?://(?:e-hentai|exhentai)\.org/g/[^"]+)"[^>]*>(.*?)</a>',
          caseSensitive: false),
      (m) {
        final href = m.group(1)!;
        final text = m.group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        if (text.contains('e-hentai.org/g/') ||
            text.contains('exhentai.org/g/')) {
          return text;
        }
        return '$text $href';
      },
    );
    return withLinks
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
  }
}
