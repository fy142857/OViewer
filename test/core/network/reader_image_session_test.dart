import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/reader_image_provider.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';

class MockCookies extends Mock implements CookieManager {}

class MockFiles extends Mock implements FileService {}

class BrokenFrameCodec extends Mock implements ui.Codec {}

class MemoryImageCache extends Fake implements ReaderImageCache {
  final entries = <String, Uint8List>{};
  var writes = 0;

  @override
  Future<Uint8List?> read(String url) async => entries[url];

  @override
  Future<void> write(String url, Uint8List bytes) async {
    entries[url] = bytes;
    writes++;
  }

  @override
  Future<void> remove(String url) async => entries.remove(url);
}

Future<Uint8List> makePng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final pixel = await picture.toImage(1, 1);
  final data = (await pixel.toByteData(format: ui.ImageByteFormat.png))!;
  final png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  pixel.dispose();
  picture.dispose();
  return png;
}

Future<ImageInfo> loadImage(ReaderImageProvider provider) async {
  final done = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((image, _) => done.complete(image),
      onError: (Object error, StackTrace? stack) =>
          done.completeError(error, stack));
  stream.addListener(listener);
  try {
    return await done.future.timeout(const Duration(seconds: 3));
  } finally {
    stream.removeListener(listener);
  }
}

