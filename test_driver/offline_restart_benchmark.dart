import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:oviewer/blocs/download/download_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/download/download_screen.dart';
import 'offline_resume_benchmark.dart'
    show ResumeBenchmarkNetwork, BenchmarkFiles, until;
import 'reader_entry_benchmark.dart' show elements;

// Launch once to seed, then genuinely kill/relaunch this isolated app for each
// sample. No directory response is needed after seeding; counters must stay zero.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError('Isolated offline_test package required');
  }
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('Restart validation')))));
  final base = await getApplicationSupportDirectory();
  final root = await Directory('${base.path}/restart-benchmark-v4')
      .create(recursive: true);
  final marker = File('${root.path}/ready');
  final db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/offline.sqlite')));
  final files = BenchmarkFiles(Directory('${root.path}/files'));
  final repo = OfflineRepository(db, files,
      legacyRoot: () async => Directory('${root.path}/legacy'));
  final network = ResumeBenchmarkNetwork(1001);
  final coordinator =
      OfflineDownloadCoordinator(repo, network, galleryLimit: 1, pageLimit: 1);
  final watch = Stopwatch()..start();
  await coordinator.initialize();
  final startupMs = watch.elapsedMicroseconds / 1000;
  final startupHashes = files.hashes;
  final startupChecks = files.checks;
  OfflineKey key(int count) =>
      OfflineKey(GallerySource.eh, 5900 + count, 'restart');
  if (!await marker.exists()) {
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGMU0bBhYGBgYmBgYGBgAAAFogB8q5SvRgAAAABJRU5ErkJggg==');
    final bytes = Uint8List(256 * 1024)..setRange(0, png.length, png);
    for (final count in [10, 1000]) {
      final id = key(count).id;
      await repo.create(key(count), 'Restart $count', count + 1);
      await repo.putIndex(
          id,
          count + 1,
          List.generate(
              count + 1,
              (i) =>
                  ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')),
          current: () => true);
      for (var page = 0; page < count; page++) {
        final saved = await files.write(id, page, Stream.value(bytes),
            current: () => true);
        await repo.savePage(id, page, saved, current: () => true);
        if ((page + 1) % 100 == 0)
          debugPrint('[restart-seed] ${page + 1}/$count');
      }
    }
    await marker.writeAsString('0', flush: true);
    await coordinator.dispose();
    await repo.dispose();
    await db.close();
    debugPrint('[restart-benchmark] SEEDED');
    return;
  }
  final round = int.parse(await marker.readAsString()) + 1;
  await marker.writeAsString('$round', flush: true);
  if (startupHashes != 0 || startupChecks != 1010 || network.indexes != 0) {
    throw StateError('Restart did not reuse durable verification');
  }
  final storage = LocalStorage();
  await storage.init();
  final settings = SettingsBloc(SettingsRepository(storage),
      initialState: const SettingsState(locale: 'en'));
  final bloc = DownloadBloc(coordinator);
  runApp(MultiBlocProvider(providers: [
    BlocProvider<DownloadBloc>.value(value: bloc),
    BlocProvider<SettingsBloc>.value(value: settings),
  ], child: MaterialApp(theme: AppTheme.light, home: const DownloadScreen())));
  await Future<void>.delayed(const Duration(milliseconds: 600));
  var pointer = 0;
  for (final count in [10, 1000]) {
    final id = key(count).id;
    final card = elements().firstWhere((e) =>
        e.widget is Card &&
        elements(e).any((child) =>
            child.widget is Text &&
            (child.widget as Text).data == 'Restart $count'));
    final button = elements(card).singleWhere((e) =>
        e.widget is TextButton &&
        (e.widget as TextButton).child is Text &&
        ((e.widget as TextButton).child as Text).data == 'Resume download');
    final box = button.findRenderObject()! as RenderBox;
    final position = box.localToGlobal(box.size.center(Offset.zero));
    final elapsed = Stopwatch()..start();
    double? requestMs;
    network.onImage = () {
      requestMs ??= elapsed.elapsedMicroseconds / 1000;
    };
    GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(pointer: ++pointer, position: position));
    GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(pointer: pointer, position: position));
    var feedback = false;
    while (!feedback) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      feedback = bloc.state.resumingIds.contains(id) ||
          bloc.state.tasks
              .any((b) => b.id == id && b.status != OfflineStatus.paused);
      if (elapsed.elapsedMilliseconds > 10000)
        throw StateError('No resume feedback');
    }
    final feedbackMs = elapsed.elapsedMicroseconds / 1000;
    await until(() => requestMs != null);
    await coordinator.pause(id);
    await until(() => coordinator.activePages == 0);
    if (files.hashes != 0 || network.indexes != 0)
      throw StateError('Redundant work after restart');
    debugPrint('[restart-sample] ${jsonEncode({
          'round': round,
          'completedPages': count,
          'startupMs': startupMs,
          'startupHashes': startupHashes,
          'startupChecks': startupChecks,
          'feedbackMs': feedbackMs,
          'requestMs': requestMs,
          'indexRequests': network.indexes,
          'hashReads': files.hashes
        })}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  runApp(const SizedBox());
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await bloc.close();
  await coordinator.dispose();
  await repo.dispose();
  await db.close();
  await settings.close();
  debugPrint('[restart-benchmark] COMPLETE $round');
}
