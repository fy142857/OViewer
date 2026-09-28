import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/parser/gallery_content_warning.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_bloc.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_event.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/widgets/gallery_warning_view.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/blocs/reader/reader_state.dart';
import 'blocs/reader_bloc_test.dart'
    show MockHistoryRepository, MockSettingsRepository;
import 'core/network/comment_redirect_test.dart'
    show client, RedirectAdapter, FakeDio;

class MockFavorites extends Mock implements FavoritesRepository {}

class MockSettings extends Mock implements SettingsBloc {}

String warning(String root) =>
    '<div class="d"><h1>Content Warning</h1><p>Site warning reason.</p>'
    '<p><a href="$root/g/42/abc/?nw=session">View Gallery</a>'
    '<a href="$root/g/42/abc/?nw=always">Never Warn Me Again</a></p></div>';
const detail = '<h1 id="gn">Test</h1><h1 id="gj">Test</h1>'
    '<table id="gdd"><tr><td class="gdt1">Length:</td><td class="gdt2">2 pages</td></tr></table>'
    '<div id="gdt"><a href="/s/aaa/42-1"><img src="https://example.test/1.jpg" /></a>'
    '<a href="/s/bbb/42-2"><img src="https://example.test/2.jpg" /></a></div>';

void main() {
  setUpAll(() => registerFallbackValue(FakeDio()));
  tearDown(() {
    AppConstants.useExHentai = false;
    ReaderIndexCache.shared.clear();
  });
  test(
      'recognizes real warning but not quoted comments or foreign continue links',
      () {
    final url = Uri.parse('https://e-hentai.org/g/42/abc/');
    expect(GalleryContentWarning.parse(warning(url.origin), url)?.message,
        'Site warning reason.');
    expect(GalleryContentWarning.parse(warning('https://example.test'), url),
        isNull);
    expect(
        GalleryContentWarning.parse(detail + warning(url.origin), url), isNull);
    expect(
        GalleryContentWarning.parse(
            '<h1>Content Warning</h1><a href="javascript:void(0)">test</a>',
            url),
        isNull);
  });
  for (final ex in [false, true]) {
    test(
        'warning confirmation loads actual detail/index on ${ex ? "EX" : "EH"}',
        () async {
      AppConstants.useExHentai = ex;
      final root = AppConstants.baseUrl;
      final adapter = RedirectAdapter((request, _) => ResponseBody.fromString(
          '${request.headers['cookie'] ?? ''}'.contains('nw=1')
              ? detail
              : warning(root),
          200));
      final dio = client(adapter);
      final repo = GalleryRepository(dio, indexCache: ReaderIndexCache());
      final bloc = GalleryDetailBloc(repo, MockFavorites());
      final blocked = bloc.stream
          .firstWhere((s) => s.status == GalleryDetailStatus.contentWarning);
      bloc.add(const FetchGalleryDetail(gid: 42, token: 'abc'));
      await blocked;
      expect(bloc.state.detail, isNull);
      expect(repo.cachedReaderIndex(42, 'abc'), isNull);
      final loaded =
          bloc.stream.firstWhere((s) => s.status == GalleryDetailStatus.loaded);
      bloc.add(
          const FetchGalleryDetail(gid: 42, token: 'abc', acceptWarning: true));
      await loaded;
      expect(bloc.state.detail!.fileCount, 2);
      expect((await repo.fetchReaderIndexPage(42, 'abc')).totalPages, 2);
      await dio.get('$root/s/aaa/42-1');
      expect(adapter.requests.last.headers['cookie'], contains('nw=1'));
      expect(adapter.requests.last.headers['cookie'],
          contains('test-session=local-only'));
      await dio.get('$root/g/43/abc/');
      expect('${adapter.requests.last.headers['cookie']}',
          isNot(contains('nw=1')));
      await dio.get('$root/uconfig.php');
      expect('${adapter.requests.last.headers['cookie']}',
          isNot(contains('nw=1')));
      ReaderIndexCache.shared.clear();
      await dio.get('$root/g/42/abc/');
      expect('${adapter.requests.last.headers['cookie']}', contains('nw=1'));
      await bloc.close();
    });
  }
  test('reader index refuses warning instead of accepting a zero-page gallery',
      () async {
    final dio = client(RedirectAdapter((_, __) =>
        ResponseBody.fromString(warning(AppConstants.baseUrl), 200)));
    final repo = GalleryRepository(dio, indexCache: ReaderIndexCache());
    await expectLater(repo.fetchReaderIndexPage(42, 'abc'),
        throwsA(isA<GalleryContentWarning>()));
    expect(repo.cachedReaderIndex(42, 'abc'), isNull);
  });
  test('direct reader warning resumes the requested page after confirmation',
      () async {
    final dio = client(RedirectAdapter((request, _) => ResponseBody.fromString(
        '${request.headers['cookie'] ?? ''}'.contains('nw=1')
            ? detail
            : warning(AppConstants.baseUrl),
        200)));
    final repo = GalleryRepository(dio, indexCache: ReaderIndexCache());
    final history = MockHistoryRepository();
    final settings = MockSettingsRepository();
    when(() => settings.getReadingMode()).thenReturn(2);
    when(() => history.updateProgress(any(), any(), any()))
        .thenAnswer((_) async {});
    final bloc = ReaderBloc(repo, history, settings);
    final blocked =
        bloc.stream.firstWhere((s) => s.status == ReaderStatus.contentWarning);
    bloc.add(const LoadReaderImages(gid: 42, token: 'abc', initialPage: 1));
    await blocked;
    verifyNever(() => history.updateProgress(any(), any(), any()));
    final ready = bloc.stream.firstWhere((s) => s.status == ReaderStatus.ready);
    bloc.add(AcceptReaderContentWarning());
    await ready;
    expect(bloc.state.currentPage, 1);
    expect(bloc.state.totalPages, 2);
    await bloc.close();
  });

  testWidgets('warning requires an explicit continue action', (tester) async {
    final settings = MockSettings();
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    var continued = 0;
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings,
        child: MaterialApp(
            home: GalleryWarningView(
                message: 'Site warning reason.',
                onContinue: () => continued++))));
    expect(continued, 0);
    expect(find.text('Site warning reason.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('continue-gallery')));
    expect(continued, 1);
  });
}
