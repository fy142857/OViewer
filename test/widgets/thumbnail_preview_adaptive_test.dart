import 'package:oviewer/widgets/thumbnail_grid.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/repositories/gallery_repository.dart';
import 'package:oviewer/screens/thumbnail_preview/thumbnail_preview_screen.dart';

class _Gallery extends Mock implements GalleryRepository {}

class _Settings extends Mock implements SettingsBloc {}

void main() {
  testWidgets(
      'full preview resizes, fills a wider viewport, retries failures and opens the original page',
      (tester) async {
    final directory = await tester
        .runAsync(() => Directory.systemTemp.createTemp('thumbnail-grid-'));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory!.path);
    await tester.runAsync(() async {
      EhImageCacheManager.initForTesting(Config('thumbnail-grid-test',
          repo: JsonCacheInfoRepository.withFile(
              File('${directory!.path}/cache.json'))));
      await EhImageCacheManager.instance.getFileFromCache('initialize');
    });
    final gallery = _Gallery();
    final settings = _Settings();
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    final requests = <int>[];
    ThumbnailResult batch(int page) =>
        ThumbnailResult(totalPages: 2, thumbnails: [
          for (var i = page * 24; i < (page + 1) * 24; i++)
            ThumbnailInfo(
                pageToken: 'p$i',
                pageIndex: i * 2,
                thumbUrl: 'https://example.test/$i',
                isSprite: true),
        ]);
    when(() => gallery.fetchThumbnails(42, 'token')).thenAnswer((_) async {
      requests.add(0);
      return batch(0);
    });
    var secondPageAttempts = 0;
    when(() => gallery.fetchThumbnails(42, 'token', page: 1))
        .thenAnswer((_) async {
      requests.add(1);
      if (++secondPageAttempts == 1) throw StateError('Connection interrupted');
      return batch(1);
    });
    GetIt.I.registerSingleton<GalleryRepository>(gallery);
    addTearDown(() async {
      await GetIt.I.reset();
      await EhImageCacheManager.instance.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null);
      expect(directory!.parent.absolute.path, Directory.systemTemp.absolute.path);
      await directory.delete(recursive: true);
    });
    await tester.binding.setSurfaceSize(const Size(360, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> pumpPreview() async {
      // The next-page indicator animates while more pages remain available.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Map<dynamic, dynamic>? opened;
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings,
        child: MaterialApp(
            home: const ThumbnailPreviewScreen(
                gid: 42, token: 'token', fileCount: 96),
            onGenerateRoute: (route) {
              expect(route.name, '/reader');
              opened = route.arguments as Map;
              return MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Reader opened')));
            })));
    await pumpPreview();
    expect(requests, [0]);
    expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        4);
    await tester.tap(find.text('7'));
    await pumpPreview();
    expect(opened!['initialPage'], 6);
    Navigator.of(tester.element(find.text('Reader opened'))).pop();
    await pumpPreview();
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await pumpPreview();
    expect(requests, [0, 1]);
    expect(find.text('95'), findsNothing);
    // A failed fill request remains retryable even when this batch cannot scroll.
    await tester.drag(find.byType(GridView), const Offset(0, -200));
    await pumpPreview();
    expect(requests, [0, 1, 1]);

    expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        12);
    expect(find.text('95'), findsOneWidget);
    await tester.tap(find.text('95'));
    await pumpPreview();
    expect(opened!['initialPage'], 94);
    expect(tester.takeException(), isNull);
    int? selectedIndex;
    await tester.binding.setSurfaceSize(const Size(360, 600));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ThumbnailGrid(
                        thumbnails: batch(0).thumbnails.take(5).toList(),
                        onThumbnailTap: (index) => selectedIndex = index))))));
    await pumpPreview();
    expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        4);
    expect(
        tester.getSize(find.byType(ClipRRect).first).width, closeTo(79, 0.01));
    await tester.tap(find.byType(ClipRRect).at(4));
    expect(selectedIndex, 4);
    await tester.binding.setSurfaceSize(const Size(840, 360));
    await pumpPreview();
    expect(
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        8);
    selectedIndex = null;
    await tester.tap(find.byType(ClipRRect).at(4));
    expect(selectedIndex, 4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