class StreamingClient extends http.BaseClient {
  final bodies = <StreamController<List<int>>>[];
  final urls = <Uri>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw http.ClientException('closed');
    urls.add(request.url);
    final body = StreamController<List<int>>();
    bodies.add(body);
    return http.StreamedResponse(body.stream, 200);
  }

  @override
  void close() {
    closed = true;
    for (final body in bodies) {
      body.addError(http.ClientException('cancelled'));
      body.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(Uri.parse('https://example.org'));
    registerFallbackValue(<String, String>{});
  });

  test(
      'exit aborts both image and thumbnail streams; reentry owns fresh requests',
      () async {
    final cookies = MockCookies();
    when(() => cookies.applyRequestHeaders(any(), any()))
        .thenAnswer((_) async {});
    final client = StreamingClient();
    final requests = ReaderRequestController(imageClientFactory: () => client);
    final files = EhImageCacheManager.readerFileService(cookies, requests);
    const bigUrl = 'https://example.org/full.jpg';
    const thumbUrl = 'https://example.org/thumb.jpg';
    final big = await files.get(bigUrl);
    final thumb = await files.get(thumbUrl);
    final bigDone =
        expectLater(big.content.toList(), throwsA(isA<http.ClientException>()));
    final thumbDone = expectLater(
        thumb.content.toList(), throwsA(isA<http.ClientException>()));

    requests.cancel();
    expect(requests.cancelToken.isCancelled, isTrue);
    expect(client.closed, isTrue);
    await Future.wait([bigDone, thumbDone]);
    await expectLater(files.get(bigUrl), throwsStateError);
    expect(client.urls, hasLength(2));

    final nextClient = StreamingClient();
    final next = ReaderRequestController(imageClientFactory: () => nextClient);
    final nextFiles = EhImageCacheManager.readerFileService(cookies, next);
    final response = await nextFiles.get(bigUrl);
    final bytes = response.content.toList();
    nextClient.bodies.single.add([1, 2, 3]);
    await nextClient.bodies.single.close();
    expect(await bytes, [
      [1, 2, 3]
    ]);
    expect(nextClient.urls.single.toString(), bigUrl);
    // The response has completed; don't enqueue cancellation errors on it.
    nextClient.bodies.clear();
    next.cancel();
  });

  test('work waiting for cookie preparation cannot start a request after exit',
      () async {
    final cookies = MockCookies();
    final preparing = Completer<void>();
    final entered = Completer<void>();
    when(() => cookies.applyRequestHeaders(any(), any())).thenAnswer((_) {
      entered.complete();
      return preparing.future;
    });
    final client = StreamingClient();
    final requests = ReaderRequestController(imageClientFactory: () => client);
    final files = EhImageCacheManager.readerFileService(cookies, requests);
    final pending = expectLater(
        files.get('https://example.org/image.jpg'), throwsStateError);
    await entered.future;
    requests.cancel();
    preparing.complete();
    await pending;
    expect(client.urls, isEmpty);
  });

  test('image cache keys distinguish retry attempts and reopened sessions', () {
    final cookies = MockCookies();
    final first = ReaderRequestController();
    final second = ReaderRequestController();
    final files = EhImageCacheManager.readerFileService(cookies, first);
    const url = 'https://example.org/image.jpg';
    final cache = MemoryImageCache();
    final original = ReaderImageProvider(url,
        requests: first, fileService: files, cache: cache);
    final retry = ReaderImageProvider(url,
        requests: first, fileService: files, cache: cache, attempt: 1);
    final reopened = ReaderImageProvider(url,
        requests: second, fileService: files, cache: cache);
    expect(original, isNot(retry));
    expect(original, isNot(reopened));
    expect(
        original,
        ReaderImageProvider(url,
            requests: first, fileService: files, cache: cache));
    first.cancel();
    second.cancel();
    PaintingBinding.instance.imageCache.clear();
  });

  test('retry downloads again, but successful images survive reentry',
      () async {
    final png = await makePng();
    final files = MockFiles();
    final cache = MemoryImageCache();
    var fetches = 0;
    const url = 'https://example.org/retry.png';
    when(() => files.get(url)).thenAnswer((_) async {
      fetches++;
      return HttpGetResponse(http.StreamedResponse(
          Stream.value(fetches == 1 ? <int>[] : png), fetches == 1 ? 403 : 200,
          contentLength: fetches == 1 ? 0 : png.length,
          headers: {'content-type': 'image/png'}));
    });
    final requests = ReaderRequestController();
    await expectLater(
        loadImage(ReaderImageProvider(url,
            requests: requests, fileService: files, cache: cache)),
        throwsA(isA<NetworkImageLoadException>()));
    expect(cache.entries, isEmpty);
    final retry = ReaderImageProvider(url,
        requests: requests, fileService: files, cache: cache, attempt: 1);
    final decoded = await loadImage(retry);
    expect(decoded.image.width, 1);
    decoded.dispose();
    expect(fetches, 2);
    requests.cancel();
    expect(cache.entries[url], png);

    final reopened = ReaderRequestController();
    final again = await loadImage(ReaderImageProvider(url,
        requests: reopened, fileService: files, cache: cache));
    expect(again.image.height, 1);
    again.dispose();
    expect(fetches, 2, reason: 'Reentry must reuse the completed image');
    reopened.cancel();

    // Explicit cache clearing must still allow a subsequent fresh download.
    await cache.remove(url);
    final afterClear = ReaderRequestController();
    (await loadImage(ReaderImageProvider(url,
            requests: afterClear, fileService: files, cache: cache)))
        .dispose();
    expect(fetches, 3);
    afterClear.cancel();
  });

  for (final failure in ['http', 'empty', 'invalid']) {
    test('$failure failures are not cached and reentry requests again',
        () async {
      final png = await makePng();
      final cache = MemoryImageCache();
      final files = MockFiles();
      var fetches = 0;
      final url = 'https://example.org/$failure.png';
      when(() => files.get(url)).thenAnswer((_) async {
        fetches++;
        final bytes = fetches > 1
            ? png
            : failure == 'invalid'
                ? [1, 2, 3]
                : <int>[];
        return HttpGetResponse(http.StreamedResponse(
            Stream.value(bytes), fetches == 1 && failure == 'http' ? 403 : 200,
            contentLength: bytes.length));
      });
      final first = ReaderRequestController();
      await expectLater(
          loadImage(ReaderImageProvider(url,
              requests: first, fileService: files, cache: cache)),
          throwsA(anything));
      expect(cache.writes, 0);
      first.cancel();
      final next = ReaderRequestController();
      (await loadImage(ReaderImageProvider(url,
              requests: next, fileService: files, cache: cache)))
          .dispose();
      expect(fetches, 2);
      expect(cache.writes, 1);
      next.cancel();
    });
  }

  test(
      'cancelling a partial image saves no cache and allows an immediate restart',
      () async {
    final png = await makePng();
    final cache = MemoryImageCache();
    final cookies = MockCookies();
    when(() => cookies.applyRequestHeaders(any(), any()))
        .thenAnswer((_) async {});
    final oldClient = StreamingClient();
    final oldRequests =
        ReaderRequestController(imageClientFactory: () => oldClient);
    final oldFiles =
        EhImageCacheManager.readerFileService(cookies, oldRequests);
    const url = 'https://example.org/partial.png';
    final pending = expectLater(
        loadImage(ReaderImageProvider(url,
            requests: oldRequests, fileService: oldFiles, cache: cache)),
        throwsA(anything));
    // Let the request reach the body stream, then provide only part of a PNG.
    while (oldClient.bodies.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    oldClient.bodies.single.add(png.sublist(0, 8));
    oldRequests.cancel();
    expect(oldClient.closed, isTrue);
    expect(cache.entries, isEmpty);

    final next = ReaderRequestController();
    final nextFiles = MockFiles();
    when(() => nextFiles.get(url)).thenAnswer((_) async => HttpGetResponse(
        http.StreamedResponse(Stream.value(png), 200,
            contentLength: png.length)));
    (await loadImage(ReaderImageProvider(url,
            requests: next, fileService: nextFiles, cache: cache)))
        .dispose();
    await pending;
    expect(cache.writes, 1);
    expect(cache.entries[url], png);
    next.cancel();
  });

  test('corrupt cached bytes are replaced, and explicit retry bypasses cache',
      () async {
    final png = await makePng();
    final cache = MemoryImageCache();
    const url = 'https://example.org/corrupt.png';
    cache.entries[url] = Uint8List.fromList([1, 2, 3]);
    final files = MockFiles();
    var fetches = 0;
    when(() => files.get(url)).thenAnswer((_) async {
      fetches++;
      return HttpGetResponse(http.StreamedResponse(Stream.value(png), 200,
          contentLength: png.length));
    });
    final requests = ReaderRequestController();
    (await loadImage(ReaderImageProvider(url,
            requests: requests, fileService: files, cache: cache)))
        .dispose();
    expect(fetches, 1);
    expect(cache.entries[url], png);
    (await loadImage(ReaderImageProvider(url,
            requests: requests, fileService: files, cache: cache, attempt: 1)))
        .dispose();
    expect(fetches, 2);
    requests.cancel();
  });

  test('a codec whose first frame fails is never written to successful cache',
      () async {
    final png = await makePng();
    final cache = MemoryImageCache();
    final files = MockFiles();
    const url = 'https://example.org/broken-frame.png';
    when(() => files.get(url)).thenAnswer((_) async => HttpGetResponse(
        http.StreamedResponse(Stream.value(png), 200,
            contentLength: png.length)));
    final codec = BrokenFrameCodec();
    when(() => codec.getNextFrame())
        .thenAnswer((_) async => throw StateError('Invalid frame'));
    final requests = ReaderRequestController();
    final provider = ReaderImageProvider(url,
        requests: requests, fileService: files, cache: cache);
    final done = Completer<void>();
    final listener = ImageStreamListener((_, __) => done.complete(),
        onError: (Object error, StackTrace? stack) =>
            done.completeError(error, stack));
    final completer =
        provider.loadImage(provider, (buffer, {getTargetSize}) async {
      buffer.dispose();
      return codec;
    });
    completer.addListener(listener);
    await expectLater(done.future, throwsStateError);
    completer.removeListener(listener);
    expect(cache.writes, 0);
    verify(() => codec.dispose()).called(1);
    requests.cancel();
  });
}
