import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

class _Request extends Mock implements HttpClientRequest {}

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String, List<String>) action) {}
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(Uint8List bytes)
      : contentLength = bytes.length,
        super(Stream.value(bytes));
  @override
  final int contentLength;
  @override
  int get statusCode => 200;
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => 'OK';
  @override
  HttpHeaders get headers => _Headers();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Hold image GETs open to measure downloads while the current image is slow.
// Gallery HTML is mocked independently; no external requests are made.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(Uri.parse('https://example.test'));
    registerFallbackValue(<String, String>{});
    registerFallbackValue(const Stream<List<int>>.empty());
  });

  final scenarios = [
    for (final mode in [0, 1, 2])
      for (final layout in ReaderPageLayout.values)
        for (final start in [0, 10, 18])
          for (final n in [1, 3, 5])
            (
              mode: mode,
              layout: layout,
              start: start,
              n: n,
              cache: false,
              fail: false
            ),
    for (final mode in [0, 1])
      for (final fail in [false, true])
        (
          mode: mode,
          layout: ReaderPageLayout.single,
          start: 10,
          n: 3,
          cache: true,
          fail: fail
        ),
  ];
  for (final scenario in scenarios) {
    final (:mode, :layout, :start, :n, :cache, :fail) = scenario;
    const total = 19; // The final double-page spread has only one page.
    final spreads = ReaderSpreads(total, layout);
    Set<int> window(int page) => {
          for (var spread = spreads.spreadOf(page) - n;
              spread <= spreads.spreadOf(page) + n;
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
      final pendingPages = <int>[];
      final foreground = {...spreads.containing(start)};
      ReaderBloc? liveBloc;
      final client = _HttpClient();
      var clientCreated = false;
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
        pendingPages.add(page);
        if (liveBloc != null) {
          final visible = liveBloc!.state.preloadWindow.visible;
          foreground.addAll(visible);
          final background = {
            for (var i = 0; i < pending.length; i++)
              if (!pending[i].isCompleted &&
                  !foreground.contains(pendingPages[i]))
                pendingPages[i]
          };
          expect(background.length, lessThanOrEqualTo(2));
        }
        return request.future;
      });
      when(() => cookies.applyRequestHeaders(any(), any()))
          .thenAnswer((_) async {});
      var savedSettings = SettingsState(
          locale: 'en', readingMode: mode, pageLayout: layout, preloadCount: n);
      final settingsChanges = StreamController<SettingsState>.broadcast();
      addTearDown(settingsChanges.close);
      when(() => settingsBloc.state).thenAnswer((_) => savedSettings);
      when(() => settingsBloc.stream).thenAnswer((_) => settingsChanges.stream);
      when(() => settings.getReadingMode()).thenReturn(mode);
      when(() => settings.getReaderPreloadCount()).thenReturn(n);
      when(() => settings.getReaderPageLayout()).thenReturn(layout);
      when(() => settings.getReaderSpreadAlignment())
          .thenReturn(ReaderSpreadAlignment.width);
      when(() => history.updateProgress(any(), any(), any()))
          .thenAnswer((_) async {});
      when(() => gallery.readerIndexCache).thenReturn(ReaderIndexCache());
      for (var part = 0; part < 5; part++) {
        when(() => gallery.fetchReaderIndexPage(42, 'token',
                page: part, cancelToken: any(named: 'cancelToken')))
            .thenAnswer((_) async => ReaderIndexPage(
                    totalPages: total,
                    indexPage: part,
                    indexPageCount: 5,
                    pageSize: 4,
                    thumbnails: {
                      for (var i = part * 4;
                          i < (part + 1) * 4 && i < total;
                          i++)
                        i: ThumbnailInfo(
                            pageToken: 'page', pageIndex: i, thumbUrl: '')
                    }));
      }
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

      Future<void> finishDownloads() async {
        final png = (await tester.runAsync(makePng))!;
        for (var round = 0; round < 100; round++) {
          final outstanding =
              pending.where((request) => !request.isCompleted).toList();
          if (outstanding.isEmpty) {
            await advance();
            final state = liveBloc!.state;
            if (pending.every((request) => request.isCompleted) &&
                state.preloadWindow.targets.every((page) =>
                    (fail && page == start - 1) ||
                    state.readyResources.containsKey(page))) return;
            continue;
          }
          for (final request in outstanding) {
            final response = _Request();
            when(() => response.headers).thenReturn(_Headers());
            when(() => response.addStream(any())).thenAnswer((call) async {
              await (call.positionalArguments.first as Stream<List<int>>)
                  .drain<void>();
            });
            when(() => response.close())
                .thenAnswer((_) async => _Response(png));
            request.complete(response);
          }
          await advance();
        }
        final state = liveBloc!.state;
        throw TestFailure('Preload queue did not drain: '
            'targets=${state.preloadWindow.targets} ready=${state.readyResources.keys} '
            'loading=${state.loadingIndices} failed=${state.failedIndices} GETs=$imagePages '
            'pending=${[
          for (var i = 0; i < pending.length; i++)
            if (!pending[i].isCompleted) pendingPages[i]
        ]}');
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
          liveBloc = bloc;
          final admitted = {...bloc.state.preloadWindow.targets};
          final subscription = bloc.stream.listen((state) {
            admitted.addAll(state.preloadWindow.targets);
            foreground.addAll(state.preloadWindow.visible);
          });
          addTearDown(subscription.cancel);
          expect(bloc.state.currentPage, start);
          expect(
              htmlPages.toSet(),
              containsAll([
                for (var page = start - 3; page <= start + 3; page++)
                  if (page >= 0 && page < total) page,
              ]));
          expect(htmlPages.length, htmlPages.toSet().length);
          debugPrint('issue71 $scenario HTML=$htmlPages imageGET=$imagePages');
          final initialWindow = bloc.state.preloadWindow;
          if (!cache && mode != 2) {
            expect(initialWindow.visible, contains(imagePages.first),
                reason: 'Visible image IO starts before background image IO');
          }
          expect(imagePages.toSet(), everyElement(isIn(initialWindow.targets)));
          expect(
              imagePages
                  .where((p) => !initialWindow.visible.contains(p))
                  .toSet()
                  .length,
              lessThanOrEqualTo(2));
          var focus = start;
          if (mode != 2 &&
              start == 10 &&
              n == 3 &&
              !cache &&
              layout == ReaderPageLayout.single) {
            // Both background slots and the current image are still stalled.
            // Turning to a prefetched page must reuse its existing GET.
            await tester.drag(content, Offset(mode == 0 ? -700 : 700, 0));
            await advance();
            focus = 11;
            expect(bloc.state.currentPage, focus);
            expect(imagePages.where((page) => page == 11), hasLength(1));
            expect(imagePages, contains(12));
          }
          {
            if (cache) {
              // Disk reads and image decoding run outside the fake test clock.
              // Wait for the frame instead of assuming one advance is enough.
              for (var attempt = 0;
                  attempt < 20 &&
                      !tester
                          .widgetList<RawImage>(find.byType(RawImage))
                          .any((image) => image.image != null);
                  attempt++) {
                await advance();
              }
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
              expect(imagePages.length, imagePages.toSet().length);
            }
            await finishDownloads();
            expect(
                imagePages.toSet(),
                containsAll(
                    bloc.state.preloadWindow.targets.difference(cachedPages)));
            expect(imagePages.toSet(), everyElement(isIn(admitted)));
            final cached = {
              for (final page in bloc.state.preloadWindow.targets)
                if (!(fail && page == start - 1))
                  page: ReaderImageCache(EhImageCacheManager.instance)
                      .read('https://example.test/$page.png'),
            };
            var cacheReadDone = false;
            final cacheReads = Future.wait(cached.values)
                .whenComplete(() => cacheReadDone = true);
            for (var i = 0; i < 60 && !cacheReadDone; i++) await advance();
            expect(cacheReadDone, true,
                reason: 'Cached byte reads must finish');
            expect(await cacheReads, everyElement(isNotNull));
            if (start == 10 && n == 1 && !cache) {
              final position = bloc.state.currentPage;
              savedSettings = savedSettings.copyWith(preloadCount: 5);
              settingsChanges.add(savedSettings);
              await advance();
              expect(bloc.state.preloadCount, 5);
              expect(bloc.state.currentPage, position);
              savedSettings = savedSettings.copyWith(preloadCount: 1);
              settingsChanges.add(savedSettings);
              await advance();
              final before = imagePages.length;
              await advance();
              expect(imagePages.length, before);
              await finishDownloads();
              savedSettings = savedSettings.copyWith(preloadCount: 5);
              settingsChanges.add(savedSettings);
              await advance();
              await finishDownloads();
              expect(bloc.state.preloadCount, 5);
              expect(bloc.state.currentPage, position);
              expect(imagePages.toSet(),
                  containsAll(bloc.state.preloadWindow.targets));
            }
            if (start == 18 && n == 5 && !cache) {
              // A far jump must bypass the queue; exit while the new visible
              // and background GETs are still stalled, with more work queued.
              bloc.add(ToggleReaderUI());
              await advance();
              tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(0);
              await advance();
              expect(bloc.state.currentPage, 0);
              expect(pending.any((request) => !request.isCompleted), true);
              return;
            }
            if (mode == 2) {
              expect(bloc.state.preloadWindow.visible, contains(start));
              expect(tester.takeException(), isNull);
              return;
            }
            final forward = focus < total - 1;
            final target = forward
                ? focus + spreads.pagesPerSpread
                : spreads.pages(spreads.spreadOf(focus) - 1).first;
            final dx = (mode == 0 ? -700.0 : 700.0) * (forward ? 1 : -1);
            await tester.drag(content, Offset(dx, 0));
            await advance();
            expect(bloc.state.currentPage, target);
            await finishDownloads();
            expect(imagePages.toSet(),
                containsAll(window(target).difference(cachedPages)));
            if (!fail) expect(imagePages.length, imagePages.toSet().length);
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
                const {
                  'Bad state: The reader image request has been cancelled.',
                  'Bad state: Reader image request cancelled',
                }.contains(details.exception.toString())) {
              return;
            }
            previousErrorHandler?.call(details);
          };
          try {
            final beforeExit = imagePages.length;
            await tester.pumpWidget(const SizedBox.shrink());
            for (final request in pending) {
              if (!request.isCompleted)
                request
                    .completeError(const SocketException('test reader closed'));
            }
            await advance();
            expect(imagePages.length, beforeExit,
                reason: 'Exiting must not start any more queued requests');
            // A cached-only run may never create a transport. Do not mask an
            // earlier visibility assertion with a missing close on that client.
            if (clientCreated) {
              verify(() => client.close(force: true)).called(greaterThan(0));
            }
          } finally {
            FlutterError.onError = previousErrorHandler;
            ReaderReentryCache.shared.clear();
            await GetIt.I.reset();
            final disposal = EhImageCacheManager.instance.dispose();
            var disposed = false;
            disposal.whenComplete(() => disposed = true);
            for (var i = 0; i < 60 && !disposed; i++) await advance();
            expect(disposed, true, reason: 'Cache disposal must finish');
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
      }, createHttpClient: (_) {
        clientCreated = true;
        return client;
      });
    });
  }
}
