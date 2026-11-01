import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:oviewer/main.dart' as application;
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/models/download_range.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/screens/home/home_screen.dart';
import 'package:oviewer/widgets/download_range_dialog.dart';
import 'offline_validation.dart' show FixtureDioClient;
import 'reader_entry_benchmark.dart' show elements, screen;

// Run only against scripts.offline_fixture_server through adb reverse tcp:8765.
// Uses real widgets, SQLite, image decoding, HTTP, and download workers.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError('Isolated offline_test package required');
  }
  try {
    await _accept();
    debugPrint('[issue75-acceptance] PASS');
  } catch (error, stack) {
    debugPrint('[issue75-acceptance] FAIL $error\n$stack');
    rethrow;
  }
}

Future<void> waitFor(FutureOr<bool> Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!await predicate()) {
    if (clock.elapsed > const Duration(seconds: 45)) {
      throw StateError('Acceptance condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<Map<String, dynamic>> fixture(String path) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:8765/$path'));
    final response = await request.close();
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<void> _accept() async {
  await fixture('control?enabled=1&delay=0.05&pages=12&reset=1');
  await application.startOfflineValidation((c, d) => FixtureDioClient(c, d));
  await waitFor(() => WidgetsBinding.instance.rootElement != null);
  await waitFor(() => elements().any((e) => e.widget is HomeScreen));
  final repo = GetIt.I<OfflineRepository>();
  final settings = GetIt.I<SettingsRepository>();
  await settings.setReadingMode(0);
  await settings.setReaderPageLayout(ReaderPageLayout.single);
  await settings.setReaderPreloadCount(1);
  final downloads = GetIt.I<OfflineDownloadCoordinator>();
  const key = OfflineKey(GallerySource.eh, 750075, 'abc123');
  await downloads.delete(key.id);
  await EhImageCacheManager.instance.emptyCache();
  final navigator = Navigator.of(screen(HomeScreen));
  unawaited(navigator.pushNamed('/gallery', arguments: {
    'gid': key.gid,
    'token': key.token,
    'source': key.source,
  }));
  await waitFor(() => elements()
      .any((e) => e.widget.key == const ValueKey('download-gallery')));
  (elements()
          .firstWhere((e) => e.widget.key == const ValueKey('download-gallery'))
          .widget as IconButton)
      .onPressed!();
  await waitFor(() => elements().any((e) => e.widget is DownloadRangeDialog));
  elements()
      .map((e) => e.widget)
      .whereType<RadioListTile<bool>>()
      .firstWhere((w) => !w.value)
      .onChanged!(false);
  await waitFor(() => elements()
      .any((e) => e.widget.key == const ValueKey('download-range-input')));
  final input = elements()
      .firstWhere((e) => e.widget.key == const ValueKey('download-range-input'))
      .widget as TextField;
  input.controller!.text = '3-4,8';
  input.onChanged!('3-4,8');
  await Future<void>.delayed(const Duration(milliseconds: 200));
  (elements()
          .firstWhere(
              (e) => e.widget.key == const ValueKey('confirm-download-range'))
          .widget as FilledButton)
      .onPressed!();
  await waitFor(() async => (await repo.get(key.id))?.complete == true);
  var book = (await repo.get(key.id))!;
  check(
      book.completedPages == 3 &&
          book.targetPages == 3 &&
          !book.allPagesComplete,
      'Partial task must complete without downloading the entire gallery');
  check(book.record.lastReadPage == 2,
      'First entry must start at the selected page');
  final stats = await fixture('stats');
  final initialImages = (stats['requests'] as List)
      .where((p) => '$p'.startsWith('/image/eh/750075/'))
      .toSet();
  check(initialImages.length == 3,
      'Only selected images should download: $initialImages');
  debugPrint(
      '[issue75-acceptance] partial_download ${book.range.label} ${book.completedPages}/12');

  await fixture('control?enabled=0&reset=1');
  unawaited(navigator.pushNamed('/reader', arguments: {
    'gid': key.gid,
    'token': key.token,
    'source': key.source,
    'offlineId': key.id
  }));
  ReaderBloc? reader;
  await waitFor(() {
    for (final element in elements()) {
      try {
        reader = element.read<ReaderBloc>();
        break;
      } catch (_) {}
    }
    return reader?.state.readyResources.containsKey(2) == true;
  });
  check(reader!.state.currentPage == 2, 'Initial reader position changed');
  check(reader!.state.totalPages == 12, 'Original page numbering must remain');
  reader!.add(ToggleReaderUI());
  await waitFor(() => elements().any((e) => e.widget is Slider));
  elements().map((e) => e.widget).whereType<Slider>().first.onChangeEnd!(5);
  await waitFor(() => reader!.state.failedIndices.contains(5));
  check(
      elements()
          .any((e) => e.widget is Text && (e.widget as Text).data == 'Retry'),
      'Unavailable page must offer retry');
  debugPrint('[issue75-acceptance] disconnected_local_read_and_missing_retry');
  await fixture('control?enabled=1&reset=1');
  reader!.add(const RetryImageAtIndex(5));
  await waitFor(() => reader!.state.readyResources.containsKey(5));
  book = (await repo.get(key.id))!;
  check(book.completedPages == 3 && book.range.label == '3-4, 8',
      'Online reading must not expand durable downloads');
  check(reader!.state.localPage(5) == null, 'Fallback must use ordinary cache');
  debugPrint(
      '[issue75-acceptance] reconnected_image_decoded_without_expanding_target');
  navigator.pop();
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await downloads.enqueue(key, book.record.title, 12,
      range: DownloadRange.parse('1', 12));
  await waitFor(() async => (await repo.get(key.id))!.complete);
  check((await repo.get(key.id))!.targetPages == 4,
      'Supplement must merge targets');
  await downloads.enqueue(key, book.record.title, 12);
  await waitFor(() async => (await repo.get(key.id))!.allPagesComplete);
  debugPrint('[issue75-acceptance] supplemented_and_completed_12_pages');
  navigator.popUntil((route) => route.isFirst);
  unawaited(navigator.pushNamed('/downloads'));
}
