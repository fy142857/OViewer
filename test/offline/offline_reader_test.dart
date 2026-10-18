import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/models/reader_page_resource.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/offline_image_provider.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/offline_files.dart';
import 'package:oviewer/core/storage/offline_entry_read.dart';
import 'package:oviewer/core/router/app_router.dart';
import 'package:oviewer/core/router/route_observer.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/reader/reader_screen.dart';
import 'package:oviewer/widgets/reader_page_image.dart';
import 'offline_storage_test.dart' show sqliteForTests;
import 'offline_coordinator_test.dart' show until;

class Gallery extends Mock implements GalleryRepository {}

class FileSource extends Mock implements OfflineFiles {}

class EntryRepository extends Mock implements OfflineRepository {}

class History extends Mock implements HistoryRepository {}

class Settings extends Mock implements SettingsRepository {}

class SettingsBlocMock extends Mock implements SettingsBloc {}

class Cookies extends Mock implements CookieManager {}

Future<void> settleOffline(WidgetTester tester) async {
  // Real file I/O and worker-isolate replies cannot complete while only the
  // fake widget clock advances. Yield real time while pumping fullscreen frames.
  for (var i = 0; i < 60; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 25));
    if (i >= 3 &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        !tester.binding.hasScheduledFrame) return;
  }
  fail('Offline reader did not settle after real I/O and layout frames');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqliteForTests);
  late Directory directory;
  late AppDatabase db;
  late OfflineRepository repository;
  late OfflineBook book;
  late Gallery gallery;
  late Settings settings;
  late SettingsBlocMock settingsBloc;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('oviewer-offline-reader-');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = OfflineRepository(db,
        OfflineFiles(root: () async => Directory('${directory.path}/offline')),
        legacyRoot: () async => Directory('${directory.path}/legacy'));
    await repository.initialize();
    book = await repository.create(
        const OfflineKey(GallerySource.eh, 42, 'abc'), 'Local book', 2);
    await repository.putIndex(
        book.id,
        2,
        const [
          ThumbnailInfo(pageToken: 'p0', pageIndex: 0, thumbUrl: ''),
          ThumbnailInfo(pageToken: 'p1', pageIndex: 1, thumbUrl: ''),
        ],
        current: () => true);
    final fixtures = jsonDecode(
        await File('test/fixtures/page_image_formats.json').readAsString());
    final saved = await repository.files.write(
        book.id, 0, Stream.value(base64Decode(fixtures['png'])),
        current: () => true);
    await repository.savePage(book.id, 0, saved, current: () => true);
    book = (await repository.get(book.id))!;
    gallery = Gallery();
    settings = Settings();
    settingsBloc = SettingsBlocMock();
    final history = History();
    when(() => settings.getReadingMode()).thenReturn(0);
    when(() => history.updateProgress(any(), any(), any()))
        .thenAnswer((_) async {});
    when(() => settingsBloc.state)
        .thenReturn(const SettingsState(locale: 'en'));
    when(() => settingsBloc.stream).thenAnswer((_) => const Stream.empty());
    GetIt.I.registerSingleton<GalleryRepository>(gallery);
    GetIt.I.registerSingleton<SettingsRepository>(settings);
    GetIt.I.registerSingleton<HistoryRepository>(history);
    GetIt.I.registerSingleton<CookieManager>(Cookies());
    GetIt.I.registerSingleton<OfflineRepository>(repository);
  });
  tearDown(() async {
    await GetIt.I.reset();
    await repository.dispose();
    await db.close();
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
  });
  testWidgets(
      'vertical resume keeps the requested last page until the user scrolls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    when(() => settings.getReadingMode()).thenReturn(2);
    await tester.runAsync(() async {
      await repository.putIndex(
          book.id,
          5,
          [
            for (var i = 0; i < 5; i++)
              ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')
          ],
          current: () => true);
      book = (await repository.get(book.id))!;
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(
              home: ReaderScreen(
                  gid: 42, token: 'abc', initialPage: 4, offlineBook: book))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleOffline(tester);
    final bloc = tester
        .element(find.byType(ScrollablePositionedList))
        .read<ReaderBloc>();
    expect(bloc.state.currentPage, 4);
    await tester.drag(
        find.byType(ScrollablePositionedList), const Offset(0, 300));
    await settleOffline(tester);
    expect(bloc.state.currentPage, lessThan(4));
    verifyZeroInteractions(gallery);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  });
  for (final mode in [0, 1, 2]) {
    testWidgets(
        'offline mode $mode decodes local pages without any gallery requests',
        (tester) async {
      when(() => settings.getReadingMode()).thenReturn(mode);
      await tester.runAsync(() async {
        await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: MaterialApp(
                home: ReaderScreen(gid: 42, token: 'abc', offlineBook: book))));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settleOffline(tester);
      final decoded = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((i) => i.image != null);
      verifyZeroInteractions(gallery);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      expect(decoded, isTrue);
    });
  }
  test(
      'repair invalidates stale page resources and updates local directory size',
      () async {
    final bloc = ReaderBloc(gallery, GetIt.I<HistoryRepository>(), settings,
        offlineBook: book, offlineRepository: repository);
    final page = book.pages.first;
    final bytes = await repository.files
        .read(page.relativePath!, page.bytes, page.sha256!);
    final initial = ReaderPageResource(() async => null, fallback: bytes);
    bloc.add(ReaderImageReady(0, 0, initial));
    await until(() => bloc.state.readyResources.containsKey(0));
    await repository.failPage(book.id, 0, 'repair');
    await until(() => bloc.state.imageAttempts[0] == 1);
    expect(bloc.state.readyResources.containsKey(0), isFalse);
    final stale = ReaderPageResource(() async => null, fallback: bytes);
    bloc.add(ReaderImageReady(0, 0, stale));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bloc.state.readyResources.containsKey(0), isFalse);
    await expectLater(stale.snapshot(), throwsStateError);
    await repository.putIndex(
        book.id,
        3,
        const [
          ThumbnailInfo(pageToken: 'p0', pageIndex: 0, thumbUrl: ''),
          ThumbnailInfo(pageToken: 'p1', pageIndex: 1, thumbUrl: ''),
          ThumbnailInfo(pageToken: 'p2', pageIndex: 2, thumbUrl: ''),
        ],
        current: () => true);
    await until(() => bloc.state.totalPages == 3);
    expect(bloc.state.thumbnails.length, 3);
    verifyZeroInteractions(gallery);
    await bloc.close();
  });
  testWidgets(
      'deleting a covered reader removes its route without closing the manager',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Home')))));
      navigator.currentState!.push(MaterialPageRoute(
          builder: (_) =>
              ReaderScreen(gid: 42, token: 'abc', offlineBook: book)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleOffline(tester);
    navigator.currentState!.push(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Download manager'))));
    await settleOffline(tester);
    await tester.runAsync(() => repository.delete(book.id));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(find.text('Download manager'), findsOneWidget);
    expect(find.byType(ReaderScreen, skipOffstage: false), findsNothing);
    navigator.currentState!.pop();
    await settleOffline(tester);
    expect(find.text('Home'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'two offline sources stay selectable and return cancels pending history',
      (tester) async {
    final recording = Completer<void>();
    final nav = GlobalKey<NavigatorState>();
    final resolver = EntryRepository();
    final other = OfflineBook(
        book.record.copyWith(id: 'ex-entry', source: const Value('ex')), []);
    when(() => resolver.initialize()).thenAnswer((_) async {});
    when(() => resolver.matching(42, 'abc', source: null))
        .thenAnswer((_) async => [book, other]);
    when(() => resolver.files).thenReturn(repository.files);
    when(() => resolver.changes).thenAnswer((_) => const Stream.empty());
    await GetIt.I.unregister<OfflineRepository>();
    GetIt.I.registerSingleton<OfflineRepository>(resolver);
    registerFallbackValue(book);
    final history = GetIt.I<HistoryRepository>();
    when(() => history.recordOfflineVisit(any()))
        .thenAnswer((_) => recording.future);
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settingsBloc,
        child: MaterialApp(
            navigatorKey: nav,
            navigatorObservers: [appRouteObserver],
            onGenerateRoute: AppRouter.generateRoute,
            home: const Scaffold(body: Text('Home')))));
    nav.currentState!
        .pushNamed('/reader', arguments: {'gid': 42, 'token': 'abc'});
    await tester.pumpAndSettle();
    expect(find.text('E-Hentai (EH)'), findsOneWidget);
    expect(find.text('ExHentai (EX)'), findsOneWidget);
    await tester.tap(find.text('ExHentai (EX)'));
    await tester.pump();
    final chosen = verify(() => history.recordOfflineVisit(captureAny()))
        .captured
        .single as OfflineBook;
    expect(chosen.source, GallerySource.ex);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    recording.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    verifyZeroInteractions(gallery);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'decoded explicit offline page keeps its position while neighbors arrive',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    when(() => settings.getReadingMode()).thenReturn(2);
    await tester.runAsync(() async {
      final first = book.pages.first;
      final bytes = await repository.files
          .read(first.relativePath!, first.bytes, first.sha256!);
      await repository.putIndex(
          book.id,
          5,
          List.generate(
              5,
              (i) =>
                  ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')),
          current: () => true);
      for (var i = 0; i < 5; i++) {
        final saved = await repository.files
            .write(book.id, i, Stream.value(bytes), current: () => true);
        await repository.savePage(book.id, i, saved, current: () => true);
      }
      book = (await repository.get(book.id))!;
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(
              home: ReaderScreen(
                  gid: 42, token: 'abc', initialPage: 3, offlineBook: book))));
    });
    final target = find.byWidgetPredicate((w) =>
        w is ReaderPageImage &&
        w.image is OfflineImageProvider &&
        (w.image as OfflineImageProvider).page.pageIndex == 3);
    final positions = <double>[];
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 25));
      if (target.evaluate().isNotEmpty &&
          find
              .descendant(of: target, matching: find.byType(RawImage))
              .evaluate()
              .isNotEmpty) {
        positions.add(tester.getTopLeft(target).dy);
      }
    }
    await settleOffline(tester);
    expect(positions, isNotEmpty);
    expect(positions.first, closeTo(0, 1));
    for (final y in positions) expect(y, closeTo(positions.first, 1));
    expect(tester.element(target).read<ReaderBloc>().state.currentPage, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
      'prepared entry read is single use and rejects a different page revision',
      () async {
    final files = FileSource();
    final page = book.pages.first;
    final bytes = await repository.files
        .read(page.relativePath!, page.bytes, page.sha256!);
    when(() => files.read(any(), any(), any())).thenAnswer((_) async => bytes);
    final prepared = OfflineEntryRead(files, page);
    expect(await prepared.take(page), bytes);
    verify(() => files.read(page.relativePath!, page.bytes, page.sha256!))
        .called(1);
    expect(await prepared.take(page), bytes);
    verify(() => files.read(page.relativePath!, page.bytes, page.sha256!))
        .called(1);
    final another = OfflineEntryRead(files, page);
    final changed = page.copyWith(bytes: page.bytes + 1);
    expect(another.matches(changed), isFalse);
    await another.take(changed);
    verify(() => files.read(page.relativePath!, changed.bytes, page.sha256!))
        .called(1);
    another.dispose();
  });

  test('cancelled queued image never reads or publishes a late resource',
      () async {
    final files = FileSource();
    final gate = Completer<void>();
    var current = true;
    var resources = 0;
    var failed = 0;
    final done = Completer<Object>();
    final provider = OfflineImageProvider(files, book.pages.first,
        beforeLoad: () => gate.future,
        isCurrent: () => current,
        onResource: (_) => resources++,
        onLoadError: () => failed++);
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
        (_, __) => fail('Cancelled image displayed'),
        onError: (Object error, StackTrace? stack) => done.complete(error));
    stream.addListener(listener);
    current = false;
    gate.complete();
    final error = await done.future.timeout(const Duration(seconds: 3));
    expect(error, isA<OfflineFailure>());
    expect((error as OfflineFailure).code, 'cancelled');
    expect(resources, 0);
    expect(failed, 1);
    verifyZeroInteractions(files);
    stream.removeListener(listener);
  });

  test(
      'damaged content is rejected by background read and does not publish resource',
      () async {
    final page = book.pages.first;
    final target = await repository.files.file(page.relativePath!);
    final bytes = await target.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await target.writeAsBytes(bytes, flush: true);
    await expectLater(
        repository.files.read(page.relativePath!, page.bytes, page.sha256!),
        throwsA(isA<OfflineFailure>()
            .having((e) => e.code, 'code', 'damaged_file')));
  });

  testWidgets(
      'offline animated GIF keeps advancing after first-frame notification',
      (tester) async {
    late OfflinePage page;
    await tester.runAsync(() async {
      final bytes = base64Decode(
          'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7');
      final file = await repository.files
          .write(book.id, 10, Stream.value(bytes), current: () => true);
      page = OfflinePage(
          bookId: book.id,
          pageIndex: 10,
          pageToken: 'gif',
          relativePath: file.relativePath,
          format: file.format,
          bytes: file.bytes,
          sha256: file.digest,
          status: 'completed');
    });
    var frames = 0;
    var firstFrames = 0;
    final errors = <Object>[];
    final stream = OfflineImageProvider(repository.files, page,
        onImageReady: () => firstFrames++).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((image, _) {
      frames++;
      image.dispose();
    }, onError: (Object error, StackTrace? stack) => errors.add(error));
    stream.addListener(listener);
    for (var i = 0; i < 40 && frames < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(errors, isEmpty);
    expect(frames, greaterThanOrEqualTo(2));
    expect(firstFrames, 1);
    stream.removeListener(listener);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('local provider decodes a durable page independently of the network',
      () async {
    final done = Completer<ImageInfo>();
    final provider = OfflineImageProvider(repository.files, book.pages.first);
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => done.complete(info),
        onError: (Object e, StackTrace? st) => done.completeError(e, st));
    stream.addListener(listener);
    try {
      final image = await done.future.timeout(const Duration(seconds: 3));
      expect(image.image.width, 2);
      image.dispose();
    } finally {
      stream.removeListener(listener);
      PaintingBinding.instance.imageCache.clear();
    }
  });
  testWidgets(
      'explicit missing offline page stays local and exposes repair action',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(
              home: ReaderScreen(
                  gid: 42, token: 'abc', initialPage: 1, offlineBook: book))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleOffline(tester);
    expect(find.text('Not cached yet'), findsOneWidget);
    await settleOffline(tester);
    await tester.tap(find.text('Page actions'));
    await settleOffline(tester);
    expect(find.text('Read again'), findsOneWidget);
    expect(find.text('Repair cache (online)'), findsOneWidget);
    verifyZeroInteractions(gallery);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  });
}
