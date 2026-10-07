import 'dart:io';
import 'package:oviewer/core/storage/reader_reentry_cache.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/reader_image_provider.dart';
import 'package:oviewer/core/network/reader_image_cache_key.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'reader_image_session_test.dart' show MockFiles, makePng, loadImage;

const descriptor =
    '0123456789abcdef0123456789abcdef01234567-316934-1280-1791-wbp';
const original =
    'abcdef0123456789abcdef0123456789abcdef0123-2864824-2220-3106-jpg';
const normal = 'https://first.hath.network:443/h/$descriptor/key=old/03.webp';
const alternate =
    'https://second.hath.network/om/session/$original/$descriptor/1280/key-new/03.webp';

class ControlledClearCache extends EhImageCacheManager {
  final gates = <String, Completer<void>>{};
  final failures = <String>{};
  ControlledClearCache(super.config) : super.forTesting();
  @override
  Future<void> removeFile(String key) async {
    final gate = gates[key];
    if (gate != null) await gate.future;
    if (failures.contains(key)) {
      throw const FileSystemException('Test deletion failure');
    }
    await super.removeFile(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ControlledClearCache manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('oviewer-reader-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
    manager = ControlledClearCache(Config('reader-cache-test',
        repo: JsonCacheInfoRepository.withFile(
            File('${directory.path}/cache.json'))));
    await manager.getFileFromCache('initialize-test-cache');
  });
  tearDown(() async {
    await manager.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
  });

  test(
      'clear awaits every disk deletion, coalesces calls and clears decoded memory',
      () async {
    final png = await makePng();
    final first = await manager.putFile('https://example.test/one', png);
    final second = await manager.putFile('https://example.test/two', png);
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final ready = Completer<void>();
    final memory = PaintingBinding.instance.imageCache;
    final image = memory.putIfAbsent(
        'clear-cache-test-image',
        () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: frame.image))))!;
    final listener = ImageStreamListener((info, _) {
      info.dispose();
      if (!ready.isCompleted) ready.complete();
    });
    image.addListener(listener);
    await ready.future;
    expect(memory.liveImageCount, greaterThan(0));
    final gate = Completer<void>();
    manager.gates['https://example.test/one'] = gate;
    var finished = false;
    final clearing = manager.emptyCache();
    expect(identical(clearing, manager.emptyCache()), true);
    clearing.then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    expect(await first.exists(), true);
    gate.complete();
    await clearing;
    expect(await first.exists(), false);
    expect(await second.exists(), false);
    expect(memory.currentSize, 0);
    expect(memory.liveImageCount, 0);
    expect(memory.pendingImageCount, 0);
    image.removeListener(listener);
  });

  test(
      'failed deletion is reported and remains retryable while other files clear',
      () async {
    final png = await makePng();
    const failedKey = 'https://example.test/blocked';
    final blocked = await manager.putFile(failedKey, png);
    final removed =
        await manager.putFile('https://example.test/removable', png);
    manager.failures.add(failedKey);
    await expectLater(
        manager.emptyCache(), throwsA(isA<FileSystemException>()));
    expect(await blocked.exists(), true);
    expect(await removed.exists(), false);
    expect(await manager.getFileFromCache(failedKey), isNotNull);
    manager.failures.clear();
    await manager.emptyCache();
    expect(await blocked.exists(), false);
    expect(await manager.getFileFromCache(failedKey), isNull);
  });

  test(
      'size counts actual files, expired bytes and files without index entries',
      () async {
    final png = await makePng();
    expect(await manager.getSizeBytes(), 0);
    await manager.putFile('https://example.test/current', png);
    await manager.putFile('https://example.test/expired', png,
        maxAge: const Duration(days: -1));
    final unindexed =
        await manager.store.fileSystem.createFile('unindexed-test.file');
    await unindexed.writeAsBytes([1, 2, 3], flush: true);
    expect(await manager.getSizeBytes(), png.length * 2 + 3);
    await unindexed.delete();
    await manager.emptyCache();
    expect(await manager.getSizeBytes(), 0);
  });

  test(
      'settings total includes retained reader memory and clear removes both layers',
      () async {
    final png = await makePng();
    await manager.putFile('https://example.test/current', png);
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final cache = ReaderReentryCache.shared;
    const key = ('https://e-hentai.org', 42, 'token');
    final data = ReaderIndexPage(
        totalPages: 1,
        indexPage: 0,
        indexPageCount: 1,
        pageSize: 1,
        thumbnails: {});
    cache.prepare(key, data, {}, 0);
    cache.complete(
        cache.ticket(key, 0)!,
        const GalleryImage(
            index: 0,
            pageUrl: 'page',
            imageUrl: 'https://example.test/current'),
        'key',
        frame.image,
        png,
        durable: true);
    expect(await manager.getSizeBytes(), png.length * 2 + 4);
    expect(manager.retainedMemoryBytes, png.length + 4);
    await manager.emptyCache();
    expect(await manager.getSizeBytes(), 0);
    expect(cache.get(key), isNull);
    frame.image.dispose();
    codec.dispose();
  });

  test('clearing during an unfinished disk write cannot restore a cache file',
      () async {
    final started = Completer<void>();
    final source =
        StreamController<List<int>>(onListen: () => started.complete());
    final result = expectLater(
        manager.putFileStream('https://example.test/late', source.stream),
        throwsStateError);
    await started.future;
    await manager.emptyCache();
    source.add(await makePng());
    await source.close();
    await result;
    expect(await manager.getFileFromCache('https://example.test/late'), isNull);
    expect(await manager.getSizeBytes(), 0);
  });

  test('same displayed content survives server, route and access-key changes',
      () {
    expect(readerImageCacheKey(normal), readerImageCacheKey(alternate));
    expect(readerImageCacheKey(normal.replaceAll('key=old', 'key=fresh')),
        readerImageCacheKey(normal));
    for (final different in [
      normal.replaceAll('1280', '1600'),
      normal.replaceAll('wbp', 'jpg'),
      normal.replaceAll('316934', '316935'),
      normal.replaceAll('012345', '112345')
    ]) {
      expect(
          readerImageCacheKey(different), isNot(readerImageCacheKey(normal)));
    }
    for (final unknown in [
      'https://example.org/h/$descriptor/key',
      'https://first.hath.network.evil.test/h/$descriptor/key',
      'https://first.hath.network/h/not-a-file/key',
      'https://first.hath.network/c2/a/b'
    ]) {
      expect(readerImageCacheKey(unknown), unknown);
    }
  });

  test('successful alternate download is reused under normal URL on reentry',
      () async {
    final png = await makePng();
    final files = MockFiles();
    final cache =
        ReaderImageCache(manager, legacyKeys: manager.legacyReaderKeys);
    when(() => files.get(alternate)).thenAnswer((_) async => HttpGetResponse(
        http.StreamedResponse(Stream.value(png), 200,
            contentLength: png.length)));
    final first = ReaderRequestController();
    (await loadImage(ReaderImageProvider(alternate,
            requests: first, fileService: files, cache: cache)))
        .dispose();
    first.cancel();
    final next = ReaderRequestController();
    (await loadImage(ReaderImageProvider(normal,
            requests: next, fileService: files, cache: cache)))
        .dispose();
    verify(() => files.get(alternate)).called(1);
    verifyNever(() => files.get(normal));
    expect(await cache.read(normal), png);
    next.cancel();
    // Explicit retry still bypasses this completed image.
    when(() => files.get(normal)).thenAnswer((_) async => HttpGetResponse(
        http.StreamedResponse(Stream.value(png), 200,
            contentLength: png.length)));
    final retry = ReaderRequestController();
    (await loadImage(ReaderImageProvider(normal,
            requests: retry, fileService: files, cache: cache, attempt: 1)))
        .dispose();
    verify(() => files.get(normal)).called(1);
    retry.cancel();
  });

  test('old URL-only successful cache is reusable without another download',
      () async {
    final png = await makePng();
    await manager.putFile(alternate, png, maxAge: const Duration(days: 7));
    await Future<void>.delayed(Duration.zero);
    final cache =
        ReaderImageCache(manager, legacyKeys: manager.legacyReaderKeys);
    final files = MockFiles();
    final requests = ReaderRequestController();
    (await loadImage(ReaderImageProvider(normal,
            requests: requests, fileService: files, cache: cache)))
        .dispose();
    verifyNever(() => files.get(any()));
    expect(await cache.read(normal), png);
    expect(await manager.getFileFromCache(alternate), isNotNull);
    requests.cancel();
    await manager.emptyCache();
    expect(await cache.read(normal), isNull,
        reason: 'Clearing cache must not resurrect legacy aliases');
  });

  test('expired old entries are not reused across hosts', () async {
    await manager.putFile(alternate, await makePng(),
        maxAge: const Duration(days: -1));
    await Future<void>.delayed(Duration.zero);
    final cache =
        ReaderImageCache(manager, legacyKeys: manager.legacyReaderKeys);
    expect(await cache.read(normal), isNull);
  });
}
