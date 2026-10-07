import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/blocs/reader/reader_state.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/reader_image_provider.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/core/storage/reader_reentry_cache.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'package:oviewer/widgets/reader_page_image.dart';
import '../../blocs/reader_bloc_test.dart'
    show MockGalleryRepository, MockHistoryRepository, MockSettingsRepository;
import 'reader_image_session_test.dart'
    show MemoryImageCache, MockFiles, makePng, loadImage;

class Disk extends MemoryImageCache {
  bool failWrite = false;
  Completer<void>? writing;
  @override
  Future<void> write(String url, Uint8List bytes) async {
    if (writing != null) await writing!.future;
    if (failWrite) throw StateError('disk full');
    await super.write(url, bytes);
  }

  @override
  DateTime? get lastReadExpiry => DateTime.now().add(const Duration(days: 1));
}

const image = GalleryImage(
    index: 0, pageUrl: 'page', imageUrl: 'https://example.org/old.png');
ReaderIndexPage metadata({int total = 1, String token = 'page'}) =>
    ReaderIndexPage(
        totalPages: total,
        indexPage: 0,
        indexPageCount: 1,
        pageSize: total,
        thumbnails: {
          for (var i = 0; i < total; i++)
            i: ThumbnailInfo(pageToken: token, pageIndex: i, thumbUrl: '')
        });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(CancelToken()));
  late ReaderReentryCache cache;
  late Disk disk;
  late MockFiles files;
  late ReaderGalleryKey key;
  setUp(() {
    AppConstants.useExHentai = false;
    cache = ReaderReentryCache();
    disk = Disk();
    files = MockFiles();
    key = (AppConstants.baseUrl, 42, 'token');
    final data = metadata();
    cache.prepare(key, data, data.thumbnails, 0);
  });
  tearDown(() {
    cache.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> seed() async {
    final png = await makePng();
    when(() => files.get(image.imageUrl)).thenAnswer((_) async =>
        HttpGetResponse(http.StreamedResponse(Stream.value(png), 200)));
    final requests = ReaderRequestController();
    (await loadImage(ReaderImageProvider(image.imageUrl,
            requests: requests,
            fileService: files,
            cache: disk,
            reentry: cache,
            ticket: cache.ticket(key, 0),
            galleryImage: image)))
        .dispose();
    requests.cancel();
  }

  ReaderImageProvider reopened(ReaderRequestController requests,
          {VoidCallback? miss, ValueChanged<dynamic>? ready}) =>
      ReaderImageProvider(image.imageUrl,
          requests: requests,
          fileService: files,
          cache: disk,
          reentry: cache,
          ticket: cache.ticket(key, 0),
          galleryImage: image,
          cacheOnly: true,
          onCacheMiss: miss,
          onResourceReady: ready);

  testWidgets(
      'warm reentry displays full frame on first widget frame and restores Save resource',
      (tester) async {
    await tester.runAsync(seed);
    final requests = ReaderRequestController();
    dynamic resource;
    await tester.pumpWidget(MaterialApp(
        home: ReaderPageImage(
            image: reopened(requests, ready: (r) => resource = r),
            errorBuilder: (_, __, ___) => const Text('error'))));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.pump();
    expect(await resource.snapshot(), disk.entries[image.imageUrl]);
    verify(() => files.get(image.imageUrl)).called(1);
    await tester.pumpWidget(const SizedBox.shrink());
    requests.cancel();
  });

  test('memory pressure retains page mapping and reads disk without network',
      () async {
    await seed();
    expect(cache.memoryBytes, greaterThan(0));
    cache.didHaveMemoryPressure();
    expect(cache.memoryBytes, 0);
    expect(cache.get(key)!.pages[0]!.durable, true);
    final requests = ReaderRequestController();
    (await loadImage(reopened(requests))).dispose();
    verify(() => files.get(image.imageUrl)).called(1);
    requests.cancel();
  });

  for (final corrupt in [false, true]) {
    test(
        'local ${corrupt ? 'corruption' : 'miss'} signals fallback without downloading old URL',
        () async {
      await seed();
      cache.releaseFrames();
      if (corrupt) {
        disk.entries[image.imageUrl] = (await makePng()).sublist(0, 8);
      } else {
        disk.entries.clear();
      }
      var misses = 0;
      final requests = ReaderRequestController();
      await expectLater(loadImage(reopened(requests, miss: () => misses++)),
          throwsA(isA<ReaderLocalCacheMiss>()));
      expect(misses, 1);
      verify(() => files.get(image.imageUrl)).called(1);
      requests.cancel();
    });
  }

  test('cache and page generations reject late completed work', () async {
    final png = await makePng();
    final old = cache.ticket(key, 0)!;
    cache.invalidatePage(key, 0);
    cache.complete(old, image, 'key', null, png, durable: true);
    expect(cache.get(key), isNull);
    final next = cache.ticket(key, 0)!;
    cache.clear();
    cache.complete(next, image, 'key', null, png, durable: true);
    expect(cache.get(key), isNull);
  });

  test('expiry, gallery identity, metadata changes and history invalidation',
      () async {
    var now = DateTime.utc(2026, 10, 7);
    cache = ReaderReentryCache(now: () => now);
    final data = metadata();
    cache.prepare(key, data, data.thumbnails, 0);
    final png = await makePng();
    cache.complete(cache.ticket(key, 0)!, image, 'key', null, png,
        durable: true, expires: now.add(const Duration(minutes: 1)));
    expect(cache.get(('https://exhentai.org', 42, 'token')), isNull);
    expect(cache.get((key.$1, 42, 'other')), isNull);
    now = now.add(const Duration(minutes: 2));
    expect(cache.get(key), isNull);
    cache.complete(cache.ticket(key, 0)!, image, 'key', null, png,
        durable: true);
    final changed = metadata(token: 'changed');
    cache.prepare(key, changed, changed.thumbnails, 0);
    expect(cache.get(key), isNull);
    cache.complete(cache.ticket(key, 0)!, image, 'key', null, png,
        durable: true);
    cache.removeGallery(42);
    expect(cache.get(key), isNull);
  });

  test(
      'LRU limits galleries, page mappings and decoded memory; current page preferred',
      () async {
    cache = ReaderReentryCache(
        maxGalleries: 2, maxPages: 3, maxFrames: 2, maxBytes: 4096);
    final png = await makePng();
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final data = metadata(total: 4);
    cache.prepare(key, data, data.thumbnails, 0);
    for (var page = 0; page < 3; page++) {
      cache.complete(cache.ticket(key, page)!, image, '$page', frame.image, png,
          durable: true);
    }
    expect(cache.frame(cache.ticket(key, 0)!), isNotNull);
    expect(cache.frame(cache.ticket(key, 1)!), isNull);
    expect(cache.memoryBytes, (4 + png.length) * 2);
    cache.complete(cache.ticket(key, 3)!, image, '3', frame.image, png,
        durable: true);
    expect(cache.get(key)!.pages.length, 3);
    for (var gid = 43; gid < 45; gid++) {
      cache.prepare((key.$1, gid, 'token'), data, data.thumbnails, 0);
    }
    expect(cache.get(key), isNull);
    expect(cache.memoryBytes, 0);
    frame.image.dispose();
    codec.dispose();
  });

  test(
      'failed disk write retains bounded frame and Save bytes without claiming persistence',
      () async {
    disk.failWrite = true;
    await seed();
    expect(cache.get(key)!.pages[0]!.durable, false);
    expect(disk.entries, isEmpty);
    final requests = ReaderRequestController();
    final ready = Completer<dynamic>();
    final stream = reopened(requests, ready: (r) => ready.complete(r))
        .resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose());
    stream.addListener(listener);
    final resource = await ready.future;
    expect(await resource.snapshot(), isNotEmpty);
    stream.removeListener(listener);
    verify(() => files.get(image.imageUrl)).called(1);
    requests.cancel();
  });

  test('late decode/write cannot restore shared state after clearing',
      () async {
    disk.writing = Completer<void>();
    final png = await makePng();
    when(() => files.get(image.imageUrl)).thenAnswer((_) async =>
        HttpGetResponse(http.StreamedResponse(Stream.value(png), 200)));
    final requests = ReaderRequestController();
    final pending = expectLater(
        loadImage(ReaderImageProvider(image.imageUrl,
            requests: requests,
            fileService: files,
            cache: disk,
            reentry: cache,
            ticket: cache.ticket(key, 0),
            galleryImage: image)),
        throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    cache.clear();
    disk.writing!.complete();
    await pending;
    expect(cache.memoryBytes, 0);
    expect(cache.get(key), isNull);
    requests.cancel();
  });

  testWidgets(
      'animated reentry keeps playing distinct frames without downloading',
      (tester) async {
    final gif = base64Decode(
        'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7');
    when(() => files.get(image.imageUrl)).thenAnswer((_) async =>
        HttpGetResponse(http.StreamedResponse(Stream.value(gif), 200)));
    Future<void> pumpFrame() async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    for (var visit = 0; visit < 2; visit++) {
      final requests = ReaderRequestController();
      final provider = visit == 0
          ? ReaderImageProvider(image.imageUrl,
              requests: requests,
              fileService: files,
              cache: disk,
              reentry: cache,
              ticket: cache.ticket(key, 0),
              galleryImage: image)
          : reopened(requests);
      await tester.pumpWidget(MaterialApp(
          home: ReaderPageImage(
              image: provider,
              errorBuilder: (_, __, ___) => const Text('error'))));
      final colors = <int>{};
      for (var n = 0; n < 15 && colors.length < 2; n++) {
        await pumpFrame();
        if (find.byType(RawImage).evaluate().isEmpty) continue;
        final raw = tester.widget<RawImage>(find.byType(RawImage));
        if (raw.image != null) {
          final data = await tester.runAsync(() => raw.image!.toByteData());
          colors.add(data!.getUint32(0));
        }
      }
      expect(colors.length, 2);
      expect(cache.memoryBytes, 0);
      expect(cache.get(key)!.pages[0]!.durable, true);
      await tester.pumpWidget(const SizedBox.shrink());
      requests.cancel();
    }
    verify(() => files.get(image.imageUrl)).called(1);
  });

  test('session invalidation and history removal clear the shared cache',
      () async {
    final shared = ReaderReentryCache.shared;
    final png = await makePng();
    void insert() {
      final data = metadata();
      shared.prepare(key, data, data.thumbnails, 0);
      shared.complete(shared.ticket(key, 0)!, image, 'key', null, png,
          durable: true);
    }

    insert();
    final old = shared.ticket(key, 0)!;
    ReaderIndexCache.shared.clear();
    expect(shared.get(key), isNull);
    expect(shared.accepts(old), false);
    insert();
    ReaderIndexCache.shared.removeGallery(42);
    expect(shared.get(key), isNull);
  });

  test('oversize frames keep disk mapping without exceeding the memory budget',
      () async {
    cache = ReaderReentryCache(maxBytes: 1);
    final data = metadata();
    cache.prepare(key, data, data.thumbnails, 0);
    final png = await makePng();
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    cache.complete(cache.ticket(key, 0)!, image, 'key', frame.image, png,
        durable: true);
    expect(cache.memoryBytes, 0);
    expect(cache.get(key)!.pages[0]!.durable, true);
    frame.image.dispose();
    codec.dispose();
  });

  test(
      'new bloc synchronously restores page and avoids all metadata network; missing bytes refetch once',
      () async {
    await seed();
    final gallery = MockGalleryRepository();
    final history = MockHistoryRepository();
    final settings = MockSettingsRepository();
    when(() => gallery.readerIndexCache).thenReturn(ReaderIndexCache());
    when(() => settings.getReadingMode()).thenReturn(0);
    when(() => history.updateProgress(any(), any(), any()))
        .thenAnswer((_) async {});
    const request = LoadReaderImages(gid: 42, token: 'token', initialPage: 0);
    final bloc = ReaderBloc(gallery, history, settings,
        initialRequest: request, reentryCache: cache);
    expect(bloc.state.status, ReaderStatus.ready);
    expect(bloc.state.loadedImages[0], image);
    bloc.add(request);
    await Future<void>.delayed(Duration.zero);
    verifyNever(() => gallery.fetchImage(any(), any(), any(),
        cancelToken: any(named: 'cancelToken')));
    final response = Completer<GalleryImage>();
    when(() => gallery.fetchImage('page', 42, 0,
            cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) => response.future);
    bloc.add(const ReaderCachedImageMissing(0, 0));
    bloc.add(const ReaderCachedImageMissing(0, 0));
    await bloc.stream.firstWhere((s) => s.loadingIndices.contains(0));
    response.complete(const GalleryImage(
        index: 0, pageUrl: 'page', imageUrl: 'https://example.org/fresh.png'));
    await bloc.stream.firstWhere((s) =>
        s.loadingIndices.isEmpty &&
        s.loadedImages[0]?.imageUrl.endsWith('fresh.png') == true);
    verify(() => gallery.fetchImage('page', 42, 0,
        cancelToken: any(named: 'cancelToken'))).called(1);
    verifyNever(() => gallery.fetchReaderIndexPage(any(), any(),
        cancelToken: any(named: 'cancelToken')));
    await bloc.close();
  });
}
