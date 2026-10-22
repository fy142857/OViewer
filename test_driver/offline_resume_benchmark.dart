import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:oviewer/blocs/download/download_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/offline_download_network.dart';
import 'package:oviewer/core/network/reader_request_controller.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/storage/offline_files.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/models/gallery_image.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/models/reader_index_page.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/download/download_screen.dart';
import 'reader_entry_benchmark.dart' show elements;

class ResumeBenchmarkNetwork extends OfflineDownloadNetwork {
  final int total;
  int indexes = 0;
  void Function()? onImage;
  ResumeBenchmarkNetwork(this.total);
  @override
  Object get session => 0;
  @override
  GallerySource get source => GallerySource.eh;
  @override
  Future<ReaderIndexPage> index(
      OfflineKey key, int page, ReaderRequestController request) async {
    indexes++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return ReaderIndexPage(
        totalPages: total,
        indexPage: page,
        indexPageCount: (total / 40).ceil(),
        pageSize: 40,
        thumbnails: {
          for (var i = page * 40; i < min(total, (page + 1) * 40); i++)
            i: ThumbnailInfo(pageToken: 'p$i', pageIndex: i, thumbUrl: '')
        });
  }

  @override
  Future<GalleryImage> image(
      OfflineKey key, String token, int page, ReaderRequestController request,
      {String? alternate}) async {
    onImage?.call();
    return GalleryImage(
        index: page, pageUrl: '', imageUrl: 'https://example.invalid/$page');
  }

  @override
  Future<FileServiceResponse> bytes(
      String url, ReaderRequestController request) async {
    final stream = StreamController<List<int>>();
    request.onCancel(() {
      unawaited(stream.close());
    });
    return HttpGetResponse(http.StreamedResponse(stream.stream, 200));
  }
}

class BenchmarkFiles extends OfflineFiles {
  int hashes = 0;
  int checks = 0;
  @override
  Future<OfflineFileStamp?> verifyForResume(
      String relative, int size, String digest,
      {OfflineFileStamp? previous}) async {
    final result =
        await super.verifyForResume(relative, size, digest, previous: previous);
    checks++;
    return result;
  }

  BenchmarkFiles(Directory directory) : super(root: () async => directory);
  @override
  Future<String> digestOf(File file) {
    hashes++;
    return super.digestOf(file);
  }
}

Future<void> until(bool Function() done) async {
  final timeout = Stopwatch()..start();
  while (!done()) {
    if (timeout.elapsed > const Duration(seconds: 30))
      throw StateError('Benchmark timeout');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

typedef CoordinatorFactory = OfflineDownloadCoordinator Function(
    OfflineRepository, OfflineDownloadNetwork);
Future<void> main() => runResumeBenchmark(
    (r, n) => OfflineDownloadCoordinator(r, n, galleryLimit: 1, pageLimit: 1),
    'fixed');

// Identical fixture and device for both coordinators. The baseline runner can
// inject the historical coordinator; UI timings are reported for current UI only.
Future<void> runResumeBenchmark(
    CoordinatorFactory factory, String label) async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError('Isolated offline_test package required');
  }
  final storage = LocalStorage();
  await storage.init();
  final settings = SettingsBloc(SettingsRepository(storage),
      initialState: const SettingsState(locale: 'en'));
  final base = await getApplicationSupportDirectory();
  var pointer = 0;
  for (final count in [10, 1000]) {
    final root = await Directory('${base.path}/resume-benchmark')
        .create(recursive: true);
    final directory = await root.createTemp('$label-$count-');
    final db = AppDatabase.forTesting(
        NativeDatabase(File('${directory.path}/data.sqlite')));
    final files = BenchmarkFiles(Directory('${directory.path}/files'));
    final repo = OfflineRepository(db, files,
        legacyRoot: () async => Directory('${directory.path}/legacy'));
    final network = ResumeBenchmarkNetwork(count + 1);
    final coordinator = factory(repo, network);
    final bloc = DownloadBloc(coordinator);
    await coordinator.initialize();
    const key = OfflineKey(GallerySource.eh, 59, 'benchmark');
    var reached = false;
    network.onImage = () {
      reached = true;
    };
    final id = await coordinator.enqueue(key, 'Resume benchmark', count + 1);
    await until(() => reached);
    await coordinator.pause(id);
    await until(() => coordinator.activePages == 0);
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGMU0bBhYGBgYmBgYGBgAAAFogB8q5SvRgAAAABJRU5ErkJggg==');
    final bytes = Uint8List(256 * 1024)..setRange(0, png.length, png);
    for (var page = 0; page < count; page++) {
      final saved =
          await files.write(id, page, Stream.value(bytes), current: () => true);
      await repo.savePage(id, page, saved, current: () => true);
      if ((page + 1) % 100 == 0)
        debugPrint('[resume-seed] $label ${page + 1}/$count');
    }
    runApp(MultiBlocProvider(
        providers: [
          BlocProvider<DownloadBloc>.value(value: bloc),
          BlocProvider<SettingsBloc>.value(value: settings),
        ],
        child:
            MaterialApp(theme: AppTheme.light, home: const DownloadScreen())));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final samples = <Map<String, Object>>[];
    for (var sample = 0; sample < 22; sample++) {
      final button = elements().singleWhere((e) =>
          e.widget is TextButton &&
          ((e.widget as TextButton).child is Text) &&
          ((e.widget as TextButton).child as Text).data == 'Resume download');
      final box = button.findRenderObject()! as RenderBox;
      final position = box.localToGlobal(box.size.center(Offset.zero));
      double? requestMs;
      final clock = Stopwatch()..start();
      network.onImage = () {
        requestMs ??= clock.elapsedMicroseconds / 1000;
      };
      final indexes = network.indexes;
      final hashes = files.hashes;
      final checks = files.checks;
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
        if (clock.elapsedMilliseconds > 30000)
          throw StateError('Missing feedback');
      }
      final feedbackMs = clock.elapsedMicroseconds / 1000;
      await until(() => requestMs != null);
      if (sample >= 2) {
        final result = <String, Object>{
          'feedbackMs': feedbackMs,
          'requestMs': requestMs!,
          'indexRequests': network.indexes - indexes,
          'hashReads': files.hashes - hashes
        };
        samples.add(result);
        debugPrint('[resume-sample] ${jsonEncode({
              'label': label,
              'completedPages': count,
              'sample': sample - 2,
              ...result
            })}');
      }
      if (sample < 2) await until(() => files.checks - checks >= count);
      await coordinator.pause(id);
      await until(() => coordinator.activePages == 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    debugPrint('[resume-group] ${jsonEncode({
          'label': label,
          'completedPages': count,
          'bytesPerPage': bytes.length,
          'sampleCount': samples.length
        })}');
    runApp(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await bloc.close();
    await coordinator.dispose();
    await repo.dispose();
    await db.close();
    if (!directory.path.startsWith('${base.path}/resume-benchmark/'))
      throw StateError('Unsafe cleanup');
    await directory.delete(recursive: true);
  }
  await settings.close();
  debugPrint('[resume-benchmark] COMPLETE $label');
}
