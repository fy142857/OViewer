import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/network/reader_index_session.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/repositories/gallery_repository.dart';

class MockDio extends Mock implements DioClient {}

String indexHtml({int total = 105, int size = 20, int page = 0}) {
  final pages = (total + size - 1) ~/ size;
  final end = ((page + 1) * size).clamp(0, total);
  return '''<html><h1 id="gn">Test</h1><h1 id="gj">Title</h1>
    <table id="gdd"><tr><td>Length:</td><td>$total pages</td></tr></table>
    <table class="ptt"><tr><td>Prev</td>
    ${List.generate(pages, (p) => '<td><a href="?p=$p">${p + 1}</a></td>').join()}
    <td>Next</td></tr></table><div id="gdt">
    ${[
    for (var i = page * size; i < end; i++)
      '<a href="https://e-hentai.org/s/a${i.toRadixString(16)}/42-${i + 1}"><img src="https://example.org/$i.jpg"></a>'
  ].join()}
    </div></html>''';
}

void main() {
  late MockDio dio;
  late ReaderIndexCache cache;
  late GalleryRepository repository;
  final originalSite = AppConstants.useExHentai;
  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    AppConstants.useExHentai = false;
    dio = MockDio();
    cache = ReaderIndexCache();
    repository = GalleryRepository(dio, indexCache: cache);
  });
  tearDown(() => AppConstants.useExHentai = originalSite);

  for (final size in [20, 40]) {
    test('parses $size-entry pagination including short final pages', () {
      final count = (105 + size - 1) ~/ size;
      for (final page in [0, count - 1]) {
        final parsed = GalleryDetailParser.parseReaderIndex(
            indexHtml(size: size, page: page),
            page: page);
        expect(parsed.totalPages, 105);
        expect(parsed.pageSize, size);
        expect(parsed.indexPageCount, count);
        expect(parsed.thumbnails.keys.first, page * size);
      }
    });
  }

  test('rejects login/empty pages and an incorrect requested page range', () {
    expect(() => GalleryDetailParser.parseReaderIndex('<html>Login</html>'),
        throwsFormatException);
    expect(() => GalleryDetailParser.parseReaderIndex(indexHtml(), page: 2),
        throwsFormatException);
  });

  test('cache isolates sites/tokens and expires without sliding the TTL', () {
    var now = DateTime(2026);
    cache = ReaderIndexCache(now: () => now);
    final page = GalleryDetailParser.parseReaderIndex(indexHtml());
    cache.put('eh', 42, 'token', page);
    expect(cache.get('ex', 42, 'token', 0), isNull);
    expect(cache.get('eh', 42, 'other', 0), isNull);
    now = now.add(const Duration(minutes: 9));
    expect(cache.get('eh', 42, 'token', 0), same(page));
    now = now.add(const Duration(minutes: 1));
    expect(cache.get('eh', 42, 'token', 0), isNull);
  });

  test(
      'cache evicts least recently used galleries and invalidates by generation',
      () {
    cache = ReaderIndexCache(capacity: 2);
    final page = GalleryDetailParser.parseReaderIndex(indexHtml());
    cache.put('eh', 1, 't', page);
    cache.put('eh', 2, 't', page);
    cache.get('eh', 1, 't', 0);
    cache.put('eh', 3, 't', page);
    expect(cache.get('eh', 2, 't', 0), isNull);
    expect(cache.get('eh', 1, 't', 0), isNotNull);
    cache.clear();
    expect(cache.generation, 1);
    expect(cache.get('eh', 1, 't', 0), isNull);
  });

  test(
      'one startup HTML request supplies metadata, no title API or duplicate fetch',
      () async {
    const url = 'https://e-hentai.org/g/42/token/?p=0';
    when(() => dio.get(url, cancelToken: any(named: 'cancelToken'))).thenAnswer(
        (_) async => indexHtml().replaceAll('<h1 id="gj">Title</h1>', ''));
    final first = await repository.fetchReaderIndexPage(42, 'token');
    expect(first.totalPages, 105);
    expect(await repository.fetchReaderIndexPage(42, 'token'), same(first));
    verify(() => dio.get(url, cancelToken: any(named: 'cancelToken')))
        .called(1);
    verifyNever(() => dio.post(any(),
        data: any(named: 'data'), cancelToken: any(named: 'cancelToken')));
  });

  test('detail and thumbnail preview responses seed reader index cache',
      () async {
    when(() => dio.get('https://e-hentai.org/g/42/token/',
            cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => indexHtml());
    when(() => dio.get('https://e-hentai.org/g/42/token/?p=2',
            cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => indexHtml(page: 2));
    await repository.fetchGalleryDetail(42, 'token');
    await repository.fetchThumbnails(42, 'token', page: 2);
    final requests = ReaderRequestController();
    final session = ReaderIndexSession(repository, requests, 42, 'token');
    await session.bootstrap();
    expect((await session.ensureImage(45)).pageIndex, 45);
    // These calls are deliberately unstubbed: a duplicate would fail the test.
    verifyNever(() => dio.get('https://e-hentai.org/g/42/token/?p=0',
        cancelToken: any(named: 'cancelToken')));
    verify(() => dio.get('https://e-hentai.org/g/42/token/?p=2',
        cancelToken: any(named: 'cancelToken'))).called(1);
    requests.cancel();
  });

  test(
      'jumping near the end fetches its page directly and merges concurrent lookups',
      () async {
    final calls = <int>[];
    when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((call) async {
      final part = int.parse(Uri.parse(call.positionalArguments.first as String)
          .queryParameters['p']!);
      calls.add(part);
      return indexHtml(page: part);
    });
    final requests = ReaderRequestController();
    final session = ReaderIndexSession(repository, requests, 42, 'token');
    await session.bootstrap();
    session.prioritize(101);
    final result =
        await Future.wait([session.ensureImage(101), session.ensureImage(102)]);
    expect(result.map((r) => r.pageIndex), [101, 102]);
    expect(calls, [0, 5]);
    expect(session.totalPages, 105);
    expect(session.thumbnails.length, 25);
    requests.cancel();
  });

  test(
      'slow background index leaves a slot for current page; latest jump wins queue',
      () async {
    final calls = <int>[];
    final slow = Completer<String>();
    final entered = Completer<void>();
    when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((call) {
      final part = int.parse(Uri.parse(call.positionalArguments.first as String)
          .queryParameters['p']!);
      calls.add(part);
      if (part == 1) {
        entered.complete();
        return slow.future;
      }
      return Future.value(indexHtml(page: part));
    });
    final requests = ReaderRequestController();
    final session = ReaderIndexSession(repository, requests, 42, 'token');
    await session.bootstrap();
    final background = session.ensureImage(20);
    await entered.future;
    final skipped = expectLater(
        session.ensureImage(60), throwsA(isA<ReaderIndexDiscarded>()));
    session.prioritize(101);
    expect((await session.ensureImage(101)).pageIndex, 101);
    expect(calls, [0, 1, 5]);
    slow.complete(indexHtml(page: 1));
    await background;
    await skipped;
    requests.cancel();
  });

  test('changed pagination is corrected once from page zero', () async {
    cache.put(AppConstants.baseUrl, 42, 'token',
        GalleryDetailParser.parseReaderIndex(indexHtml()));
    final calls = <int>[];
    when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((call) async {
      final part = int.parse(Uri.parse(call.positionalArguments.first as String)
          .queryParameters['p']!);
      calls.add(part);
      return indexHtml(size: 40, page: part);
    });
    final requests = ReaderRequestController();
    final session = ReaderIndexSession(repository, requests, 42, 'token');
    await session.bootstrap();
    session.prioritize(45);
    expect((await session.ensureImage(45)).pageIndex, 45);
    expect(calls, [2, 0, 1]);
    requests.cancel();
  });

  for (final invalidate in ['cancel', 'session', 'site']) {
    test('$invalidate prevents a late response from repopulating cache',
        () async {
      final response = Completer<String>();
      final entered = Completer<void>();
      when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) {
        entered.complete();
        return response.future;
      });
      final cancel = CancelToken();
      final pending = expectLater(
          repository.fetchReaderIndexPage(42, 'token', cancelToken: cancel),
          throwsStateError);
      await entered.future;
      if (invalidate == 'cancel') cancel.cancel();
      if (invalidate == 'session') cache.clear();
      if (invalidate == 'site') AppConstants.useExHentai = true;
      response.complete(indexHtml());
      await pending;
      expect(cache.get('https://e-hentai.org', 42, 'token', 0), isNull);
    });
  }
}
