import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:oviewer/main.dart' as application;
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/services/offline_download_coordinator.dart';
import 'package:oviewer/models/download_range.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/home/home_screen.dart';
import 'offline_validation.dart' show FixtureDioClient;
import 'reader_entry_benchmark.dart' show elements, screen;
import 'partial_download_acceptance.dart' show fixture, waitFor, check;

class _TraceClient extends FixtureDioClient {
  _TraceClient(super.cookies, super.database);
  final parts = <int>[];
  @override
  Future<String> get(String url,
      {Map<String, dynamic>? queryParams,
      CancelToken? cancelToken,
      bool followRedirects = true}) {
    final uri = Uri.parse(url);
    if (uri.path == '/g/750076/abc123/') {
      parts.add(
          int.parse('${queryParams?['p'] ?? uri.queryParameters['p'] ?? 0}'));
    }
    return super.get(url,
        queryParams: queryParams,
        cancelToken: cancelToken,
        followRedirects: followRedirects);
  }
}

// Only the isolated test package, with scripts.offline_fixture_server + adb reverse.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError('Isolated offline_test package required');
  }
  try {
    await _run();
  } catch (error, stack) {
    debugPrint('[sparse-index-acceptance] FAIL $error\n$stack');
    rethrow;
  }
}

Future<void> _run() async {
  await fixture('control?enabled=1&delay=0.02&pages=120&reset=1');
  late _TraceClient client;
  await application
      .startOfflineValidation((c, d) => client = _TraceClient(c, d));
  await waitFor(() => WidgetsBinding.instance.rootElement != null);
  await waitFor(() => elements().any((e) => e.widget is HomeScreen));
  final repo = GetIt.I<OfflineRepository>();
  final coordinator = GetIt.I<OfflineDownloadCoordinator>();
  final settings = GetIt.I<SettingsRepository>();
  await settings.setReadingMode(0);
  await settings.setReaderPageLayout(ReaderPageLayout.single);
  await settings.setReaderPreloadCount(1);
  const key = OfflineKey(GallerySource.eh, 750076, 'abc123');
  await coordinator.delete(key.id);
  await EhImageCacheManager.instance.emptyCache();
  await coordinator.enqueue(key, 'Sparse index fixture', 120,
      range: DownloadRange.parse('85,119', 120));
  await waitFor(() async => (await repo.get(key.id))?.complete == true);
  var book = (await repo.get(key.id))!;
  final initial = List.of(client.parts);
  check(initial.join(',') == '0,14,19', 'Initial directory requests: $initial');
  check(
      book.pages.length == 18 &&
          book.completedPages == 2 &&
          !book.hasCompleteIndex,
      'Must persist only three directory parts and two selected images');
  await coordinator.enqueue(key, book.record.title, 120,
      range: DownloadRange.parse('86', 120));
  await waitFor(() async => (await repo.get(key.id))!.complete);
  check(client.parts.length == 3, 'Cached directory part should be reused');
  await coordinator.enqueue(key, book.record.title, 120,
      range: DownloadRange.parse('61', 120));
  await waitFor(() async => (await repo.get(key.id))!.complete);
  final extended = List.of(client.parts);
  check(extended.join(',') == '0,14,19,10',
      'Extension directory requests: $extended');
  final navigator = Navigator.of(screen(HomeScreen));
  unawaited(navigator.pushNamed('/reader', arguments: {
    'gid': key.gid,
    'token': key.token,
    'source': key.source,
    'offlineId': key.id,
    'initialPage': 72,
  }));
  ReaderBloc? reader;
  await waitFor(() {
    for (final element in elements()) {
      try {
        reader = element.read<ReaderBloc>();
        break;
      } catch (_) {}
    }
    return reader?.state.readyResources.containsKey(72) == true;
  });
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final reading = client.parts.skip(extended.length).toList();
  check(
      reading.contains(12) &&
          reading.every((p) => p == 11 || p == 12) &&
          reading.length <= 2,
      'Reader must fetch only visible/prefetch parts, not header or intervening parts: $reading');
  book = (await repo.get(key.id))!;
  check(
      book.completedPages == 4 &&
          book.targetPages == 4 &&
          book.record.totalPages == 120,
      'Reading must preserve selected download scope and original page count');
  debugPrint('[sparse-index-acceptance] PASS ${jsonEncode({
        'total_pages': 120,
        'total_index_parts': 20,
        'initial_parts': initial,
        'extended_parts': extended,
        'reading_parts': reading,
        'durable_images': book.completedPages,
        'stored_index_rows': book.pages.length,
      })}');
  navigator.pop();
  unawaited(navigator.pushNamed('/downloads'));
}
