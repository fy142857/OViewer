import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/router/route_observer.dart';
import 'package:oviewer/core/router/app_router.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'package:oviewer/core/storage/reader_index_cache.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/reading_progress.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/reader/reader_screen.dart';

class MockGallery extends Mock implements GalleryRepository {}

class MockHistory extends Mock implements HistoryRepository {}

class MockSettings extends Mock implements SettingsRepository {}

class MockSettingsBloc extends Mock implements SettingsBloc {}

class MockCookies extends Mock implements CookieManager {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockGallery gallery;
  late MockSettingsBloc settingsBloc;
  late List<Completer<GalleryImage>> pending;
  late List<CancelToken> tokens;
  late List<String> systemModes;

  setUpAll(() => registerFallbackValue(CancelToken()));

  setUp(() {
    gallery = MockGallery();
    when(() => gallery.readerIndexCache).thenReturn(ReaderIndexCache());
    final history = MockHistory();
    final settings = MockSettings();
    settingsBloc = MockSettingsBloc();
    pending = [];
    tokens = [];
    systemModes = [];
    when(() => settingsBloc.state)
        .thenReturn(const SettingsState(locale: 'en'));
    when(() => settingsBloc.stream).thenAnswer((_) => const Stream.empty());
    when(() => settings.getReadingMode()).thenReturn(0);
    when(() => history.getProgress(any())).thenAnswer((_) async => null);
    when(() => history.updateProgress(any(), any(), any()))
        .thenAnswer((_) async {});
    when(() => gallery.fetchReaderIndexPage(42, 'token',
            cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => ReaderIndexPage(
                totalPages: 1,
                indexPage: 0,
                indexPageCount: 1,
                pageSize: 1,
                thumbnails: {
                  0: const ThumbnailInfo(
                      pageToken: 'page', pageIndex: 0, thumbUrl: '')
                }));
    when(() => gallery.fetchImage('page', 42, 0,
        cancelToken: any(named: 'cancelToken'))).thenAnswer((call) {
      final result = Completer<GalleryImage>();
      pending.add(result);
      tokens.add(call.namedArguments[#cancelToken] as CancelToken);
      return result.future;
    });
    GetIt.I.registerSingleton<GalleryRepository>(gallery);
    GetIt.I.registerSingleton<HistoryRepository>(history);
    GetIt.I.registerSingleton<SettingsRepository>(settings);
    GetIt.I.registerSingleton<CookieManager>(MockCookies());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        systemModes.add(call.arguments as String);
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await GetIt.I.reset();
  });

  void stubTwentyPages() {
    when(() => GetIt.I<SettingsRepository>().getReadingMode()).thenReturn(2);
    when(() => GetIt.I<HistoryRepository>().getProgress(42)).thenAnswer(
        (_) async => ReadingProgress(
            gid: 42,
            lastReadPage: 12,
            totalPages: 20,
            lastReadAt: DateTime(2026)));
    when(() =>
        gallery.fetchReaderIndexPage(42, 'token',
            cancelToken: any(named: 'cancelToken'))).thenAnswer((_) async =>
        ReaderIndexPage(
            totalPages: 20,
            indexPage: 0,
            indexPageCount: 1,
            pageSize: 20,
            thumbnails: {
              for (var i = 0; i < 20; i++)
                i: ThumbnailInfo(pageToken: 'page', pageIndex: i, thumbUrl: '')
            }));
    for (var page = 0; page < 20; page++) {
      when(() => gallery.fetchImage('page', 42, page,
          cancelToken: any(named: 'cancelToken'))).thenAnswer((call) {
        final result = Completer<GalleryImage>();
        pending.add(result);
        tokens.add(call.namedArguments[#cancelToken] as CancelToken);
        return result.future;
      });
    }
  }

  testWidgets(
      'vertical preview selection ignores inherited stored scroll position',
      (tester) async {
    stubTwentyPages();
    final bucket = PageStorageBucket();
    var seeded = false;
    try {
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(
              home: PageStorage(
                  bucket: bucket,
                  child: KeyedSubtree(
                      key: const PageStorageKey('reader'),
                      child: Builder(builder: (context) {
                        if (!seeded) {
                          seeded = true;
                          bucket.writeState(
                              context,
                              const ItemPosition(
                                  index: 12,
                                  itemLeadingEdge: 0,
                                  itemTrailingEdge: 0.8));
                        }
                        return const ReaderScreen(
                            gid: 42, token: 'token', initialPage: 5);
                      }))))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final list = tester.widget<ScrollablePositionedList>(
          find.byType(ScrollablePositionedList));
      expect(
          list.itemPositionsNotifier!.itemPositions.value
              .any((p) => p.index == 5 && p.itemLeadingEdge.abs() < 0.01),
          isTrue);
      expect(
          tester
              .element(find.byType(ScrollablePositionedList))
              .read<ReaderBloc>()
              .state
              .currentPage,
          5);
      verifyNever(() => GetIt.I<HistoryRepository>().getProgress(42));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final request in pending) {
        if (!request.isCompleted) {
          request.completeError(StateError('cancelled'));
        }
      }
      await tester.pump();
    }
  });

  testWidgets(
      'named reader route opens selected previews and only resumes when no page is provided',
      (tester) async {
    stubTwentyPages();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settingsBloc,
        child: MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [appRouteObserver],
            onGenerateRoute: AppRouter.generateRoute,
            home: Scaffold(
                body: Builder(
                    builder: (context) => Column(children: [
                          for (final page in [null, 0, 5])
                            TextButton(
                                onPressed: () => Navigator.pushNamed(
                                        context, AppRouter.reader, arguments: {
                                      'gid': 42,
                                      'token': 'token',
                                      if (page != null) 'initialPage': page
                                    }),
                                child: Text(page == null
                                    ? 'Continue'
                                    : 'Preview $page')),
                        ]))))));
    for (final selected in [null, 0, 5]) {
      await tester
          .tap(find.text(selected == null ? 'Continue' : 'Preview $selected'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final expected = selected ?? 12;
      final list = tester.widget<ScrollablePositionedList>(
          find.byType(ScrollablePositionedList));
      expect(
          list.itemPositionsNotifier!.itemPositions.value.any(
              (p) => p.index == expected && p.itemLeadingEdge.abs() < 0.01),
          isTrue);
      expect(
          tester
              .element(find.byType(ScrollablePositionedList))
              .read<ReaderBloc>()
              .state
              .currentPage,
          expected);
      navigator.currentState!.pop();
      for (final request in pending) {
        if (!request.isCompleted) {
          request.completeError(StateError('cancelled'));
        }
      }
      await tester.pumpAndSettle();
    }
    verify(() => GetIt.I<HistoryRepository>().getProgress(42)).called(1);
  });

  for (final mode in [0, 1, 2]) {
    for (final selected in [0, 5]) {
      testWidgets(
          'mode $mode: changed explicit preview page $selected overrides previous reading position',
          (tester) async {
        when(() => GetIt.I<SettingsRepository>().getReadingMode())
            .thenReturn(mode);
        when(() => GetIt.I<HistoryRepository>().getProgress(42)).thenAnswer(
            (_) async => ReadingProgress(
                gid: 42,
                lastReadPage: 12,
                totalPages: 20,
                lastReadAt: DateTime(2026)));
        when(() => gallery.fetchReaderIndexPage(42, 'token',
                cancelToken: any(named: 'cancelToken')))
            .thenAnswer((_) async => ReaderIndexPage(
                    totalPages: 20,
                    indexPage: 0,
                    indexPageCount: 1,
                    pageSize: 20,
                    thumbnails: {
                      for (var i = 0; i < 20; i++)
                        i: ThumbnailInfo(
                            pageToken: 'page', pageIndex: i, thumbUrl: '')
                    }));
        for (var page = 0; page < 20; page++) {
          when(() => gallery.fetchImage('page', 42, page,
              cancelToken: any(named: 'cancelToken'))).thenAnswer((call) {
            final result = Completer<GalleryImage>();
            pending.add(result);
            tokens.add(call.namedArguments[#cancelToken] as CancelToken);
            return result.future;
          });
        }
        Widget app(int? initialPage) => BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: MaterialApp(
                home: ReaderScreen(
                    gid: 42, token: 'token', initialPage: initialPage)));
        Finder content() => find
            .byType(mode == 2 ? ScrollablePositionedList : PhotoViewGallery);
        Future<void> settleLayout() async {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
        }

        try {
          await tester.pumpWidget(app(null));
          await settleLayout();
          expect(tester.element(content()).read<ReaderBloc>().state.currentPage,
              12);
          final previousTokens = List<CancelToken>.of(tokens);
          await tester.pumpWidget(app(selected));
          await settleLayout();
          expect(tester.element(content()).read<ReaderBloc>().state.currentPage,
              selected);
          if (mode != 2) {
            final view = tester.widget<PhotoViewGallery>(content());
            expect(view.pageController!.page!.round(), selected);
          } else {
            final view = tester.widget<ScrollablePositionedList>(content());
            final positions = view.itemPositionsNotifier!.itemPositions.value;
            expect(
                positions.any((p) =>
                    p.index == selected && p.itemLeadingEdge.abs() < 0.01),
                isTrue);
          }
          expect(previousTokens.every((t) => t.isCancelled), isTrue);
          verify(() => GetIt.I<HistoryRepository>().getProgress(42)).called(1);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          for (final request in pending) {
            if (!request.isCompleted) {
              request.completeError(StateError('cancelled'));
            }
          }
          await tester.pump();
        }
      });
    }
  }

  testWidgets(
      'sparse indices preserve total pages and slider drag requests only its final position',
      (tester) async {
    ReaderIndexPage part(int page) => ReaderIndexPage(
            totalPages: 105,
            indexPage: page,
            indexPageCount: 6,
            pageSize: 20,
            thumbnails: {
              for (var i = page * 20; i < ((page + 1) * 20).clamp(0, 105); i++)
                i: ThumbnailInfo(pageToken: 'page', pageIndex: i, thumbUrl: '')
            });
    final slow = Completer<ReaderIndexPage>();
    final indexCalls = <int>[];
    for (var page = 0; page < 6; page++) {
      when(() => gallery.fetchReaderIndexPage(42, 'token',
          page: page, cancelToken: any(named: 'cancelToken'))).thenAnswer((_) {
        indexCalls.add(page);
        return page == 5 ? slow.future : Future.value(part(page));
      });
    }
    for (var page = 0; page < 20; page++) {
      when(() => gallery.fetchImage('page', 42, page,
          cancelToken: any(named: 'cancelToken'))).thenAnswer((call) {
        final result = Completer<GalleryImage>();
        pending.add(result);
        tokens.add(call.namedArguments[#cancelToken] as CancelToken);
        return result.future;
      });
    }
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settingsBloc,
        child: MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [appRouteObserver],
            home: const Scaffold(body: Text('Home')))));
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) =>
            const ReaderScreen(gid: 42, token: 'token', initialPage: 101)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final slider = tester.widget<Slider>(find.byType(Slider));
    final bloc = tester.element(find.byType(Slider)).read<ReaderBloc>();
    expect(slider.max, 104);
    expect(slider.value, 101);
    expect(bloc.state.totalPages, 105);
    expect(bloc.state.thumbnails.containsKey(101), isFalse);
    slider.onChanged!(50);
    await tester.pump();
    slider.onChanged!(10);
    await tester.pump();
    expect(bloc.state.currentPage, 101);
    expect(indexCalls.contains(2), isFalse);
    slider.onChangeEnd!(10);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(bloc.state.currentPage, 10);
    expect(indexCalls.contains(2), isFalse);
    navigator.currentState!.pop();
    slow.completeError(StateError('cancelled'));
    for (final request in pending) {
      request.completeError(StateError('cancelled'));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final mode in [0, 1, 2]) {
    testWidgets(
        'mode $mode: single tap shows system bars; pop cancels before animation and reopening reloads',
        (tester) async {
      when(() => GetIt.I<SettingsRepository>().getReadingMode())
          .thenReturn(mode);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settingsBloc,
        child: MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [appRouteObserver],
            home: const Scaffold(body: Text('Home'))),
      ));
      void open() => navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const ReaderScreen(gid: 42, token: 'token')));
      open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(tokens, hasLength(1));
      expect(systemModes.last, 'SystemUiMode.immersiveSticky');

      await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(systemModes.last, 'SystemUiMode.edgeToEdge');
      await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(systemModes.last, 'SystemUiMode.immersiveSticky');

      navigator.currentState!.pop();
      expect(tokens.first.isCancelled, isTrue);
      // The route is still present while its reverse transition runs.
      expect(find.byType(ReaderScreen), findsOneWidget);
      pending.first.completeError(StateError('cancelled'));
      open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(tokens, hasLength(2));
      expect(tokens.last, isNot(same(tokens.first)));
      expect(tokens.last.isCancelled, isFalse);
      expect(systemModes.last, 'SystemUiMode.immersiveSticky');
      navigator.currentState!.pop();
      pending.last.completeError(StateError('cancelled'));
      await tester.pumpAndSettle();
      expect(systemModes.last, 'SystemUiMode.edgeToEdge');
    });
  }
}
