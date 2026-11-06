import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:oviewer/main.dart' as application;
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/screens/home/home_screen.dart';
import 'offline_validation.dart' show FixtureDioClient;
import 'reader_entry_benchmark.dart' show elements, screen;
import 'partial_download_acceptance.dart' show fixture, waitFor, check;

// Host reads KEY markers from logcat and injects the corresponding Android
// keyevent. A widget-only channel mock would bypass MainActivity.dispatchKeyEvent.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError('Isolated offline_test package required');
  }
  try {
    await _run();
  } catch (error, stack) {
    debugPrint('[volume-acceptance] FAIL $error\n$stack');
    rethrow;
  }
}

Future<void> key(int code, ReaderBloc reader, int target, String label) async {
  debugPrint('[volume-acceptance] KEY $code $label target=$target');
  await waitFor(() => reader.state.currentPage == target);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  check(reader.state.currentPage == target, 'No duplicate turns: $label');
}

Future<void> _run() async {
  await fixture('control?enabled=1&delay=0.02&pages=12&reset=1');
  await application.startOfflineValidation((c, d) => FixtureDioClient(c, d));
  await waitFor(() => WidgetsBinding.instance.rootElement != null);
  await waitFor(() => elements().any((e) => e.widget is HomeScreen));
  final coordinator = GetIt.I<OfflineDownloadCoordinator>();
  final repository = GetIt.I<OfflineRepository>();
  const offline = OfflineKey(GallerySource.eh, 750080, 'abc123');
  await coordinator.delete(offline.id);
  await coordinator.enqueue(offline, 'Volume key acceptance', 12);
  await waitFor(
      () async => (await repository.get(offline.id))?.complete == true);
  final home = screen(HomeScreen);
  final settings = home.read<SettingsBloc>();
  final navigator = Navigator.of(home);
  var cases = 0;
  for (final mode in [0, 1, 2]) {
    for (final layout in ReaderPageLayout.values) {
      settings.add(UpdateReadingMode(mode));
      settings.add(UpdateReaderPageLayout(layout));
      settings
          .add(const UpdateReaderSpreadAlignment(ReaderSpreadAlignment.height));
      final transition = Completer<void>();
      settings.add(UpdateReaderPageTransition(
          layout == ReaderPageLayout.single
              ? ReaderPageTransition.none
              : ReaderPageTransition.slide,
          transition));
      await transition.future;
      final enable = Completer<void>();
      settings.add(UpdateReaderVolumeKeys(true, enable));
      await enable.future;
      await waitFor(() =>
          settings.state.readingMode == mode &&
          settings.state.pageLayout == layout);
      unawaited(navigator.pushNamed('/reader', arguments: {
        'gid': offline.gid,
        'token': offline.token,
        'source': offline.source,
        'offlineId': offline.id,
        'initialPage': 0
      }));
      ReaderBloc? reader;
      await waitFor(() {
        for (final e in elements()) {
          try {
            reader = e.read<ReaderBloc>();
            break;
          } catch (_) {}
        }
        return reader?.state.readyResources.containsKey(0) == true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final next = layout == ReaderPageLayout.single ? 1 : 2;
      await key(25, reader!, next, '$mode/${layout.name}/next');
      await key(24, reader!, 0, '$mode/${layout.name}/previous');
      check(!reader!.state.showUI, 'Volume input does not toggle controls');
      if (mode == 2) {
        final row = elements().firstWhere(
            (e) => e.widget.key == const ValueKey('reader-spread-0'));
        final size = (row.findRenderObject()! as RenderBox).size;
        check(size.height > size.width, 'Portrait height-fit remains active');
      }
      // Covering the reader releases volume keys even though it stays mounted.
      unawaited(navigator.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Volume key overlay')))));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      debugPrint(
          '[volume-acceptance] KEY 25 $mode/${layout.name}/covered target=0');
      await Future<void>.delayed(const Duration(seconds: 2));
      check(reader!.state.currentPage == 0, 'Covered reader must not turn');
      navigator.pop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await key(25, reader!, next, '$mode/${layout.name}/resume');
      navigator.pop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      cases++;
    }
  }
  final disable = Completer<void>();
  settings.add(UpdateReaderVolumeKeys(false, disable));
  await disable.future;
  debugPrint('[volume-acceptance] PASS cases=$cases');
}
