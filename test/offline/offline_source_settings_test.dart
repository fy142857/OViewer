import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/offline_download_network.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import '../core/network/comment_redirect_test.dart';

class OfflinePreferencesFailure extends InMemorySharedPreferencesStore {
  OfflinePreferencesFailure()
      : super.withData({
          'flutter.offline_parallel_galleries': 2,
          'flutter.offline_parallel_pages': 4,
        });
  bool throwOnWrite = false;
  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (key.startsWith('flutter.offline_parallel_')) {
      if (throwOnWrite) throw StateError('write failed');
      return Future.value(false);
    }
    return super.setValue(type, key, value);
  }
}

String indexHtml(
        {int gid = 42,
        String site = 'https://e-hentai.org',
        String token = 'abc'}) =>
    '''
<link rel="canonical" href="$site/g/$gid/$token/">
<h1 id="gn">Fixture</h1><h1 id="gj">Fixture</h1>
<div id="gdd"><table><tr><td>Length:</td><td>2 pages</td></tr></table></div>
<div id="gdt"><div class="gdtm"><a href="$site/s/aa/$gid-1"><img alt="1" src="https://example.test/1.png"></a></div>
<div class="gdtm"><a href="$site/s/bb/$gid-2"><img alt="2" src="https://example.test/2.png"></a></div></div>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(FakeDio()));
  tearDown(() {
    AppConstants.onSiteChanged = null;
    AppConstants.useExHentai = false;
  });
  test('offline parallel defaults are two books and four global pages',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LocalStorage();
    await storage.init();
    expect(storage.getOfflineParallelGalleries(), 2);
    expect(storage.getOfflineParallelPages(), 4);
    await storage.setOfflineParallelGalleries(3);
    await storage.setOfflineParallelPages(6);
    final restarted = LocalStorage();
    await restarted.init();
    expect(restarted.getOfflineParallelGalleries(), 3);
    expect(restarted.getOfflineParallelPages(), 6);
    await expectLater(storage.setOfflineParallelPages(7), throwsArgumentError);
    await expectLater(
        storage.setOfflineParallelGalleries(0), throwsArgumentError);
    expect(storage.getOfflineParallelPages(), 6);
  });
  test('invalid persisted concurrency values recover to safe defaults',
      () async {
    SharedPreferences.setMockInitialValues(
        {'offline_parallel_galleries': '3', 'offline_parallel_pages': 200});
    final storage = LocalStorage();
    await storage.init();
    expect(storage.getOfflineParallelGalleries(), 2);
    expect(storage.getOfflineParallelPages(), 4);
  });
  for (final throws in [false, true]) {
    test('failed setting writes retain the old stored values (throws=$throws)',
        () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = OfflinePreferencesFailure()
        ..throwOnWrite = throws;
      final storage = LocalStorage();
      await storage.init();
      await expectLater(
          storage.setOfflineParallelGalleries(3), throwsStateError);
      await expectLater(storage.setOfflineParallelPages(6), throwsStateError);
      expect(storage.getOfflineParallelGalleries(), 2);
      expect(storage.getOfflineParallelPages(), 4);
    });
  }
  test('detail result retains its request origin after a global site change',
      () async {
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString(indexHtml(), 200));
    final dio = client(adapter);
    final future = GalleryRepository(dio).fetchGalleryDetail(42, 'abc');
    AppConstants.useExHentai = true;
    final detail = await future;
    expect(detail.source, GallerySource.eh);
    expect(adapter.requests.first.uri.host, 'e-hentai.org');
    expect(detail.withComments([]).source, GallerySource.eh);
  });
  test('explicit EX task cannot download while EH mode is active', () async {
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString(indexHtml(), 200));
    final network = SiteOfflineDownloadNetwork(client(adapter), MockCookies());
    final request = ReaderRequestController();
    addTearDown(request.cancel);
    await expectLater(
        network.index(
            const OfflineKey(GallerySource.ex, 42, 'abc'), 0, request),
        throwsA(isA<OfflineFailure>()
            .having((e) => e.code, 'code', 'source_changed')));
    expect(adapter.requests, isEmpty);
  });
  for (final invalid in ['gid', 'token', 'origin', 'login']) {
    test('offline index rejects wrong $invalid without downloading any image',
        () async {
      final adapter = RedirectAdapter((_, __) => ResponseBody.fromString(
          invalid == 'login'
              ? '<input name="UserName"><input name="PassWord">'
              : indexHtml(
                  gid: invalid == 'gid' ? 43 : 42,
                  token: invalid == 'token' ? 'other' : 'abc',
                  site: invalid == 'origin'
                      ? 'https://exhentai.org'
                      : 'https://e-hentai.org'),
          200));
      final network =
          SiteOfflineDownloadNetwork(client(adapter), MockCookies());
      final request = ReaderRequestController();
      addTearDown(request.cancel);
      await expectLater(
          network.index(
              const OfflineKey(GallerySource.eh, 42, 'abc'), 0, request),
          throwsA(isA<OfflineFailure>()));
      expect(adapter.requests.length, 1);
      expect(adapter.requests.single.followRedirects, isFalse);
    });
  }
  test('valid explicit source index returns all local page identities',
      () async {
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString(indexHtml(), 200));
    final network = SiteOfflineDownloadNetwork(client(adapter), MockCookies());
    final request = ReaderRequestController();
    addTearDown(request.cancel);
    final index = await network.index(
        const OfflineKey(GallerySource.eh, 42, 'abc'), 0, request);
    expect(index.totalPages, 2);
    expect(index.thumbnails.keys, [0, 1]);
  });
}
