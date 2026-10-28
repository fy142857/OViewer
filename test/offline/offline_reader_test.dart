import 'dart:ui' as ui;
import 'package:photo_view/photo_view_gallery.dart';
import 'package:oviewer/widgets/reader_page_menu.dart';
import 'package:oviewer/models/reader_page_layout.dart';
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
    when(() => settings.getReaderPreloadCount()).thenReturn(1);
    when(() => settings.getReaderPageLayout())
        .thenReturn(ReaderPageLayout.single);
    when(() => settings.getReaderSpreadAlignment())
        .thenReturn(ReaderSpreadAlignment.width);
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
    when(() => settings.getReaderPreloadCount()).thenReturn(1);
    when(() => settings.getReaderPageLayout())
        .thenReturn(ReaderPageLayout.single);
    when(() => settings.getReaderSpreadAlignment())
        .thenReturn(ReaderSpreadAlignment.width);
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
      when(() => settings.getReaderPreloadCount()).thenReturn(1);
      when(() => settings.getReaderPageLayout())
          .thenReturn(ReaderPageLayout.single);
      when(() => settings.getReaderSpreadAlignment())
          .thenReturn(ReaderSpreadAlignment.width);
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
  for (final mode in [0, 1, 2]) {
    testWidgets(
        'double-page mode $mode keeps explicit focus, gestures and local resources',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final preferences = StreamController<SettingsState>.broadcast();
      addTearDown(preferences.close);
      when(() => settingsBloc.stream).thenAnswer((_) => preferences.stream);
      when(() => settingsBloc.state).thenReturn(SettingsState(
          locale: 'en',
          readingMode: mode,
          pageLayout: ReaderPageLayout.doublePage));
      when(() => settings.getReadingMode()).thenReturn(mode);
      when(() => settings.getReaderPreloadCount()).thenReturn(1);
      when(() => settings.getReaderPageLayout())
          .thenReturn(ReaderPageLayout.doublePage);
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
                    gid: 42,
                    token: 'abc',
                    initialPage: 1,
                    offlineBook: book))));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settleOffline(tester);
      final content =
          find.byType(mode == 2 ? ScrollablePositionedList : PhotoViewGallery);
      final bloc = tester.element(content).read<ReaderBloc>();
      expect(bloc.state.currentPage, 1);
      final first = find.byKey(const ValueKey('reader-page-0'));
      final second = find.byKey(const ValueKey('reader-page-1'));
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      expect(
          tester.getRect(first).left < tester.getRect(second).left, mode != 1);
      // Missing target page must release entry priority so its sibling can decode.
      expect(
          tester
              .widgetList<RawImage>(
                  find.descendant(of: first, matching: find.byType(RawImage)))
              .any((image) => image.image != null),
          isTrue);
      for (final page in [0, 1]) {
        await tester.longPress(find.byKey(ValueKey('reader-page-$page')));
        await tester.pumpAndSettle();
        expect(tester.widget<ReaderPageMenu>(find.byType(ReaderPageMenu)).page,
            page);
        expect(find.byKey(const ValueKey('save-page')),
            page == 0 ? findsOneWidget : findsNothing);
        await tester.tap(find.text('Cancel'));
        await settleOffline(tester);
      }
      // A two-finger gesture scales the pair together, not a single cell.
      final beforeZoom = tester.getRect(first).width;
      final center = tester.getRect(content).center;
      final finger1 =
          await tester.startGesture(center - const Offset(40, 0), pointer: 1);
      final finger2 =
          await tester.startGesture(center + const Offset(40, 0), pointer: 2);
      await tester.pump();
      await finger1.moveTo(center - const Offset(55, 0));
      await finger2.moveTo(center + const Offset(55, 0));
      await tester.pump();
      await finger1.moveTo(center - const Offset(100, 0));
      await finger2.moveTo(center + const Offset(100, 0));
      await tester.pump();
      await finger1.up();
      await finger2.up();
      await settleOffline(tester);
      expect(tester.getRect(first).width, greaterThan(beforeZoom * 1.1));
      expect(tester.getRect(first).width,
          closeTo(tester.getRect(second).width, 0.1));
      expect(bloc.state.currentPage, 1);
      await tester.binding.setSurfaceSize(const Size(800, 360));
      await settleOffline(tester);
      expect(bloc.state.currentPage, 1);
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      // A mode change resets viewport storage but preserves the exact second page.
      preferences.add(SettingsState(
          locale: 'en',
          readingMode: mode,
          pageLayout: ReaderPageLayout.single));
      await settleOffline(tester);
      expect(bloc.state.currentPage, 1);
      preferences.add(SettingsState(
          locale: 'en',
          readingMode: mode,
          pageLayout: ReaderPageLayout.doublePage));
      await settleOffline(tester);
      expect(bloc.state.currentPage, 1);
      // Natural navigation moves to a new spread using its first original page.
      await tester.drag(
          content,
          mode == 2
              ? const Offset(0, -300)
              : Offset(mode == 1 ? 600 : -600, 0));
      await settleOffline(tester);
      expect(bloc.state.currentPage, greaterThanOrEqualTo(2));
      expect(bloc.state.currentPage.isEven, isTrue);
      // Slide within original page indices to the odd tail page.
      bloc.add(ToggleReaderUI());
      await settleOffline(tester);
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(4);
      await settleOffline(tester);
      expect(bloc.state.currentPage, 4);
      expect(find.byKey(const ValueKey('reader-page-4')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('reader-page-4'))).width,
          800);
      expect(tester.takeException(), isNull);
      verifyZeroInteractions(gallery);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
    });
  }

  testWidgets(
      'landscape height fit centres unequal pages and supports single-page reading',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 360);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    when(() => settings.getReadingMode()).thenReturn(2);
    when(() => settings.getReaderPreloadCount()).thenReturn(1);
    when(() => settings.getReaderPageLayout())
        .thenReturn(ReaderPageLayout.doublePage);
    await tester.runAsync(() async {
      for (final pair in [(0, 10, 20), (1, 30, 10)]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(Colors.orange, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(pair.$2, pair.$3);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        picture.dispose();
        final saved = await repository.files
            .write(book.id, pair.$1, Stream.value(png), current: () => true);
        await repository.savePage(book.id, pair.$1, saved, current: () => true);
      }
      book = (await repository.get(book.id))!;
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(
              home: ReaderScreen(
                  gid: 42, token: 'abc', initialPage: 1, offlineBook: book))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleOffline(tester);
    final first = find.byKey(const ValueKey('reader-page-0'));
    final second = find.byKey(const ValueKey('reader-page-1'));
    expect(tester.getSize(first).width, 400);
    expect(tester.getSize(second).width, 400);
    expect(tester.getSize(first).height,
        greaterThan(tester.getSize(second).height));
    expect(tester.getRect(first).center.dy,
        closeTo(tester.getRect(second).center.dy, 0.1));
    final bloc = tester
        .element(find.byType(ScrollablePositionedList))
        .read<ReaderBloc>();
    bloc.add(const ChangeReaderPreferences(2, ReaderPageLayout.doublePage,
        alignment: ReaderSpreadAlignment.height));
    await settleOffline(tester);
    expect(tester.getSize(first).height, closeTo(360, 0.1));
    expect(tester.getSize(second).height, closeTo(60, 0.1));
    expect(tester.getSize(first).width,
        closeTo(tester.getSize(second).width, 0.1));
    expect(tester.getRect(first).center.dy,
        closeTo(tester.getRect(second).center.dy, 0.1));
    expect(tester.getRect(first).top, closeTo(0, 0.1));
    expect(bloc.state.currentPage, 1);
    bloc.add(const ChangeReaderPreferences(2, ReaderPageLayout.doublePage));
    await settleOffline(tester);
    expect(tester.getSize(first).width, 400);
    expect(bloc.state.currentPage, 1);
    bloc.add(const ChangeReaderPreferences(2, ReaderPageLayout.single,
        alignment: ReaderSpreadAlignment.height));
    await settleOffline(tester);
    bloc.add(ToggleReaderUI());
    await settleOffline(tester);
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(0);
    await settleOffline(tester);
    expect(tester.getSize(first).height, closeTo(360, 0.1));
    expect(tester.getSize(first).width, closeTo(180, 0.1));
    tester.view.physicalSize = const Size(360, 800);
    await settleOffline(tester);
    expect(bloc.state.currentPage, 0);
    tester.view.physicalSize = const Size(800, 360);
    await settleOffline(tester);
    for (final mode in [0, 1]) {
      bloc.add(ChangeReaderPreferences(mode, ReaderPageLayout.doublePage));
      await settleOffline(tester);
      final a = tester.getRect(first), b = tester.getRect(second);
      expect(mode == 0 ? b.left - a.right : a.left - b.right, closeTo(4, 0.1));
      expect(a.center.dy, closeTo(b.center.dy, 0.1));
      expect(a.expandToInclude(b).center.dx, closeTo(400, 0.1));
      expect(a.height, closeTo(360, 0.1));
      expect(a.left, greaterThanOrEqualTo(0));
      expect(b.right, lessThanOrEqualTo(800));
      expect(bloc.state.currentPage, 0);
    }
    // Every direction/orientation/preference keeps the two page centres aligned.
    for (final size in [const Size(360, 800), const Size(800, 360)]) {
      tester.view.physicalSize = size;
      await settleOffline(tester);
      for (final mode in [0, 1, 2]) {
        for (final alignment in ReaderSpreadAlignment.values) {
          bloc.add(ChangeReaderPreferences(mode, ReaderPageLayout.doublePage,
              alignment: alignment));
          await settleOffline(tester);
          expect(tester.getRect(first).center.dy,
              closeTo(tester.getRect(second).center.dy, 0.1),
              reason: '$size direction=$mode alignment=$alignment');
          expect(bloc.state.currentPage, 0);
        }
      }
    }
    expect(tester.takeException(), isNull);
    verifyZeroInteractions(gallery);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  });

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
    when(() => settings.getReaderPreloadCount()).thenReturn(1);
    when(() => settings.getReaderPageLayout())
        .thenReturn(ReaderPageLayout.single);
    when(() => settings.getReaderSpreadAlignment())
        .thenReturn(ReaderSpreadAlignment.width);
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
          verificationVersion: 0,
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
