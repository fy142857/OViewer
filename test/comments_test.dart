import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_bloc.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_event.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/models/gallery_comment.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/screens/comments/comments_screen.dart';
import 'package:oviewer/widgets/comment_card.dart';

class MockDio extends Mock implements DioClient {}

class MockRepo extends Mock implements GalleryRepository {}

class MockFavorites extends Mock implements FavoritesRepository {}

class MockAuth extends Mock implements AuthBloc {}

class MockSettings extends Mock implements SettingsBloc {}

String commentHtml(int id,
        {String date = '27 September 2026, 08:31',
        int score = 2,
        String up = '',
        String down = ''}) =>
    '''
<div class="c1"><div class="c2">
<div class="c3">Posted on $date by: &nbsp; <a>Tester $id</a></div>
<div class="c4">${id == 0 ? 'Uploader Comment' : ''}</div>
<div class="c5"><span id="comment_score_$id">$score</span></div>
<a id="comment_vote_up_$id" style="$up">Vote Up</a>
<a id="comment_vote_down_$id" style="$down">Vote Down</a></div>
<div class="c6" id="comment_$id">Comment $id</div></div>
''';
String page(String comments) =>
    '<script>var apiuid = 12; var apikey = "test-key";</script>'
    '<h1 id="gn">Test gallery</h1><div id="cdiv">$comments</div><div id="chd"></div>';
final original = GalleryDetailParser.parse(page(commentHtml(1)), 10, 'abc');

Future<void> load(GalleryDetailBloc bloc) async {
  final ready =
      bloc.stream.firstWhere((s) => s.status == GalleryDetailStatus.loaded);
  bloc.add(const FetchGalleryDetail(gid: 10, token: 'abc'));
  await ready;
}

