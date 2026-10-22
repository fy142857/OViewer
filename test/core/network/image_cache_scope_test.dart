import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/image_cache_scope.dart';
import 'package:oviewer/core/network/reader_image_provider.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/widgets/scoped_network_image.dart';
import 'reader_image_session_test.dart'
    show MockCookies, MockFiles, StreamingClient;

class ScopeFiles extends FileService {
  final firstStarted = Completer<void>();
  final firstBody = StreamController<List<int>>();
  int calls = 0;
  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final scope = ImageCacheScope.fromTag(headers![ImageCacheScope.header]!);
    final body = ++calls == 1 ? firstBody.stream : Stream.value([7, 8, 9]);
    if (!firstStarted.isCompleted) firstStarted.complete();
    return HttpGetResponse(http.StreamedResponse(body.map((bytes) {
      scope.ensureCurrent();
      return bytes;
    }), 200, headers: {'content-type': 'image/jpeg'}, contentLength: 3));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(Uri.parse("https://example.test/")));
  late Directory directory;
  late EhImageCacheManager manager;
  const url = 'https://ehgt.org/image.jpg';
  final bytes = Uint8List.fromList([1, 2, 3]);
  setUp(() async {
    AppConstants.onSiteChanged = null;
    AppConstants.useExHentai = false;
    ImageCacheScope.setSession('test-session');
    directory = await Directory.systemTemp.createTemp('oviewer-scope-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
    manager = EhImageCacheManager.forTesting(Config('scope-test',
        repo: JsonCacheInfoRepository.withFile(
            File('${directory.path}/cache.json'))));
    await manager.getFileFromCache('initialize');
  });
  tearDown(() async {
    await manager.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
    AppConstants.useExHentai = false;
    ImageCacheScope.setSession('test-session');
  });

  test('disk cache returns on switching back, but old request tickets do not',
      () async {
    final eh = ImageCacheScope.capture();
    final cache = ReaderImageCache(manager, scope: eh);
    await cache.write(url, bytes);
    AppConstants.useExHentai = true;
    final ex = ImageCacheScope.capture();
    expect(await ReaderImageCache(manager, scope: ex).read(url), isNull);
    await ReaderImageCache(manager, scope: ex)
        .write(url, Uint8List.fromList([4]));
    AppConstants.useExHentai = false;
    final returned = ImageCacheScope.capture();
    expect(returned.key(url), eh.key(url));
    expect(eh.isCurrent, false);
    await expectLater(cache.read(url), throwsStateError);
    expect(await ReaderImageCache(manager, scope: returned).read(url), bytes);
    ImageCacheScope.setSession('another-login');
    expect(await ReaderImageCache(manager).read(url), isNull);
    await manager.emptyCache();
    expect(await manager.getFileFromCache(cache.key(url)), isNull);
    expect(
        await manager
            .getFileFromCache(ReaderImageCache(manager, scope: ex).key(url)),
        isNull);
  });

  test('thumbnail memory and disk identities use the same site/session scope',
      () {
    final eh = scopedNetworkImageProvider(url, cacheManager: manager);
    final widget = scopedNetworkImage(imageUrl: url, cacheManager: manager);
    expect(widget.cacheKey, eh.cacheKey);
    AppConstants.useExHentai = true;
    final ex = scopedNetworkImageProvider(url, cacheManager: manager);
    expect(ex, isNot(eh));
    AppConstants.useExHentai = false;
    expect(scopedNetworkImageProvider(url, cacheManager: manager), eh);
    ImageCacheScope.setSession('next-login');
    expect(scopedNetworkImageProvider(url, cacheManager: manager), isNot(eh));
  });

  test('both sites share the same total disk budget', () async {
    await manager.applyLimitMB(1);
    final eh = ReaderImageCache(manager);
    await eh.write(url, Uint8List(700000));
    AppConstants.useExHentai = true;
    final ex = ReaderImageCache(manager);
    await ex.write(url, Uint8List(700000));
    await manager.enforceLimit();
    expect(await manager.getFileFromCache(eh.key(url)), isNull);
    expect(await manager.getFileFromCache(ex.key(url)), isNotNull);
    expect(await manager.getSizeBytes(), lessThanOrEqualTo(1024 * 1024));
  });

  test('reader decoded-image identity includes the captured request scope', () {
    final requests = ReaderRequestController();
    final files = MockFiles();
    ReaderImageProvider provider() {
      final scope = ImageCacheScope.capture();
      return ReaderImageProvider(url,
          requests: requests,
          fileService: files,
          cache: ReaderImageCache(manager, scope: scope),
          imageScope: scope);
    }

    final first = provider();
    expect(provider(), first);
    AppConstants.useExHentai = true;
    expect(provider(), isNot(first));
    AppConstants.useExHentai = false;
    expect(provider(), isNot(first));
    requests.cancel();
  });

  test('session namespace survives restart and rotates for login and logout',
      () async {
    final cookies = app.CookieManager(clearBrowserAuthentication: () async {});
    await cookies.init();
    final guest = ImageCacheScope.capture();
    await cookies.saveLoginCookies(memberId: '1', passHash: 'test');
    final signedIn = ImageCacheScope.capture();
    expect(signedIn.key(url), isNot(guest.key(url)));
    await ReaderImageCache(manager, scope: signedIn).write(url, bytes);
    final restarted =
        app.CookieManager(clearBrowserAuthentication: () async {});
    await restarted.init();
    expect(ImageCacheScope.capture().key(url), signedIn.key(url));
    expect(await ReaderImageCache(manager).read(url), bytes);
    await restarted.saveLoginCookies(memberId: '2', passHash: 'other');
    final nextLogin = ImageCacheScope.capture();
    expect(nextLogin.key(url), isNot(signedIn.key(url)));
    expect(await ReaderImageCache(manager).read(url), isNull);
    await restarted.clearCookies();
    expect(ImageCacheScope.capture().key(url), isNot(nextLogin.key(url)));
    expect(ImageCacheScope.capture().isCurrent, true);
  });

  test('scope is checked after delayed cookie preparation and before HTTP',
      () async {
    final cookies = MockCookies();
    final gate = Completer<void>();
    final entered = Completer<void>();
    when(() => cookies.applyRequestHeaders(any(), any())).thenAnswer((_) {
      entered.complete();
      return gate.future;
    });
    final client = StreamingClient();
    final requests = ReaderRequestController(imageClientFactory: () => client);
    final service = EhImageCacheManager.readerFileService(cookies, requests,
        maxAttempts: 1);
    final response = service.get(url);
    final failed = expectLater(response, throwsStateError);
    await entered.future;
    AppConstants.useExHentai = true;
    gate.complete();
    await failed;
    expect(client.urls, isEmpty);
    requests.cancel();
  });

  test('a late response body cannot survive a site switch', () async {
    final cookies = MockCookies();
    when(() => cookies.applyRequestHeaders(any(), any()))
        .thenAnswer((_) async {});
    final client = StreamingClient();
    final requests = ReaderRequestController(imageClientFactory: () => client);
    final service = EhImageCacheManager.readerFileService(cookies, requests,
        maxAttempts: 1);
    final response = await service.get(url);
    final pending = response.content.toList();
    final failed = expectLater(pending, throwsStateError);
    AppConstants.useExHentai = true;
    client.bodies.single.add([1]);
    await client.bodies.single.close();
    await failed;
    client.bodies.clear();
    requests.cancel();
  });

  test('rapid return to a site retries an inherited obsolete thumbnail stream',
      () async {
    final files = ScopeFiles();
    final scoped = EhImageCacheManager.forTesting(Config('scope-return-test',
        repo: JsonCacheInfoRepository.withFile(
            File('${directory.path}/return.json')),
        fileService: files));
    await scoped.getFileFromCache('initialize');
    final old = ImageCacheScope.capture();
    final first = scoped
        .getFileStream(url, key: old.key(url), headers: old.headers)
        .toList();
    final rejected = expectLater(first, throwsA(isA<ImageScopeExpired>()));
    await files.firstStarted.future;
    AppConstants.useExHentai = true;
    AppConstants.useExHentai = false;
    final current = ImageCacheScope.capture();
    final returned = scoped
        .getFileStream(url, key: current.key(url), headers: current.headers)
        .toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(files.calls, 1,
        reason: 'The library coalesces by the persistent key');
    files.firstBody.add([1, 2, 3]);
    await files.firstBody.close();
    await rejected;
    final results = await returned;
    expect(files.calls, 2);
    expect(await (results.last as FileInfo).file.readAsBytes(), [7, 8, 9]);
    await scoped.dispose();
  });
}
