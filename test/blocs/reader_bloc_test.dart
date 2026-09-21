import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/blocs/reader/reader_state.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/reading_progress.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';

class MockGalleryRepository extends Mock implements GalleryRepository {}

class MockHistoryRepository extends Mock implements HistoryRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

class MockHttpClient extends Mock implements http.Client {}

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
  });

  test('closing the reader bloc cancels its active gallery request', () async {
    final galleryRepository = MockGalleryRepository();
    when(() => galleryRepository.readerIndexCache)
        .thenReturn(ReaderIndexCache());
    final historyRepository = MockHistoryRepository();
    final settingsRepository = MockSettingsRepository();
    final requestController = ReaderRequestController();
    final detailCompleter = Completer<ReaderIndexPage>();
    final tokenCompleter = Completer<CancelToken>();

    when(() => settingsRepository.getReadingMode()).thenReturn(0);
    when(() => galleryRepository.fetchReaderIndexPage(
          42,
          'token',
          cancelToken: any(named: 'cancelToken'),
        )).thenAnswer((invocation) {
      tokenCompleter.complete(
        invocation.namedArguments[#cancelToken] as CancelToken,
      );
      return detailCompleter.future;
    });

    final bloc = ReaderBloc(
      galleryRepository,
      historyRepository,
      settingsRepository,
      requestController: requestController,
    );
    bloc.add(const LoadReaderImages(gid: 42, token: 'token', initialPage: 1));

    expect(await tokenCompleter.future, same(requestController.cancelToken));

    final closeFuture = bloc.close();
    expect(requestController.cancelToken.isCancelled, isTrue);

    detailCompleter.completeError(StateError('cancelled'));
    await closeFuture;
  });

  test('cancelling a reader session closes its image HTTP client', () {
    final imageClient = MockHttpClient();
    final requestController = ReaderRequestController(
      imageClientFactory: () => imageClient,
    );
    expect(requestController.imageClient, same(imageClient));

    requestController.cancel();

    expect(requestController.isCancelled, isTrue);
    verify(() => imageClient.close()).called(1);
  });

  group('image loading and retry', () {
    late MockGalleryRepository gallery;
    late MockHistoryRepository history;
    late MockSettingsRepository settings;
    late ReaderBloc bloc;

    const first = GalleryImage(
        index: 0,
        pageUrl: 'page',
        imageUrl: 'https://example.org/first.png',
        nlKey: 'alternate');

    Future<void> waitFor(bool Function(ReaderState) predicate) async {
      if (predicate(bloc.state)) return;
      await bloc.stream.firstWhere(predicate).timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw StateError('Reader wait timed out: '
              'loaded=${bloc.state.loadedImages.keys} '
              'loading=${bloc.state.loadingIndices} failed=${bloc.state.failedIndices} '
              'status=${bloc.state.status}'));
    }

    setUp(() {
      gallery = MockGalleryRepository();
      when(() => gallery.readerIndexCache).thenReturn(ReaderIndexCache());
      history = MockHistoryRepository();
      settings = MockSettingsRepository();
      when(() => settings.getReadingMode()).thenReturn(0);
      when(() => history.getProgress(any())).thenAnswer((_) async => null);
      when(() => history.updateProgress(any(), any(), any()))
          .thenAnswer((_) async {});
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => ReaderIndexPage(
                  totalPages: 1,
                  indexPage: 0,
                  indexPageCount: 1,
                  pageSize: 1,
                  thumbnails: {
                    0: const ThumbnailInfo(
                        pageToken: 'page', pageIndex: 0, thumbUrl: '')
                  }));
      when(() => gallery.fetchImage('page', 42, 0,
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => first);
      bloc = ReaderBloc(gallery, history, settings);
    });

    tearDown(() => bloc.close());

    ReaderIndexPage part(int page) => ReaderIndexPage(
            totalPages: 105,
            indexPage: page,
            indexPageCount: 6,
            pageSize: 20,
            thumbnails: {
              for (var i = page * 20; i < ((page + 1) * 20).clamp(0, 105); i++)
                i: ThumbnailInfo(pageToken: 'page', pageIndex: i, thumbUrl: '')
            });

    test(
        'reader is ready with true page count before the target index finishes',
        () async {
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => part(0));
      final target = Completer<ReaderIndexPage>();
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              page: 5, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) => target.future);
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              page: 4, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => part(4));
      for (var i = 98; i < 105; i++) {
        when(() => gallery.fetchImage('page', 42, i,
                cancelToken: any(named: 'cancelToken')))
            .thenAnswer((_) async => GalleryImage(
                index: i,
                pageUrl: 'page',
                imageUrl: 'https://example.org/$i.png'));
      }
      bloc.add(
          const LoadReaderImages(gid: 42, token: 'token', initialPage: 101));
      await waitFor((s) => s.loadingIndices.contains(101));
      expect(bloc.state.status, ReaderStatus.ready);
      expect(bloc.state.totalPages, 105);
      expect(bloc.state.currentPage, 101);
      expect(bloc.state.thumbnails.length, 20);
      expect(bloc.state.loadedImages, isEmpty);
      verifyNever(() => history.getProgress(42));
      target.complete(part(5));
      await waitFor((s) => s.loadedImages.containsKey(101));
    });

    test(
        'explicit first page does not restore saved progress; null reads it once',
        () async {
      when(() => history.getProgress(42)).thenAnswer((_) async =>
          ReadingProgress(
              gid: 42,
              lastReadPage: 2,
              totalPages: 3,
              lastReadAt: DateTime(2026)));
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
      for (var i = 0; i < 3; i++) {
        when(() => gallery.fetchImage('page', 42, i,
                cancelToken: any(named: 'cancelToken')))
            .thenAnswer((_) async => GalleryImage(
                index: i,
                pageUrl: 'page',
                imageUrl: 'https://example.org/$i.png'));
      }
      bloc.add(const LoadReaderImages(gid: 42, token: 'token', initialPage: 0));
      await waitFor(
          (s) => s.loadedImages.length == 3 && s.loadingIndices.isEmpty);
      expect(bloc.state.currentPage, 0);
      verifyNever(() => history.getProgress(42));
      await bloc.close();
      bloc = ReaderBloc(gallery, history, settings);
      bloc.add(const LoadReaderImages(gid: 42, token: 'token'));
      await waitFor((s) => s.status == ReaderStatus.ready);
      expect(bloc.state.currentPage, 2);
      verify(() => history.getProgress(42)).called(1);
    });

    test(
        'a missing index page fails locally and can be retried without leaving reader',
        () async {
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => part(0));
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              page: 1, cancelToken: any(named: 'cancelToken')))
          .thenThrow(StateError('Offline'));
      bloc.add(
          const LoadReaderImages(gid: 42, token: 'token', initialPage: 21));
      await waitFor((s) => s.failedIndices.contains(21));
      expect(bloc.state.status, ReaderStatus.ready);
      expect(bloc.state.totalPages, 105);
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              page: 1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => part(1));
      for (var i = 18; i < 25; i++) {
        when(() => gallery.fetchImage('page', 42, i,
                cancelToken: any(named: 'cancelToken')))
            .thenAnswer((_) async => GalleryImage(
                index: i,
                pageUrl: 'page',
                imageUrl: 'https://example.org/$i.png'));
      }
      bloc.add(const RetryImageAtIndex(21));
      await waitFor((s) => s.loadedImages.containsKey(21));
      expect(bloc.state.status, ReaderStatus.ready);
      expect(bloc.state.failedIndices.contains(21), isFalse);
    });

    test('stale token refresh is bounded to one new index lookup', () async {
      var fetches = 0;
      when(() => gallery.fetchImage('page', 42, 0,
          cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async {
        fetches++;
        return const GalleryImage(index: 0, pageUrl: 'page', imageUrl: '');
      });
      bloc.add(const LoadReaderImages(gid: 42, token: 'token', initialPage: 0));
      await waitFor((s) => s.failedIndices.contains(0));
      expect(fetches, 2);
      verify(() => gallery.invalidateReaderIndex(42, 'token', 0)).called(1);
      expect(bloc.state.status, ReaderStatus.ready);
    });

    test('retry publishes a replacement URL even when page count is unchanged',
        () async {
      bloc.add(const LoadReaderImages(gid: 42, token: 'token'));
      await waitFor(
          (s) => s.loadedImages.length == 1 && s.loadingIndices.isEmpty);
      final request = Completer<GalleryImage>();
      when(() => gallery.fetchImageWithNl('page', 42, 0, 'alternate',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) => request.future);
      bloc.add(const RetryImageAtIndex(0));
      await waitFor((s) => s.loadingIndices.contains(0));
      expect(bloc.state.imageAttempts[0], 1);
      request.complete(const GalleryImage(
          index: 0,
          pageUrl: 'page',
          imageUrl: 'https://example.org/replacement.png'));
      await waitFor((s) => s.loadingIndices.isEmpty);
      expect(bloc.state.loadedImages[0]!.imageUrl,
          'https://example.org/replacement.png');
    });

    test('retry advances the load attempt even for an identical returned URL',
        () async {
      bloc.add(const LoadReaderImages(gid: 42, token: 'token'));
      await waitFor(
          (s) => s.loadedImages.isNotEmpty && s.loadingIndices.isEmpty);
      when(() => gallery.fetchImageWithNl('page', 42, 0, 'alternate',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => first);
      bloc.add(const RetryImageAtIndex(0));
      await waitFor((s) => s.imageAttempts[0] == 1 && s.loadingIndices.isEmpty);
      expect(bloc.state.loadedImages[0]!.imageUrl, first.imageUrl);
    });

    test(
        'failed page metadata can be explicitly retried without an automatic loop',
        () async {
      when(() => gallery.fetchImage('page', 42, 0,
              cancelToken: any(named: 'cancelToken')))
          .thenThrow(StateError('offline'));
      bloc.add(const LoadReaderImages(gid: 42, token: 'token'));
      await waitFor(
          (s) => s.failedIndices.contains(0) && s.loadingIndices.isEmpty);
      when(() => gallery.fetchImage('page', 42, 0,
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => first);
      bloc.add(const LoadImageAtIndex(0));
      bloc.add(const RetryImageAtIndex(0));
      await waitFor(
          (s) => s.loadedImages.isNotEmpty && s.loadingIndices.isEmpty);
      expect(bloc.state.failedIndices, isEmpty);
      verify(() => gallery.fetchImage('page', 42, 0,
          cancelToken: any(named: 'cancelToken'))).called(2);
    });

    test(
        'preloading stays around the reading position rather than walking the book',
        () async {
      when(() => gallery.fetchReaderIndexPage(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => ReaderIndexPage(
                  totalPages: 20,
                  indexPage: 0,
                  indexPageCount: 1,
                  pageSize: 20,
                  thumbnails: {
                    for (var i = 0; i < 20; i++)
                      i: ThumbnailInfo(
                          pageToken: 'page', pageIndex: i, thumbUrl: '')
                  }));
      for (var index = 0; index < 20; index++) {
        when(() => gallery.fetchImage('page', 42, index,
                cancelToken: any(named: 'cancelToken')))
            .thenAnswer((_) async => GalleryImage(
                index: index,
                pageUrl: 'page',
                imageUrl: 'https://example.org/image.png'));
      }
      bloc.add(const LoadReaderImages(gid: 42, token: 'token'));
      await waitFor(
          (s) => s.loadedImages.length == 4 && s.loadingIndices.isEmpty);
      // A subsequent event drains all earlier load completions/preload events.
      bloc.add(ToggleReaderUI());
      await waitFor((s) => s.showUI);
      expect(bloc.state.loadedImages.keys, unorderedEquals([0, 1, 2, 3]));
      bloc.add(const PageChanged(10));
      await waitFor(
          (s) => s.loadedImages.containsKey(13) && s.loadingIndices.isEmpty);
      expect(bloc.state.loadedImages.containsKey(14), isFalse);
    });
  });
}
