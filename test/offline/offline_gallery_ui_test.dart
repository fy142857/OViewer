import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/download/download_bloc.dart';
import 'package:oviewer/blocs/download/download_event.dart';
import 'package:oviewer/blocs/download/download_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/models/gallery_preview.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/screens/download/download_screen.dart';
import 'package:oviewer/widgets/gallery_status_icons.dart';

class Downloads extends Mock implements DownloadBloc {}

class Settings extends Mock implements SettingsBloc {}

OfflineBook book(
        {String source = 'eh',
        String status = 'completed',
        int pages = 2,
        String token = 'abc'}) =>
    OfflineBook(
        OfflineGallery(
            id: 'book-$source',
            source: source,
            gid: 42,
            token: token,
            title: 'Offline gallery',
            totalPages: 2,
            status: status,
            createdAt: DateTime(2026),
            lastReadPage: 0,
            indexReady: true,
            everCompleted: status == 'completed'),
        List.generate(
            pages,
            (i) => OfflinePage(
                bookId: 'book-$source',
                pageIndex: i,
                pageToken: 'page-$i',
                bytes: 100,
                status: 'completed')));

void main() {
  setUpAll(() => registerFallbackValue(LoadDownloads()));
  late Downloads downloads;
  late Settings settings;
  late DownloadState state;
  late SettingsState settingsState;
  late StreamController<DownloadState> changes;
  late StreamController<SettingsState> settingsChanges;
  setUp(() {
    downloads = Downloads();
    settings = Settings();
    state = DownloadState(status: DownloadListStatus.loaded, tasks: [book()]);
    settingsState = const SettingsState(locale: 'en');
    changes = StreamController.broadcast();
    settingsChanges = StreamController.broadcast();
    when(() => downloads.state).thenAnswer((_) => state);
    when(() => downloads.stream).thenAnswer((_) => changes.stream);
    when(() => settings.state).thenAnswer((_) => settingsState);
    when(() => settings.stream).thenAnswer((_) => settingsChanges.stream);
  });
  tearDown(() async {
    await changes.close();
    await settingsChanges.close();
  });
  Future<void> boot(WidgetTester tester, Widget home,
      {RouteFactory? route, ThemeMode themeMode = ThemeMode.light}) async {
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<DownloadBloc>.value(value: downloads),
          BlocProvider<SettingsBloc>.value(value: settings),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeMode,
          home: home,
          onGenerateRoute: route,
        )));
    await tester.pumpAndSettle();
  }

  for (final decorated in [false, true]) {
    testWidgets(
        'cache marker tracks completion, token, source and deletion (grid=$decorated)',
        (tester) async {
      final gallery = GalleryPreview(
          gid: 42,
          token: 'abc',
          title: 'Gallery',
          thumbUrl: '',
          category: 'Manga',
          rating: 4,
          uploader: '',
          fileCount: 2,
          postedAt: DateTime(2026),
          isFavorited: true);
      state = DownloadState(
          status: DownloadListStatus.loaded,
          tasks: [book(status: 'downloading', pages: 1)]);
      await boot(
          tester,
          Scaffold(
              body:
                  GalleryStatusIcons(gallery: gallery, decorated: decorated)));
      expect(find.byIcon(Icons.offline_pin), findsNothing);
      state = DownloadState(status: DownloadListStatus.loaded, tasks: [book()]);
      changes.add(state);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cached offline'), findsOneWidget);
      expect(tester.getCenter(find.byIcon(Icons.offline_pin)).dx,
          lessThan(tester.getCenter(find.byIcon(Icons.favorite)).dx));
      settingsState = settingsState.copyWith(useExHentai: true);
      settingsChanges.add(settingsState);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.offline_pin), findsNothing);
      state = DownloadState(
          status: DownloadListStatus.loaded,
          tasks: [book(source: 'ex', token: 'different')]);
      changes.add(state);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.offline_pin), findsNothing);
      state = DownloadState(
          status: DownloadListStatus.loaded, tasks: [book(source: 'ex')]);
      changes.add(state);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.offline_pin), findsOneWidget);
      state = const DownloadState(status: DownloadListStatus.loaded);
      changes.add(state);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.offline_pin), findsNothing);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });
  }

  for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
        'whole download card opens local reader, delete stays inside card and does not navigate ($themeMode)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      RouteSettings? opened;
      await boot(tester, const DownloadScreen(), themeMode: themeMode,
          route: (route) {
        opened = route;
        return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Reader')));
      });
      expect(find.text('Read offline'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      final card = tester.getRect(find
          .descendant(of: find.byType(Card), matching: find.byType(InkWell))
          .first);
      // Material 3 places Tooltip around the icon, inside the button padding.
      // Check the whole button's bounds, which are positioned by the card.
      final deleteButton = find.ancestor(
          of: find.byTooltip('Delete'), matching: find.byType(IconButton));
      expect(deleteButton, findsOneWidget);
      final delete = tester.getRect(deleteButton);
      expect(card.bottom - delete.bottom, closeTo(4, 0.1));
      expect(card.right - delete.right, closeTo(4, 0.1));
      expect(card.height, lessThan(120));
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(opened, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(card.right - 8, card.top + 12));
      await tester.pumpAndSettle();
      expect(opened!.name, '/reader');
      expect((opened!.arguments as Map)['offlineId'], 'book-eh');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'partial download remains readable and pause action does not open reader',
      (tester) async {
    state = DownloadState(
        status: DownloadListStatus.loaded,
        tasks: [book(status: 'downloading', pages: 1)]);
    RouteSettings? opened;
    await boot(tester, const DownloadScreen(), route: (route) {
      opened = route;
      return MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Reader')));
    });
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    verify(() => downloads.add(any(that: isA<PauseDownload>()))).called(1);
    expect(opened, isNull);
    await tester.tap(find.text('Offline gallery'));
    await tester.pumpAndSettle();
    expect((opened!.arguments as Map)['offlineId'], 'book-eh');
  });
  for (final entry in [
    book(pages: 0, status: 'paused'),
    book(source: '', status: 'sourceRequired')
  ]) {
    testWidgets(
        'unreadable task cannot accidentally open online reader (${entry.status})',
        (tester) async {
      state = DownloadState(status: DownloadListStatus.loaded, tasks: [entry]);
      RouteSettings? opened;
      await boot(tester, const DownloadScreen(), route: (route) {
        opened = route;
        return MaterialPageRoute(builder: (_) => const SizedBox());
      });
      await tester.tap(find.text('Offline gallery'));
      await tester.pumpAndSettle();
      expect(opened, isNull);
    });
  }
}
