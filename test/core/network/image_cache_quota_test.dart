import 'dart:async';
import 'dart:io' as io;
import 'package:file/file.dart' show File;
import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/models/reader_page_resource.dart';
import 'reader_image_session_test.dart' show makePng;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_cache_manager/src/storage/cache_object.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/image_cache_quota.dart';
import 'package:oviewer/core/network/reader_image_provider.dart';

class MockFiles extends Mock implements FileService {}

class FailingQuota extends ImageCacheQuota {
  bool fail = true;
  FailingQuota(super.delegate, super.files, {required super.limitBytes});
  @override
  Future<void> deleteCachedFile(File file) async {
    if (fail) throw const io.FileSystemException('busy');
    await super.deleteCachedFile(file);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late io.Directory directory;
  late MockFiles files;
  late EhImageCacheManager manager;
  late Config config;
  setUp(() async {
    directory = await io.Directory.systemTemp.createTemp('oviewer-quota-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
    files = MockFiles();
    when(() => files.concurrentFetches).thenReturn(10);
    config = Config('images',
        fileService: files,
        repo: JsonCacheInfoRepository.withFile(
            io.File('${directory.path}/metadata.json')));
    manager = EhImageCacheManager.forTesting(config, limitBytes: 8);
    await manager.getFileFromCache('initialize');
  });
  tearDown(() async {
    await manager.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    expect(
        directory.parent.absolute.path, io.Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
  });
  Future<void> write(String key, int bytes) async {
    await manager.putFile(key, Uint8List(bytes));
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }

  test('failed streamed writes cannot leave excess unregistered files',
      () async {
    Stream<List<int>> broken() async* {
      yield List.filled(12, 1);
      throw StateError('interrupted');
    }

    await expectLater(
        manager.putFileStream('interrupted', broken()), throwsStateError);
    expect(await manager.getSizeBytes(), lessThanOrEqualTo(8));
    expect(await manager.readBytes('interrupted'), isNull);
  });

  test('decoded reader image and Save survive oversized disk eviction',
      () async {
    final png = await makePng();
    final requests = ReaderRequestController();
    final ready = Completer<ImageInfo>();
    ReaderPageResource? resource;
    when(() => files.get('reader')).thenAnswer((_) async => HttpGetResponse(
        http.StreamedResponse(Stream.value(png), 200,
            contentLength: png.length)));
    final stream = ReaderImageProvider('reader',
            requests: requests,
            fileService: files,
            cache: ReaderImageCache(manager),
            onResourceReady: (value) => resource = value)
        .resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      if (!ready.isCompleted) ready.complete(info.clone());
    },
        onError: (Object error, StackTrace? stack) =>
            ready.completeError(error, stack));
    stream.addListener(listener);
    final frame = await ready.future;
    expect(frame.image.width, greaterThan(0));
    await manager.enforceLimit();
    expect(await manager.getSizeBytes(), 0);
    expect(await resource!.snapshot(), png);
    stream.removeListener(listener);
    requests.cancel();
    frame.dispose();
    await expectLater(resource!.snapshot(), throwsStateError);
  });

  test(
      'real byte limit evicts least recently read, including memory-cache hits',
      () async {
    await write('cover', 4);
    await write('preview', 4);
    expect(await manager.getSizeBytes(), 8);
    await manager.readBytes('cover');
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await write('reader', 4);
    expect(await manager.readBytes('preview'), isNull,
        reason:
            '${await manager.getSizeBytes()} bytes; ${(await config.repo.getAllObjects()).map((e) => '${e.key}: ${e.touched}')}');
    expect(await manager.readBytes('cover'), hasLength(4));
    expect(await manager.readBytes('reader'), hasLength(4));
    expect(await manager.getSizeBytes(), 8);
  });

  test('reader stable keys and cover downloads share one disk budget',
      () async {
    final cache = ReaderImageCache(manager);
    await cache.write('https://reader.test/image', Uint8List(6));
    when(() => files.get('https://cover.test/image',
            headers: any(named: 'headers')))
        .thenAnswer((_) async => HttpGetResponse(http.StreamedResponse(
            Stream.value([1, 2, 3, 4, 5, 6]), 200,
            contentLength: 6)));
    await for (final response
        in manager.getFileStream('https://cover.test/image')) {
      if (response is FileInfo) {
        expect(await response.file.readAsBytes(), hasLength(6));
      }
    }
    expect(await cache.read('https://reader.test/image'), isNull);
    expect(await manager.readBytes('https://cover.test/image'), hasLength(6));
    expect(await manager.getSizeBytes(), 6);
  });

  test(
      'oversized active download stays readable then leaves no excess disk bytes',
      () async {
    final received = Completer<FileInfo>();
    final finishReading = Completer<void>();
    when(() => files.get('large', headers: any(named: 'headers'))).thenAnswer(
        (_) async => HttpGetResponse(http.StreamedResponse(
            Stream.value(List.filled(12, 7)), 200,
            contentLength: 12)));
    final reader = () async {
      await for (final response in manager.getFileStream('large')) {
        if (response is FileInfo) {
          received.complete(response);
          await finishReading.future;
          expect(await response.file.readAsBytes(), List.filled(12, 7));
        }
      }
    }();
    final active = await received.future;
    await Future.wait([write('a', 4), write('b', 4), manager.enforceLimit()]);
    expect(await active.file.exists(), isTrue);
    finishReading.complete();
    await reader;
    await manager.enforceLimit();
    expect(await manager.getSizeBytes(), lessThanOrEqualTo(8));
  });

  test(
      'restart applies a smaller budget using persisted LRU order and actual lengths',
      () async {
    await write('old', 4);
    await write('recent', 4);
    await manager.dispose();
    final repository = JsonCacheInfoRepository.withFile(
        io.File('${directory.path}/metadata.json'));
    manager = EhImageCacheManager.forTesting(Config('images', repo: repository),
        limitBytes: 4);
    await manager.enforceLimit();
    expect(await manager.readBytes('old'), isNull);
    expect(await manager.readBytes('recent'), hasLength(4));
    expect(await manager.getSizeBytes(), 4);
  });

  test('orphan files count toward budget; sibling user data is untouched',
      () async {
    final protected =
        io.File('${directory.path}/history-progress-favorites-photo.db');
    await protected.writeAsString('keep all user data');
    final orphan = await config.fileSystem.createFile('orphan.jpg');
    await orphan.writeAsBytes(Uint8List(20));
    await manager.enforceLimit();
    expect(await orphan.exists(), isFalse);
    expect(await manager.getSizeBytes(), 0);
    expect(await protected.readAsString(), 'keep all user data');
  });

  test('failed deletion retains metadata and succeeds on explicit retry',
      () async {
    final repo = JsonCacheInfoRepository.withFile(
        io.File('${directory.path}/failures.json'));
    final quota = FailingQuota(repo, config.fileSystem, limitBytes: 1);
    await quota.open();
    final file = await config.fileSystem.createFile('failed.jpg');
    await file.writeAsBytes(Uint8List(4));
    await quota.insert(CacheObject('failed',
        relativePath: 'failed.jpg', validTill: DateTime(2100)));
    await expectLater(quota.enforce(), throwsA(isA<io.FileSystemException>()));
    expect(quota.cleanupFailed, isTrue);
    expect(await quota.get('failed'), isNotNull);
    expect(await file.exists(), isTrue);
    quota.fail = false;
    await quota.enforce();
    expect(quota.cleanupFailed, isFalse);
    expect(await file.exists(), isFalse);
    expect(await quota.get('failed'), isNull);
    await quota.close();
  });

  test(
      'repeated writes and checks serialize metadata without duplicate entries',
      () async {
    await Future.wait(List.generate(10, (i) => write('same', 4)));
    await manager.enforceLimit();
    final entries = await config.repo.getAllObjects();
    expect(entries.map((e) => e.key).toSet(), {'same'});
    expect(entries, hasLength(1));
    expect(await manager.getSizeBytes(), lessThanOrEqualTo(8));
  });
}
