import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:oviewer/main.dart' as application;
import 'offline_validation.dart' show FixtureDioClient;
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/history_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/blocs/history/history_bloc.dart';
import 'package:oviewer/blocs/history/history_event.dart';
import 'package:oviewer/widgets/thumbnail_grid.dart';
import 'package:oviewer/screens/home/home_screen.dart';
import 'package:oviewer/screens/history/history_screen.dart';
import 'package:oviewer/screens/download/download_screen.dart';
import 'package:oviewer/screens/thumbnail_preview/thumbnail_preview_screen.dart';

List<Element> elements([Element? root]) {
  final result = <Element>[];
  void visit(Element e) {
    result.add(e);
    e.visitChildren(visit);
  }

  visit(root ?? WidgetsBinding.instance.rootElement!);
  return result;
}

Element screen(Type type) =>
    elements().lastWhere((e) => e.widget.runtimeType == type);
Future<void> settle([int ms = 600]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
// Local-only Profile acceptance harness. Never use the production package ID.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError(
        'Reader benchmark requires the isolated offline_test package');
  }
  await application.startOfflineValidation((c, d) => FixtureDioClient(c, d));
  await settle(1800);
  final repo = GetIt.I<OfflineRepository>();
  const key = OfflineKey(GallerySource.eh, 1001, 'abc123');
  var book = await repo.get(key.id);
  if (book?.complete != true) {
    book = await repo.create(key, 'Offline Fixture EH 1001', 12);
    await repo.putIndex(
        book.id,
        12,
        List.generate(
            12,
            (i) => ThumbnailInfo(
                pageToken: (i + 1).toRadixString(16).padLeft(8, '0'),
                pageIndex: i,
                thumbUrl: '')),
        current: () => true);
    final bytes = Uint8List(1200 * 1800 * 4);
    final random = Random(63);
    for (var i = 0; i < bytes.length; i += 4) {
      bytes[i] = random.nextInt(16) * 16;
      bytes[i + 1] = random.nextInt(16) * 16;
      bytes[i + 2] = random.nextInt(16) * 16;
      bytes[i + 3] = 255;
    }
    final image = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        bytes, 1200, 1800, ui.PixelFormat.rgba8888, image.complete);
    final decoded = await image.future;
    final png = (await decoded.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    decoded.dispose();
    for (var i = 0; i < 12; i++) {
      final saved = await repo.files
          .write(book.id, i, Stream.value(png), current: () => true);
      await repo.savePage(book.id, i, saved, current: () => true);
    }
    await repo.setStatus(book.id, OfflineStatus.completed);
    book = (await repo.get(key.id))!;
  }
  await GetIt.I<HistoryRepository>().recordOfflineVisit(book!);
  final home = screen(HomeScreen);
  home.read<HistoryBloc>().add(LoadHistory());
  final nav = Navigator.of(home);
  const args = {'gid': 1001, 'token': 'abc123', 'source': GallerySource.eh};
  for (final mode
      in const String.fromEnvironment('BENCH_MODES', defaultValue: '0,1,2')
          .split(',')
          .map(int.parse)) {
    await GetIt.I<SettingsRepository>().setReadingMode(mode);
    for (final entry in const String.fromEnvironment('BENCH_ENTRIES',
            defaultValue:
                'download,detail,detail_thumb,preview,home_history,history')
        .split(',')) {
      nav.popUntil((r) => r.isFirst);
      await settle();
      if (entry == 'download') {
        unawaited(nav.pushNamed('/downloads'));
      }
      if (entry == 'detail' || entry == 'detail_thumb') {
        unawaited(nav.pushNamed('/gallery', arguments: args));
      }
      if (entry == 'preview') {
        unawaited(nav.pushNamed('/thumbnail_preview',
            arguments: {...args, 'fileCount': 12}));
      }
      if (entry == 'history') {
        unawaited(nav.pushNamed('/history'));
      }
      if (entry == 'home_history') {
        final tab =
            elements(home).map((e) => e.widget).whereType<TabBar>().first;
        tab.controller!.animateTo(2);
      }
      await settle(1400);
      for (var sample = 0;
          sample < const int.fromEnvironment('BENCH_SAMPLES', defaultValue: 10);
          sample++) {
        debugPrint(
            '[reader-bench] start mode=$mode entry=$entry sample=$sample');
        if (entry == 'download') {
          elements(screen(DownloadScreen))
              .map((e) => e.widget)
              .whereType<InkWell>()
              .firstWhere((w) => w.onTap != null)
              .onTap!();
        }
        if (entry == 'detail') {
          (elements()
                  .lastWhere(
                      (e) => e.widget.key == const ValueKey('read-gallery'))
                  .widget as FilledButton)
              .onPressed!();
        }
        if (entry == 'detail_thumb') {
          elements()
              .map((e) => e.widget)
              .whereType<ThumbnailGrid>()
              .last
              .onThumbnailTap!(0);
        }
        if (entry == 'preview') {
          elements(screen(ThumbnailPreviewScreen))
              .map((e) => e.widget)
              .whereType<GestureDetector>()
              .firstWhere((w) => w.onTap != null && w.child is Stack)
              .onTap!();
        }
        if (entry == 'home_history' || entry == 'history') {
          elements(screen(entry == 'history' ? HistoryScreen : HomeScreen))
              .map((e) => e.widget)
              .whereType<ListTile>()
              .firstWhere((w) =>
                  w.onTap != null &&
                  w.title is Text &&
                  ((w.title as Text).data ?? '').contains('Offline Fixture'))
              .onTap!();
        }
        await settle(1600);
        nav.pop();
        await settle(350);
      }
    }
  }
  debugPrint('[reader-bench] complete');
}
