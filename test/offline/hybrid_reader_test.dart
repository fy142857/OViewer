import 'dart:async';
import 'dart:typed_data';
import 'package:drift/drift.dart' show Value;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/image_cache_scope.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/core/storage/reader_reentry_cache.dart';
import 'package:oviewer/models/download_range.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/models/reader_page_resource.dart';
import '../widgets/reader_screen_test.dart'
    show MockGallery, MockHistory, MockSettings;
import 'offline_coordinator_test.dart' show until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(CancelToken()));
  late MockGallery gallery;
  late MockHistory history;
  late MockSettings settings;
  late OfflineBook book;
  late Set<int> calls;
  late Set<int> failing;
  Completer<GalleryImage>? gate;
  ReaderBloc? reader;
  setUp(() {
    AppConstants.useExHentai = false;
    ImageCacheScope.setSession('hybrid-test');
    ReaderReentryCache.shared.clear();
    gallery = MockGallery();
    history = MockHistory();
    settings = MockSettings();
    calls = {};
    failing = {};
    gate = null;
    const key = OfflineKey(GallerySource.eh, 42, 'abc');
    book = OfflineBook(
        OfflineGallery(
            id: key.id,
            source: 'eh',
            gid: 42,
            token: 'abc',
            title: 'Partial book',
            totalPages: 50,
            downloadRange: DownloadRange.parse('21', 50).toStorage(),
            status: 'completed',
            createdAt: DateTime(2026),
            lastReadPage: 20,
            indexReady: true,
            indexNeedsRefresh: false,
            everCompleted: false),
        [
          for (var i = 0; i < 50; i++)
            OfflinePage(
                bookId: key.id,
                pageIndex: i,
                pageToken: 'p$i',
                relativePath: i == 20 ? 'local.png' : null,
                sha256: i == 20 ? 'digest' : null,
                bytes: i == 20 ? 10 : 0,
                status: i == 20 ? 'completed' : 'pending',
                verificationVersion: 0),
        ]);
    when(() => gallery.readerIndexCache).thenReturn(ReaderIndexCache());
    when(() => settings.getReadingMode()).thenReturn(0);
    when(() => settings.getReaderPreloadCount()).thenReturn(1);
    when(() => settings.getReaderPageLayout())
        .thenReturn(ReaderPageLayout.single);
    when(() => settings.getReaderSpreadAlignment())
        .thenReturn(ReaderSpreadAlignment.width);
    when(() => history.updateProgress(any(), any(), any()))
        .thenAnswer((_) async {});
    when(() =>
        gallery.fetchReaderIndexPage(42, 'abc',
            cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async =>
        ReaderIndexPage(
            totalPages: 50,
            indexPage: 0,
            indexPageCount: 1,
            pageSize: 50,
            thumbnails: {
              for (var i = 0; i < 50; i++)
                i: ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')
            }));
    for (var i = 0; i < 50; i++) {
      when(() => gallery.fetchImage('p$i', 42, i,
          cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async {
        calls.add(i);
        if (failing.contains(i)) throw StateError('network unavailable');
        if (gate != null) return gate!.future;
        return GalleryImage(
            index: i, pageUrl: '', imageUrl: 'https://example.test/$i.png');
      });
    }
  });
  tearDown(() async {
    await reader?.close();
    reader = null;
    ReaderReentryCache.shared.clear();
    AppConstants.useExHentai = false;
  });
  ReaderBloc start({OfflineBook? local}) {
    reader = ReaderBloc(gallery, history, settings, offlineBook: local ?? book);
    reader!.add(const LoadReaderImages(gid: 42, token: 'abc'));
    return reader!;
  }

  for (final mode in [0, 1, 2]) {
    for (final layout in ReaderPageLayout.values) {
      for (var count = 1; count <= 5; count++) {
        test(
            'local-first preserves address lead mode=$mode layout=$layout count=$count',
            () async {
          when(() => settings.getReadingMode()).thenReturn(mode);
          when(() => settings.getReaderPageLayout()).thenReturn(layout);
          when(() => settings.getReaderPreloadCount()).thenReturn(count);
          final bloc = start();
          final expected = bloc.state.preloadWindow.addresses.difference({20});
          await until(
              () => bloc.state.loadedImages.keys.toSet().containsAll(expected));
          expect(calls, expected);
          expect(bloc.state.currentPage, 20);
          expect(bloc.state.totalPages, 50);
          expect(bloc.state.localPage(20), isNotNull);
          expect(bloc.state.offlineBook!.targetPages, 1);
          expect(bloc.state.offlineBook!.completedPages, 1);
          expect(bloc.state.preloadWindow.addresses.length,
              greaterThan(bloc.state.preloadWindow.targets.length));
        });
      }
    }
  }
  test(
      'failed fallback retries after reconnect without expanding the download target',
      () async {
    failing.add(21);
    final bloc = start();
    bloc.add(const PageChanged(21));
    await until(() => bloc.state.failedIndices.contains(21));
    failing.clear();
    bloc.add(const RetryImageAtIndex(21));
    await until(() => bloc.state.loadedImages.containsKey(21));
    expect(bloc.state.failedIndices.contains(21), false);
    expect(bloc.state.offlineBook!.range.label, '21');
    expect(bloc.state.offlineBook!.completedTargetPages, 1);
  });
  test(
      'ordinary reading cache restores a missing page without another address request',
      () async {
    final cache = ReaderReentryCache.shared;
    final key = (AppConstants.baseUrl, 42, 'abc');
    final metadata = ReaderIndexPage(
        totalPages: 50,
        indexPage: 0,
        indexPageCount: 1,
        pageSize: 50,
        thumbnails: {
          for (var i = 0; i < 50; i++)
            i: ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')
        });
    cache.prepare(key, metadata, metadata.thumbnails, 21);
    cache.complete(
        cache.ticket(key, 21)!,
        const GalleryImage(
            index: 21,
            pageUrl: '',
            imageUrl: 'https://example.test/cached.png'),
        'cache-key',
        null,
        Uint8List.fromList([1, 2, 3]),
        durable: true);
    final bloc = start(
        local: OfflineBook(book.record.copyWith(lastReadPage: 21), book.pages));
    await until(() => bloc.state.loadedImages.containsKey(21));
    expect(bloc.state.cacheOnlyPages.contains(21), true);
    expect(bloc.state.loadedImages[21]!.imageUrl,
        'https://example.test/cached.png');
    expect(calls.contains(21), false);
    expect(bloc.state.offlineBook!.targetPages, 1);
  });
  test('deletion rejects late network results', () async {
    gate = Completer<GalleryImage>();
    final bloc = start();
    await until(() => calls.isNotEmpty);
    bloc.add(const OfflineReaderChanged(null));
    await until(() => bloc.state.status.name == 'deleted');
    gate!.complete(const GalleryImage(
        index: 21, pageUrl: '', imageUrl: 'https://example.test/late.png'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(bloc.state.loadedImages, isEmpty);
    expect(bloc.state.status.name, 'deleted');
  });
  test('wrong site never requests fallback but keeps local pages available',
      () async {
    AppConstants.useExHentai = true;
    final bloc = start();
    await until(() => bloc.state.failedIndices.isNotEmpty);
    expect(calls, isEmpty);
    expect(bloc.state.localPage(20), isNotNull);
    verifyNever(() => gallery.fetchReaderIndexPage(42, 'abc',
        cancelToken: any(named: 'cancelToken')));
  });
  test('late network result after session change does not replace a local page',
      () async {
    gate = Completer<GalleryImage>();
    final bloc = start();
    await until(() => calls.isNotEmpty);
    ImageCacheScope.setSession('changed-session');
    gate!.complete(const GalleryImage(
        index: 21, pageUrl: '', imageUrl: 'https://example.test/late.png'));
    await until(() => bloc.state.loadingIndices.isEmpty);
    expect(bloc.state.loadedImages, isEmpty);
    expect(bloc.state.failedIndices, isNotEmpty);
    expect(bloc.state.localPage(20), isNotNull);
  });
  test('download arrival retains an already decoded visible network page',
      () async {
    final bloc = start();
    bloc.add(const PageChanged(21));
    await until(() =>
        bloc.state.loadedImages.containsKey(21) &&
        !bloc.state.loadingIndices.contains(21));
    final resource = ReaderPageResource(() async => null,
        fallback: Uint8List.fromList([1, 2, 3]));
    bloc.add(ReaderImageReady(21, 0, resource));
    await until(() => bloc.state.readyResources.containsKey(21));
    final updated = OfflineBook(book.record, [
      for (final page in book.pages)
        if (page.pageIndex == 21)
          page.copyWith(
              status: 'completed',
              bytes: 3,
              relativePath: const Value('new.png'),
              sha256: const Value('new-digest'))
        else
          page
    ]);
    bloc.add(OfflineReaderChanged(updated));
    await until(() => bloc.state.offlineBook == updated);
    expect(identical(bloc.state.readyResources[21], resource), true);
    expect(bloc.state.imageAttempts[21] ?? 0, 0);
    expect(await resource.snapshot(), [1, 2, 3]);
    bloc.add(const ChangeReaderPreferences(1, ReaderPageLayout.doublePage,
        alignment: ReaderSpreadAlignment.width));
    await until(() => bloc.state.readingMode == 1);
    expect(bloc.state.retainedNetworkPages, isEmpty);
    expect(bloc.state.localPage(21), isNotNull,
        reason: 'explicit presentation changes must prefer the new local file');
    bloc.add(const PageChanged(22));
    await until(() => bloc.state.currentPage == 22);
    expect(bloc.state.localPage(21), isNotNull);
  });
  test('damaged local page falls back once and rejects a stale error report',
      () async {
    final bloc = start();
    await until(() => calls.isNotEmpty);
    final page = book.pages[20];
    bloc.add(ReaderLocalPageFailed(page, 0));
    await until(() => bloc.state.loadedImages.containsKey(20));
    expect(bloc.state.localPage(20), isNull);
    expect(bloc.state.imageAttempts[20], 1);
    bloc.add(ReaderLocalPageFailed(page, 0));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bloc.state.imageAttempts[20], 1);
  });
}