void main() {
  tearDown(() => AppConstants.useExHentai = false);
  test('real DOM IDs, English UTC dates, vote states and hidden count', () {
    final detail = GalleryDetailParser.parse(
        page('${commentHtml(0)}'
            '${commentHtml(321, score: -9, down: 'color:blue')}'
            '${commentHtml(322, up: 'color: rgb(0, 0, 255);')}'
            '<a href="?hc=1">There are 7 more comments below the viewing threshold - click to show all.</a>'),
        10,
        'abc');
    expect(detail.comments.map((c) => c.id), [0, 321, 322]);
    expect(detail.comments[0].isUploader, true);
    expect(detail.comments[1].postedAt, DateTime.utc(2026, 9, 27, 8, 31));
    expect(detail.comments[1].score, -9);
    expect(detail.comments[1].isVotedDown, true);
    expect(detail.comments[2].isVotedUp, true);
    expect(detail.commentCount, 10);
  });
  test('real threshold paragraph counts 54 visible plus 148 hidden', () {
    final html = '<div id="cdiv">'
        '${List.generate(54, (i) => commentHtml(i)).join()}'
        '<div id="chd"><p>There are 148 more comments below the viewing threshold - '
        '<a href="https://e-hentai.org/g/3225333/91a17c1dc5/?hc=1#comments" rel="nofollow">click to show all</a>.</p>'
        '<p id="postnewcomment">Post a comment</p></div></div>';
    final detail = GalleryDetailParser.parse(html, 3225333, '91a17c1dc5');
    expect(detail.comments, hasLength(54));
    expect(detail.commentCount, 202);
  });

  test(
      'threshold parsing handles singular, nested markup and ignores quoted notices',
      () {
    for (final pair in <String, int>{
      '<p>There is 1 more comment below the viewing threshold - <a href="?hc=1#comments">click to show all</a>.</p>':
          1,
      '<p>There are <strong>1,234</strong> more comments below the viewing threshold - <a href="?p=0&amp;hc=1#comments">click to show all</a>.</p>':
          1234,
      '<p>There are 148 more comments below the viewing threshold - <a href="?hc=10">other</a>.</p>':
          0,
    }.entries) {
      expect(
          GalleryDetailParser.hiddenCommentCount(
              '<div id="cdiv"><div id="chd">${pair.key}</div></div>'),
          pair.value);
    }
    const quote =
        '<p>There are 999 more comments below the viewing threshold - <a href="?hc=1">click to show all</a>.</p>';
    const html =
        '<div id="cdiv"><div class="c1"><div class="c6" id="comment_7">$quote</div></div>'
        '<div id="chd"><p>There are 148 more comments below the viewing threshold - <a href="?hc=1">click to show all</a>.</p></div></div>';
    expect(GalleryDetailParser.hiddenCommentCount(html), 148);
    expect(
        GalleryDetailParser.hiddenCommentCount(
            '<div id="cdiv"><div class="c1"><div class="c6" id="comment_7">$quote</div></div></div>'),
        0);
  });

  test('invalid timestamps stay unknown; UTC and ISO dates are supported', () {
    expect(
        GalleryDetailParser.parseComments(commentHtml(1, date: 'invalid'))
            .single
            .postedAt,
        isNull);
    expect(GalleryDetailParser.parseCommentDate('31 February 2026, 01:02'),
        isNull);
    expect(GalleryDetailParser.parseCommentDate('2026-09-27 08:31'),
        DateTime.utc(2026, 9, 27, 8, 31));
    expect(
        GalleryDetailParser.parseComments(
                commentHtml(1, date: '27 September 2026, 08:31 UTC'))
            .single
            .postedAt,
        DateTime.utc(2026, 9, 27, 8, 31));
  });
  test('parser retains native site order regardless of time or score', () {
    final comments = GalleryDetailParser.parseComments(
        commentHtml(3, score: -5) +
            commentHtml(1, date: 'invalid', score: 99) +
            commentHtml(2));
    expect(comments.map((c) => c.id), [3, 1, 2]);
    expect(comments.first.withVote(40, 1), isNot(comments.first));
  });

  for (final ex in [false, true]) {
    test('comment fetch/form post/vote protocol on ${ex ? "EX" : "EH"}',
        () async {
      AppConstants.useExHentai = ex;
      final dio = MockDio();
      final repo = GalleryRepository(dio);
      final root = AppConstants.baseUrl;
      when(() => dio.get(any())).thenAnswer((_) async => page(commentHtml(77)));
      expect((await repo.fetchComments(10, 'abc')).single.id, 77);
      verify(() => dio.get('$root/g/10/abc/?hc=1')).called(1);
      when(() => dio.post(any(),
              data: any(named: 'data'),
              contentType: any(named: 'contentType'),
              followPostRedirects: true,
              headers: any(named: 'headers')))
          .thenAnswer((_) async => page(commentHtml(78)));
      expect(
          (await repo.postComment(10, 'abc', ' hello & world ')).single.id, 78);
      verify(() => dio.post('$root/g/10/abc/?hc=1',
              data: {'commenttext_new': 'hello & world'},
              contentType: Headers.formUrlEncodedContentType,
              followPostRedirects: true,
              headers: {'Origin': root, 'Referer': '$root/g/10/abc/?hc=1'}))
          .called(1);
      when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
          (_) async => '{"comment_id":77,"comment_score":23,"comment_vote":1}');
      final voted = await repo.voteComment(10, 'abc', 77, true);
      expect(voted.score, 23);
      expect(voted.vote, 1);
      verify(() => dio.post('$root/api.php', data: {
            'method': 'votecomment',
            'apiuid': 12,
            'apikey': 'test-key',
            'gid': 10,
            'token': 'abc',
            'comment_id': 77,
            'comment_vote': 1
          })).called(1);
    });
  }
  test('vote errors and invalid results are rejected, ID zero never posts',
      () async {
    final dio = MockDio();
    final repo = GalleryRepository(dio);
    when(() => dio.get(any())).thenAnswer((_) async => page(commentHtml(77)));
    for (final response in [
      '{"error":"You have commented on this gallery"}',
      '{}',
      '{"comment_id":78,"comment_score":3,"comment_vote":1}'
    ]) {
      when(() => dio.post(any(), data: any(named: 'data')))
          .thenAnswer((_) async => response);
      await expectLater(repo.voteComment(10, 'abc', 77, true), throwsException);
    }
    await expectLater(
        repo.voteComment(10, 'abc', 0, true), throwsArgumentError);
  });
  test('form errors/login pages are not treated as successful comments',
      () async {
    final dio = MockDio();
    final repo = GalleryRepository(dio);
    for (final response in [
      '${page(commentHtml(77))}<p>Posting denied</p>',
      '<html>Login required</html>',
      '${page(commentHtml(77))}<textarea name="commenttext_new">draft</textarea>',
      '<div id="cdiv"></div><div id="chd">You have to register</div>'
    ]) {
      when(() => dio.post(any(),
          data: any(named: 'data'),
          contentType: any(named: 'contentType'),
          followPostRedirects: true,
          headers: any(named: 'headers'))).thenAnswer((_) async => response);
      await expectLater(repo.postComment(10, 'abc', 'draft'), throwsException);
    }
  });

  testWidgets(
      'native visible comments first; first bottom loads all hidden comments',
      (tester) async {
    final repo = MockRepo();
    final auth = MockAuth();
    final settings = MockSettings();
    final visible = GalleryDetailParser.parseComments(
        commentHtml(0) + commentHtml(99) + commentHtml(11));
    final hidden = List.generate(45,
        (i) => GalleryDetailParser.parseComments(commentHtml(1000 + i)).single);
    final response = Completer<List<GalleryComment>>();
    when(() => repo.fetchGalleryDetail(10, 'abc')).thenAnswer(
        (_) async => original.withComments(visible, totalCount: 48));
    when(() => repo.fetchComments(10, 'abc'))
        .thenAnswer((_) => response.future);
    when(() => auth.state)
        .thenReturn(const AuthState(status: AuthStatus.authenticated));
    when(() => auth.stream).thenAnswer((_) => const Stream.empty());
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    final bloc = GalleryDetailBloc(repo, MockFavorites());
    addTearDown(bloc.close);
    await load(bloc);
    await tester.pumpWidget(MultiBlocProvider(providers: [
      BlocProvider.value(value: bloc),
      BlocProvider<AuthBloc>.value(value: auth),
      BlocProvider<SettingsBloc>.value(value: settings),
    ], child: const MaterialApp(home: CommentsScreen(gid: 10, token: 'abc'))));
    await tester.pumpAndSettle();
    verifyNever(() => repo.fetchComments(10, 'abc'));
    expect(bloc.state.detail!.comments.map((c) => c.id), [0, 99, 11]);
    expect(find.byKey(const ValueKey('uploader-badge')), findsOneWidget);
    final uploader = tester.widget<Text>(find.text('Tester 0'));
    expect(uploader.style!.color,
        Theme.of(tester.element(find.text('Tester 0'))).colorScheme.primary);
    await tester.drag(find.byType(ListView), const Offset(0, -650));
    await tester.pump();
    expect(bloc.state.commentsLoading, true);
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pump();
    response.complete([hidden.first, ...visible, ...hidden, visible.first]);
    await tester.pumpAndSettle();
    expect(bloc.state.detail!.comments.map((c) => c.id),
        [0, 99, 11, ...hidden.map((c) => c.id)]);
    expect(bloc.state.detail!.commentCount, 48);
    expect(bloc.state.allCommentsLoaded, true);
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(bloc.state.detail!.comments.length, 48);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(bloc.state.detail!.comments.length, 48);
    expect(bloc.state.allCommentsLoaded, true);
    verify(() => repo.fetchComments(10, 'abc')).called(1);
    expect(bloc.state.detail!.comments.map((c) => c.id).toSet(), hasLength(48));
  });

  for (final ex in [false, true]) {
    testWidgets(
        '54 + 148 actual notice structure expands all after retry on ${ex ? "EX" : "EH"}',
        (tester) async {
      AppConstants.useExHentai = ex;
      final root = AppConstants.baseUrl;
      final dio = MockDio();
      final settings = MockSettings();
      final visible = List.generate(54, (i) => commentHtml(i)).join();
      final collapsed =
          '<div id="cdiv">$visible<div id="chd"><p>There are 148 more comments below the viewing threshold - '
          '<a href="$root/g/3225333/91a17c1dc5/?hc=1#comments" rel="nofollow">click to show all</a>.</p></div></div>';
      final expanded =
          '<div id="cdiv">${List.generate(202, (i) => commentHtml(i)).join()}<div id="chd"></div></div>';
      var requests = 0;
      when(() => dio.get(any())).thenAnswer((call) async {
        if ((call.positionalArguments.first as String).contains('hc=1')) {
          return ++requests == 1 ? collapsed : expanded;
        }
        return collapsed;
      });
      when(() => dio.post(any(), data: any(named: 'data')))
          .thenAnswer((_) async => '{"gmetadata":[{"title_jpn":"Test"}]}');
      when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      final bloc = GalleryDetailBloc(GalleryRepository(dio), MockFavorites());
      addTearDown(bloc.close);
      final ready =
          bloc.stream.firstWhere((s) => s.status == GalleryDetailStatus.loaded);
      bloc.add(const FetchGalleryDetail(gid: 3225333, token: '91a17c1dc5'));
      await ready;
      expect(bloc.state.detail!.comments.length, 54);
      expect(bloc.state.detail!.commentCount, 202);
      expect(bloc.state.allCommentsLoaded, false);
      await tester.pumpWidget(MultiBlocProvider(
          providers: [
            BlocProvider.value(value: bloc),
            BlocProvider<SettingsBloc>.value(value: settings),
          ],
          child: const MaterialApp(
              home: CommentsScreen(gid: 3225333, token: '91a17c1dc5'))));
      await tester.pumpAndSettle();
      expect(find.text('Comments (202)'), findsOneWidget);
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(bloc.state.commentsError, contains('not expanded'));
      expect(bloc.state.detail!.commentCount, 202);
      expect(bloc.state.allCommentsLoaded, false);
      await tester.scrollUntilVisible(find.text('Retry'), 500,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(bloc.state.detail!.comments.length, 202);
      expect(bloc.state.detail!.commentCount, 202);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(bloc.state.detail!.comments.length, 202);
      expect(bloc.state.allCommentsLoaded, true);
      expect(bloc.state.detail!.comments.map((c) => c.id),
          List.generate(202, (i) => i));
      verify(() => dio.get('$root/g/3225333/91a17c1dc5/?hc=1')).called(2);
    });
  }

  testWidgets('full comments failure can retry; guests cannot submit or vote',
      (tester) async {
    final repo = MockRepo();
    final auth = MockAuth();
    final settings = MockSettings();
    when(() => repo.fetchGalleryDetail(10, 'abc')).thenAnswer(
        (_) async => original.withComments(original.comments, totalCount: 2));
    when(() => repo.fetchComments(10, 'abc'))
        .thenThrow(Exception('Load denied'));
    when(() => auth.state)
        .thenReturn(const AuthState(status: AuthStatus.unauthenticated));
    when(() => auth.stream).thenAnswer((_) => const Stream.empty());
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    final bloc = GalleryDetailBloc(repo, MockFavorites());
    addTearDown(bloc.close);
    await load(bloc);
    await tester.pumpWidget(MultiBlocProvider(providers: [
      BlocProvider.value(value: bloc),
      BlocProvider<AuthBloc>.value(value: auth),
      BlocProvider<SettingsBloc>.value(value: settings),
    ], child: const MaterialApp(home: CommentsScreen(gid: 10, token: 'abc'))));
    await tester.pumpAndSettle();
    verifyNever(() => repo.fetchComments(10, 'abc'));
    await tester.tap(find.byKey(const ValueKey('more-comments')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Load denied'), findsOneWidget);
    when(() => repo.fetchComments(10, 'abc'))
        .thenAnswer((_) async => original.comments);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Load denied'), findsNothing);
    expect(bloc.state.allCommentsLoaded, true);
    await tester.tap(find.byKey(const ValueKey('write-comment')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Log in to comment or vote'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('comment-up-1')));
    await tester.pump();
    verifyNever(() => repo.voteComment(any(), any(), any(), any()));
    verifyNever(() => repo.postComment(any(), any(), any()));
  });

  testWidgets(
      'native order, votes, failure/retry and posting update shared detail state',
      (tester) async {
    final repo = MockRepo();
    final auth = MockAuth();
    final settings = MockSettings();
    final all = GalleryDetailParser.parseComments(commentHtml(1, score: 30) +
        commentHtml(2, date: '28 September 2026, 08:31', score: 2));
    when(() => repo.fetchGalleryDetail(10, 'abc'))
        .thenAnswer((_) async => original.withComments(all, all: true));
    when(() => repo.fetchComments(10, 'abc')).thenAnswer((_) async => all);
    when(() => auth.state)
        .thenReturn(const AuthState(status: AuthStatus.authenticated));
    when(() => auth.stream).thenAnswer((_) => const Stream.empty());
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    final bloc = GalleryDetailBloc(repo, MockFavorites());
    addTearDown(bloc.close);
    await load(bloc);
    await tester.pumpWidget(MultiBlocProvider(providers: [
      BlocProvider.value(value: bloc),
      BlocProvider<AuthBloc>.value(value: auth),
      BlocProvider<SettingsBloc>.value(value: settings),
    ], child: const MaterialApp(home: CommentsScreen(gid: 10, token: 'abc'))));
    await tester.pumpAndSettle();
    expect(find.text('Comments (2)'), findsOneWidget);
    List<int> order() => tester
        .widgetList<CommentCard>(find.byType(CommentCard))
        .map((c) => c.comment.id)
        .toList();
    expect(order(), [1, 2]);
    expect(find.byKey(const ValueKey('comment-sort')), findsNothing);
    expect(find.byKey(const ValueKey('comment-order')), findsNothing);
    verifyNever(() => repo.fetchComments(10, 'abc'));

    final vote = Completer<CommentVoteResult>();
    when(() => repo.voteComment(10, 'abc', 1, true))
        .thenAnswer((_) => vote.future);
    await tester.tap(find.byKey(const ValueKey('comment-up-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('comment-up-1')));
    await tester.pump();
    verify(() => repo.voteComment(10, 'abc', 1, true)).called(1);
    vote.complete(const CommentVoteResult(42, 1));
    await tester.pumpAndSettle();
    expect(find.text('+42'), findsOneWidget);
    expect(bloc.state.detail!.comments.first.isVotedUp, true);
    when(() => repo.voteComment(10, 'abc', 1, true))
        .thenAnswer((_) async => const CommentVoteResult(30, 0));
    await tester.tap(find.byKey(const ValueKey('comment-up-1')));
    await tester.pumpAndSettle();
    expect(bloc.state.detail!.comments.first.isVotedUp, false);
    expect(find.text('+30'), findsOneWidget);
    when(() => repo.voteComment(10, 'abc', 1, false))
        .thenThrow(Exception('Vote denied'));
    await tester.tap(find.byKey(const ValueKey('comment-down-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Vote denied'), findsOneWidget);
    expect(bloc.state.detail!.comments.first.score, 30);

    await tester.tap(find.byKey(const ValueKey('write-comment')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('send-comment')))
            .onPressed,
        isNull);
    await tester.enterText(
        find.byKey(const ValueKey('comment-input')), 'Test draft');
    await tester.pump();
    when(() => repo.postComment(10, 'abc', 'Test draft'))
        .thenThrow(Exception('Posting denied'));
    await tester.tap(find.byKey(const ValueKey('send-comment')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Posting denied'), findsOneWidget);
    expect(find.text('Test draft'), findsOneWidget);
    final posted = Completer<List<GalleryComment>>();
    when(() => repo.postComment(10, 'abc', 'Test draft'))
        .thenAnswer((_) => posted.future);
    await tester.tap(find.byKey(const ValueKey('send-comment')));
    await tester.pump();
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('send-comment')))
            .onPressed,
        isNull);
    posted.complete(
        [...all, ...GalleryDetailParser.parseComments(commentHtml(3))]);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(bloc.state.detail!.commentCount, 3);
    expect(find.text('Comments (3)'), findsOneWidget);
  });
}
