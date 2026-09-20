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
import 'package:oviewer/models/gallery_detail.dart';
import 'package:oviewer/models/gallery_image.dart';
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
    final historyRepository = MockHistoryRepository();
    final settingsRepository = MockSettingsRepository();
    final requestController = ReaderRequestController();
    final detailCompleter = Completer<GalleryDetail>();
    final tokenCompleter = Completer<CancelToken>();

    when(() => settingsRepository.getReadingMode()).thenReturn(0);
    when(() => galleryRepository.fetchGalleryDetail(
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
      history = MockHistoryRepository();
      settings = MockSettingsRepository();
      when(() => settings.getReadingMode()).thenReturn(0);
      when(() => history.getProgress(any())).thenAnswer((_) async => null);
      when(() => history.updateProgress(any(), any(), any()))
          .thenAnswer((_) async {});
      when(() => gallery.fetchGalleryDetail(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => GalleryDetail(
              gid: 42,
              token: 'token',
              title: 'Test',
              thumbUrl: '',
              category: 'Manga',
              uploader: '',
              postedAt: DateTime(2026),
              fileCount: 1,
              rating: 0));
      when(() => gallery.fetchThumbnails(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => const ThumbnailResult(thumbnails: [
                ThumbnailInfo(pageToken: 'page', pageIndex: 0, thumbUrl: '')
              ], totalPages: 1));
      when(() => gallery.fetchImage('page', 42, 0,
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => first);
      bloc = ReaderBloc(gallery, history, settings);
    });

    tearDown(() => bloc.close());

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
      when(() => gallery.fetchThumbnails(42, 'token',
              cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => ThumbnailResult(
              thumbnails: List.generate(
                  20,
                  (i) => ThumbnailInfo(
                      pageToken: 'page', pageIndex: i, thumbUrl: '')),
              totalPages: 1));
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
