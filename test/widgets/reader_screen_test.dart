import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/router/route_observer.dart';
import 'package:oviewer/models/gallery_detail.dart';
import 'package:oviewer/models/gallery_image.dart';
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
    when(() => gallery.fetchGalleryDetail(42, 'token',
            cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => GalleryDetail(
            gid: 42,
            token: 'token',
            title: 'Test',
            thumbUrl: '',
            category: 'Manga',
            uploader: '',
            postedAt: DateTime(2026),
            fileCount: 1,
            rating: 0));
    when(() => gallery.fetchThumbnails(42, 'token',
            cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => const ThumbnailResult(thumbnails: [
              ThumbnailInfo(pageToken: 'page', pageIndex: 0, thumbUrl: '')
            ], totalPages: 1));
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
