import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/offline_image_provider.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/offline_files.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/reader/reader_screen.dart';
import 'offline_storage_test.dart' show sqliteForTests;

class Gallery extends Mock implements GalleryRepository {}

class History extends Mock implements HistoryRepository {}

class Settings extends Mock implements SettingsRepository {}

class SettingsBlocMock extends Mock implements SettingsBloc {}

class Cookies extends Mock implements CookieManager {}

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
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
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
    await tester.pump();
    expect(find.text('Not cached yet'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Page actions'));
    await tester.pumpAndSettle();
    expect(find.text('Read again'), findsOneWidget);
    expect(find.text('Repair cache (online)'), findsOneWidget);
    verifyZeroInteractions(gallery);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  });
}
