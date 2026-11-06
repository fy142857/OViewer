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
import 'package:oviewer/blocs/reader/reader_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
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

import '../core/network/reader_image_session_test.dart' show makePng;
import 'reader_screen_test.dart'
    show MockGallery, MockHistory, MockSettings, MockSettingsBloc, MockCookies;

class _Client extends Mock implements HttpClient {}

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
  List<RedirectInfo> get redirects => const [];
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => 'OK';
  @override
  HttpHeaders get headers => _Headers();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(Uri.parse('https://example.test'));
    registerFallbackValue(<String, String>{});
    registerFallbackValue(const Stream<List<int>>.empty());
  });

  for (final mode in [0, 1, 2]) {
    for (final variant in [
      for (final layout in ReaderPageLayout.values)
        for (final transition in ReaderPageTransition.values)
          (layout, transition)
    ]) {
      final layout = variant.$1;
      final transition = variant.$2;
      for (final fail in mode < 2 && layout == ReaderPageLayout.single
          ? [false, true]
          : [false]) {
        testWidgets(
            'issue 73: controls work before first frame mode=$mode layout=$layout transition=$transition fail=$fail',
            (tester) async {
          await tester.binding.setSurfaceSize(const Size(400, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final gallery = MockGallery();
          final history = MockHistory();
          final settings = MockSettings();
          final settingsBloc = MockSettingsBloc();
          final cookies = MockCookies();
          when(() => settings.getReadingMode()).thenReturn(mode);
          when(() => settings.getReaderPageLayout()).thenReturn(layout);
          when(() => settings.getReaderPreloadCount()).thenReturn(1);
          when(() => settings.getReaderSpreadAlignment())
              .thenReturn(ReaderSpreadAlignment.width);
          when(() => settingsBloc.state).thenReturn(SettingsState(
              locale: 'en',
              readingMode: mode,
              pageLayout: layout,
              pageTransition: transition));
          when(() => settingsBloc.stream)
              .thenAnswer((_) => const Stream.empty());
          when(() => history.getProgress(any())).thenAnswer((_) async => null);
          when(() => history.updateProgress(any(), any(), any()))
              .thenAnswer((_) async {});
          when(() => cookies.applyRequestHeaders(any(), any()))
              .thenAnswer((_) async {});
          when(() => gallery.readerIndexCache).thenReturn(ReaderIndexCache());
          when(() => gallery.fetchReaderIndexPage(42, 'token',
                  cancelToken: any(named: 'cancelToken')))
              .thenAnswer((_) async => ReaderIndexPage(
                      totalPages: 3,
                      indexPage: 0,
                      indexPageCount: 1,
                      pageSize: 3,
                      thumbnails: {
                        for (var i = 0; i < 3; i++)
                          i: ThumbnailInfo(
                              pageToken: 'page', pageIndex: i, thumbUrl: '')
                      }));
          for (var page = 0; page < 3; page++) {
            when(() => gallery.fetchImage('page', 42, page,
                    cancelToken: any(named: 'cancelToken')))
                .thenAnswer((_) async => GalleryImage(
                    index: page,
                    pageUrl: 'page',
                    imageUrl: 'https://example.test/$page.png'));
          }
          ReaderReentryCache.shared.clear();
          GetIt.I.registerSingleton<GalleryRepository>(gallery);
          GetIt.I.registerSingleton<HistoryRepository>(history);
          GetIt.I.registerSingleton<SettingsRepository>(settings);
          GetIt.I.registerSingleton<CookieManager>(cookies);
          final directory = (await tester
              .runAsync(() => Directory.systemTemp.createTemp('issue73-')))!;
          final messenger = tester.binding.defaultBinaryMessenger;
          final modes = <String>[];
          messenger.setMockMethodCallHandler(SystemChannels.platform,
              (call) async {
            if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
              modes.add(call.arguments as String);
            }
            return null;
          });
          messenger.setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => directory.path);
          await tester.runAsync(() async {
            EhImageCacheManager.initForTesting(Config('issue73',
                repo: JsonCacheInfoRepository.withFile(
                    File('${directory.path}/cache.json'))));
            await EhImageCacheManager.instance.getFileFromCache('initialize');
          });
          final client = _Client();
          final pending = <Completer<HttpClientRequest>>[];
          when(() => client.openUrl(any(), any())).thenAnswer((_) {
            final request = Completer<HttpClientRequest>();
            pending.add(request);
            return request.future;
          });
          Future<void> advance() async {
            for (var i = 0; i < 8; i++) {
              await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)));
              await tester.pump(const Duration(milliseconds: 40));
            }
          }

          void completeDownloads(Uint8List bytes) {
            for (final held in pending.where((p) => !p.isCompleted).toList()) {
              final request = _Request();
              when(() => request.headers).thenReturn(_Headers());
              when(() => request.addStream(any())).thenAnswer((call) async =>
                  (call.positionalArguments.first as Stream<List<int>>)
                      .drain<void>());
              when(() => request.close())
                  .thenAnswer((_) async => _Response(bytes));
              held.complete(request);
            }
          }

          await HttpOverrides.runZoned(() async {
            try {
              await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
                  value: settingsBloc,
                  child: const MaterialApp(
                      home: ReaderScreen(gid: 42, token: 'token'))));
              await advance();
              final bloc = tester
                  .element(find.byType(BlocConsumer<ReaderBloc, ReaderState>))
                  .read<ReaderBloc>();
              expect(bloc.state.status, ReaderStatus.ready,
                  reason: bloc.state.errorMessage);
              expect(pending, isNotEmpty,
                  reason:
                      'state=${bloc.state}; text=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList()}');
              expect(bloc.state.loadedImages, isNotEmpty,
                  reason:
                      'Links are resolved; the image itself is still loading.');
              expect(bloc.state.readyResources, isEmpty);
              expect(find.byIcon(Icons.arrow_back), findsNothing);
              for (final point in [
                const Offset(200, 400),
                const Offset(120, 200)
              ]) {
                await tester.tapAt(point);
                await tester.pump(const Duration(milliseconds: 350));
                expect(bloc.state.showUI, isTrue);
                expect(find.byIcon(Icons.arrow_back), findsOneWidget);
                expect(find.byType(Slider), findsOneWidget);
                expect(modes.last, 'SystemUiMode.edgeToEdge');
                await tester.tapAt(point);
                await tester.pump(const Duration(milliseconds: 350));
                expect(bloc.state.showUI, isFalse);
                expect(modes.last, 'SystemUiMode.immersiveSticky');
              }
              // Edge navigation keeps controls independently visible/hidden.
              final nextPoint = mode == 2
                  ? const Offset(380, 600)
                  : Offset(mode == 0 ? 380 : 20, 400);
              final prevPoint = mode == 2
                  ? const Offset(20, 200)
                  : Offset(mode == 0 ? 20 : 380, 400);
              await tester.tapAt(const Offset(200, 400));
              await tester.pump(const Duration(milliseconds: 350));
              expect(bloc.state.showUI, isTrue);
              await tester.tapAt(nextPoint);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 16));
              for (var frame = 0; frame < 12; frame++) {
                await tester.pump(const Duration(milliseconds: 50));
              }
              expect(bloc.state.currentPage,
                  layout == ReaderPageLayout.single ? 1 : 2);
              expect(bloc.state.showUI, isTrue);
              await tester.tapAt(prevPoint);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 16));
              for (var frame = 0; frame < 12; frame++) {
                await tester.pump(const Duration(milliseconds: 50));
              }
              expect(bloc.state.currentPage, 0);
              await tester.tapAt(const Offset(200, 400));
              await tester.pump(const Duration(milliseconds: 350));
              expect(bloc.state.showUI, isFalse);
              if (mode < 2 && transition == ReaderPageTransition.none) {
                await tester.timedDragFrom(const Offset(200, 400),
                    const Offset(25, 0), const Duration(milliseconds: 300));
                await tester.pump(const Duration(milliseconds: 100));
                expect(bloc.state.currentPage, 0,
                    reason: 'Short slow drags do not turn pages');
                final gesture =
                    await tester.startGesture(const Offset(200, 400));
                await gesture.moveBy(Offset(mode == 0 ? -100 : 100, 0));
                await tester.pump(const Duration(milliseconds: 100));
                final pageView = tester.widget<PageView>(find.byType(PageView));
                expect(pageView.controller.page, 0);
                await gesture.up();
                for (var frame = 0; frame < 12; frame++) {
                  await tester.pump(const Duration(milliseconds: 50));
                }
                expect(bloc.state.currentPage,
                    layout == ReaderPageLayout.single ? 1 : 2);
                await tester.tapAt(prevPoint);
                for (var frame = 0; frame < 12; frame++) {
                  await tester.pump(const Duration(milliseconds: 50));
                }
              }
              if (mode < 2) {
                final direction = mode == 0 ? -300.0 : 300.0;
                await tester.dragFrom(
                    const Offset(200, 400), Offset(direction, 0));
                await tester.pump(const Duration(milliseconds: 500));
                expect(bloc.state.currentPage,
                    layout == ReaderPageLayout.single ? 1 : 2);
                expect(bloc.state.showUI, isFalse);
                await tester.dragFrom(
                    const Offset(200, 400), Offset(-direction, 0));
                await tester.pump(const Duration(milliseconds: 500));
                expect(bloc.state.currentPage, 0);
              }
              if (fail) {
                completeDownloads(Uint8List.fromList([1, 2, 3]));
                await advance();
                expect(find.text('Retry').hitTestable(), findsOneWidget);
                await tester.tapAt(const Offset(120, 200));
                await tester.pump(const Duration(milliseconds: 350));
                expect(bloc.state.showUI, isTrue);
                await tester.tapAt(const Offset(120, 200));
                await tester.pump(const Duration(milliseconds: 350));
                expect(bloc.state.showUI, isFalse);
                await tester.tap(find.text('Retry').hitTestable().first);
                await advance();
                expect(bloc.state.imageAttempts[0], 1);
                expect(bloc.state.showUI, isFalse,
                    reason: 'Retry must not also toggle controls.');
              }
              // Completing the real image stream must retain normal single-tap behavior.
              final png = (await tester
                  .runAsync(() => makePng(width: 40, height: 60)))!;
              for (var round = 0;
                  round < 8 && bloc.state.readyResources.length < 3;
                  round++) {
                completeDownloads(png);
                await advance();
              }
              expect(bloc.state.readyResources.containsKey(0), isTrue);
              await tester.tapAt(const Offset(200, 400));
              await tester.pump(const Duration(milliseconds: 350));
              expect(bloc.state.showUI, isTrue);
              await tester.tapAt(const Offset(200, 400));
              await tester.pump(const Duration(milliseconds: 350));
              expect(bloc.state.showUI, isFalse);
              // Pinching blocks navigation in every reading direction.
              final firstFinger =
                  await tester.startGesture(const Offset(150, 380), pointer: 1);
              final secondFinger =
                  await tester.startGesture(const Offset(250, 420), pointer: 2);
              await firstFinger.moveTo(const Offset(130, 370));
              await secondFinger.moveTo(const Offset(270, 430));
              await tester.pump(const Duration(milliseconds: 50));
              await firstFinger.moveTo(const Offset(80, 340));
              await secondFinger.moveTo(const Offset(320, 460));
              await tester.pump(const Duration(milliseconds: 50));
              await firstFinger.up();
              await secondFinger.up();
              for (var frame = 0; frame < 12; frame++) {
                await tester.pump(const Duration(milliseconds: 50));
              }
              final zoomPage = bloc.state.currentPage;
              await tester.tapAt(nextPoint);
              for (var frame = 0; frame < 12; frame++) {
                await tester.pump(const Duration(milliseconds: 50));
              }
              expect(bloc.state.currentPage, zoomPage,
                  reason: 'A zoomed edge tap must not turn pages');
              expect(bloc.state.showUI, isTrue);
              await tester.tapAt(const Offset(200, 400));
              await tester.pump(const Duration(milliseconds: 40));
              await tester.tapAt(const Offset(200, 400));
              for (var frame = 0; frame < 12; frame++) {
                await tester.pump(const Duration(milliseconds: 50));
              }
              await tester.tapAt(nextPoint);
              for (var frame = 0; frame < 12; frame++) {
                await tester.pump(const Duration(milliseconds: 50));
              }
              expect(bloc.state.currentPage,
                  layout == ReaderPageLayout.single ? 1 : 2,
                  reason: 'Restoring zoom restores navigation');
              expect(tester.takeException(), isNull);
            } finally {
              final previousErrorHandler = FlutterError.onError;
              FlutterError.onError = (details) {
                final error = details.exception;
                if (error is StateError &&
                    error.message.contains('cancelled')) {
                  return;
                }
                previousErrorHandler?.call(details);
              };
              addTearDown(() => FlutterError.onError = previousErrorHandler);
              await tester.pumpWidget(const SizedBox.shrink());
              for (final request in pending.where((p) => !p.isCompleted)) {
                request.completeError(StateError('cancelled'));
              }
              await advance();
              PaintingBinding.instance.imageCache
                ..clear()
                ..clearLiveImages();
              ReaderReentryCache.shared.clear();
              await GetIt.I.reset();
              await tester.pump(const Duration(seconds: 11));
              final disposal = EhImageCacheManager.instance.dispose();
              var disposed = false;
              disposal.whenComplete(() => disposed = true);
              for (var i = 0; i < 50 && !disposed; i++) {
                await advance();
              }
              expect(disposed, isTrue, reason: 'Cache disposal must finish');
              await disposal;
              await tester.runAsync(() async {
                expect(directory.parent.absolute.path,
                    Directory.systemTemp.absolute.path);
                await directory.delete(recursive: true);
              });
              messenger.setMockMethodCallHandler(SystemChannels.platform, null);
              messenger.setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/path_provider'),
                  null);
            }
          }, createHttpClient: (_) => client);
        });
      }
    }
  }
}
