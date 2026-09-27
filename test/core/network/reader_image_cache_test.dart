import 'dart:io';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late EhImageCacheManager manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('oviewer-reader-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
    manager = EhImageCacheManager.forTesting(Config('reader-cache-test',
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
