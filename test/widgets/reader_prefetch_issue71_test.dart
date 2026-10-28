import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/reader_image_provider.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/core/storage/reader_reentry_cache.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/reader/reader_screen.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'reader_screen_test.dart'
    show MockGallery, MockHistory, MockSettings, MockSettingsBloc, MockCookies;
import '../core/network/reader_image_session_test.dart' show makePng;

class _HttpClient extends Mock implements HttpClient {}

// Hold image GETs open to measure downloads while the current image is slow.
// Gallery HTML is mocked independently; no external requests are made.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(Uri.parse('https://example.test'));
    registerFallbackValue(<String, String>{});
  });

  final scenarios = [
    for (final mode in [0, 1])
      for (final layout in ReaderPageLayout.values)
        for (final start in [0, 10, 18])
          (mode: mode, layout: layout, start: start, cache: false, fail: false),
    (
      mode: 2,
      layout: ReaderPageLayout.single,
      start: 10,
      cache: false,
      fail: false
    ),
    for (final mode in [0, 1])
      for (final fail in [false, true])
        (
          mode: mode,
          layout: ReaderPageLayout.single,
          start: 10,
          cache: true,
          fail: fail
        ),
  ];
  for (final scenario in scenarios) {
    final (:mode, :layout, :start, :cache, :fail) = scenario;
    const total = 19; // The final double-page spread has only one page.
    final spreads = ReaderSpreads(total, layout);
    Set<int> window(int page) => {
          for (var spread = spreads.spreadOf(page) - 1;
              spread <= spreads.spreadOf(page) + 1;
              spread++)
            if (spread >= 0 && spread < spreads.count) ...spreads.pages(spread),
        };
    final cachedPages = cache ? (fail ? <int>{start} : window(start)) : <int>{};
    testWidgets('issue 71: $scenario preloads adjacent image screens',
        (tester) async {
      final gallery = MockGallery();
      final history = MockHistory();
      final settings = MockSettings();
      final settingsBloc = MockSettingsBloc();
      final cookies = MockCookies();
      final htmlPages = <int>[];
      final imagePages = <int>[];
      final pending = <Completer<HttpClientRequest>>[];
      final client = _HttpClient();
      when(() => client.openUrl(any(), any())).thenAnswer((call) {
        expect(call.positionalArguments.first, 'GET');
        final uri = call.positionalArguments[1] as Uri;
        final page = int.parse(uri.pathSegments.last.split('.').first);
        imagePages.add(page);
        if (fail && page == start - 1) {
          return Future.error(const HttpException('test neighbour failure'));
        }
        final request = Completer<HttpClientRequest>();
        pending.add(request);
        return request.future;
      });
      when(() => cookies.applyRequestHeaders(any(), any()))
          .thenAnswer((_) async {});
      when(() => settingsBloc.state)
          .thenReturn(const SettingsState(locale: 'en'));
      when(() => settingsBloc.stream).thenAnswer((_) => const Stream.empty());
      when(() => settings.getReadingMode()).thenReturn(mode);
      when(() => settings.getReaderPageLayout()).thenReturn(layout);
      when(() => settings.getReaderSpreadAlignment())
          .thenReturn(ReaderSpreadAlignment.width);
      when(() => history.updateProgress(any(), any(), any()))
          .thenAnswer((_) async {});
      when(() => gallery.readerIndexCache).thenReturn(ReaderIndexCache());
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => ReaderIndexPage(
                  totalPages: total,
                  indexPage: 0,
                  indexPageCount: 1,
                  pageSize: total,
                  thumbnails: {
                    for (var i = 0; i < total; i++)
                      i: ThumbnailInfo(
                          pageToken: 'page', pageIndex: i, thumbUrl: '')
                  }));
      for (var page = 0; page < total; page++) {
        when(() => gallery.fetchImage('page', 42, page,
            cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async {
          htmlPages.add(page);
          return GalleryImage(
              index: page,
              pageUrl: 'page',
              imageUrl: 'https://example.test/$page.png',
              width: 600,
              height: 900);
        });
      }
      ReaderReentryCache.shared.clear();
      GetIt.I.registerSingleton<GalleryRepository>(gallery);
      GetIt.I.registerSingleton<HistoryRepository>(history);
      GetIt.I.registerSingleton<SettingsRepository>(settings);
      GetIt.I.registerSingleton<SettingsBloc>(settingsBloc);
      GetIt.I.registerSingleton<CookieManager>(cookies);
      final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('oviewer-issue71-')))!;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          SystemChannels.platform, (_) async => null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path);
      await tester.runAsync(() async {
        EhImageCacheManager.initForTesting(Config('issue71-$mode',
            repo: JsonCacheInfoRepository.withFile(
                File('${directory.path}/cache.json'))));
        await EhImageCacheManager.instance.getFileFromCache('initialize');
        if (cachedPages.isNotEmpty) {
          final png = await makePng();
          for (final page in cachedPages) {
            await ReaderImageCache(EhImageCacheManager.instance)
                .write('https://example.test/$page.png', png);
          }
        }
      });
      Future<void> advance() async {
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      await HttpOverrides.runZoned(() async {
        try {
          await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
              value: settingsBloc,
              child: MaterialApp(
                  home: ReaderScreen(
                      gid: 42, token: 'token', initialPage: start))));
          await advance();
          final content = find
              .byType(mode == 2 ? ScrollablePositionedList : PhotoViewGallery);
          final bloc = tester.element(content).read<ReaderBloc>();
          expect(bloc.state.currentPage, start);
          expect(
              htmlPages.toSet(),
              containsAll([
                for (var page = start - 3; page <= start + 3; page++)
                  if (page >= 0 && page < total) page,
              ]));
          expect(htmlPages.length, htmlPages.toSet().length);
          debugPrint('issue71 $scenario HTML=$htmlPages imageGET=$imagePages');
          if (mode == 2) {
            expect(imagePages.any((page) => page != start), isTrue,
                reason: 'The vertical list builds nearby images eagerly.');
          } else {
            final expected = window(start).difference(cachedPages);
            expect(imagePages.toSet(), expected);
            if (cache) {
              expect(
                  tester
                      .widgetList<RawImage>(find.byType(RawImage))
                      .any((image) => image.image != null),
                  isTrue);
            }
            if (fail) {
              // Exhaust the neighbour's bounded transport retries while the
              // cached current image stays visible and another GET is pending.
              await tester.pump(const Duration(seconds: 2));
              await advance();
              expect(bloc.state.currentPage, start);
              expect(
                  tester
                      .widgetList<RawImage>(find.byType(RawImage))
                      .any((image) => image.image != null),
                  isTrue);
            } else {
              expect(imagePages.length, expected.length);
            }
            final forward = start < total - 1;
            final target = forward
                ? start + spreads.pagesPerSpread
                : spreads.pages(spreads.spreadOf(start) - 1).first;
            final dx = (mode == 0 ? -700.0 : 700.0) * (forward ? 1 : -1);
            await tester.drag(content, Offset(dx, 0));
            await advance();
            expect(bloc.state.currentPage, target);
            final visited =
                {...window(start), ...window(target)}.difference(cachedPages);
            expect(imagePages.toSet(), visited);
            if (!fail) expect(imagePages.length, visited.length);
            // Rebuilds and switching direction reuse in-flight/cached images.
            if (start == 10 && !cache && layout == ReaderPageLayout.single) {
              bloc.add(const ChangeReadingMode(2));
              await advance();
              expect(find.byType(ScrollablePositionedList), findsOneWidget);
              bloc.add(ChangeReadingMode(mode));
              await advance();
              expect(bloc.state.currentPage, target);
              expect(imagePages.length, imagePages.toSet().length);
            }
          }
          expect(tester.takeException(), isNull);
        } finally {
          final previousErrorHandler = FlutterError.onError;
          FlutterError.onError = (details) {
            if (details.exception is StateError &&
                details.exception.toString() ==
                    'Bad state: The reader image request has been cancelled.') {
              return;
            }
            previousErrorHandler?.call(details);
          };
          try {
            await tester.pumpWidget(const SizedBox.shrink());
            for (final request in pending) {
              request
                  .completeError(const SocketException('test reader closed'));
            }
            await advance();
            verify(() => client.close(force: true)).called(greaterThan(0));
          } finally {
            FlutterError.onError = previousErrorHandler;
            ReaderReentryCache.shared.clear();
            await GetIt.I.reset();
            final disposal = EhImageCacheManager.instance.dispose();
            await advance();
            await disposal;
            await tester.runAsync(() async {
              expect(directory.parent.absolute.path,
                  Directory.systemTemp.absolute.path);
              await directory.delete(recursive: true);
            });
            messenger.setMockMethodCallHandler(SystemChannels.platform, null);
            messenger.setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'), null);
          }
        }
      }, createHttpClient: (_) => client);
    });
  }
}
