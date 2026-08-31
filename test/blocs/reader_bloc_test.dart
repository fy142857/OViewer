import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/models/gallery_detail.dart';
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
    const imageUrl = 'https://example.org/page.jpg';

    requestController.registerImageUrl(imageUrl);
    expect(
      ReaderImageRequestRegistry.controllerFor(imageUrl),
      same(requestController),
    );
    expect(requestController.imageClient, same(imageClient));

    requestController.cancel();

    expect(requestController.isCancelled, isTrue);
    verify(() => imageClient.close()).called(1);
  });
}
