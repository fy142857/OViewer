import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:oviewer/main.dart' as application;
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/network/image_cache_scope.dart';
import 'package:oviewer/screens/home/home_screen.dart';
import 'package:oviewer/widgets/site_mode_tile.dart';
import 'reader_entry_benchmark.dart' show elements, screen, settle;

// Local HTML only: switching tests must not depend on remote server latency.
class BenchmarkDio extends DioClient {
  BenchmarkDio(super.cookies, super.database);
  @override
  Future<String> get(String url,
          {Map<String, dynamic>? queryParams,
          CancelToken? cancelToken,
          bool followRedirects = true}) async =>
      '<html><body><table class="itg"></table>No hits found</body></html>';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError('Isolated test package required');
  }
  await application.startOfflineValidation((c, d) => BenchmarkDio(c, d));
  await settle(1000);
  unawaited(Navigator.of(screen(HomeScreen)).pushNamed('/settings'));
  await settle(1200);
  final cache = GetIt.I<EhImageCacheManager>();
  await cache.emptyCache();
  final scope = ImageCacheScope.capture();
  var pointer = 0;
  for (final count in [0, 1000]) {
    if (count > 0) {
      final bytes = Uint8List(64 * 1024);
      for (var batch = 0; batch < count; batch += 64) {
        await Future.wait([
          for (var i = batch; i < count && i < batch + 64; i++)
            cache.putFile('https://example.invalid/site-benchmark/$i', bytes,
                key: scope.key('https://example.invalid/site-benchmark/$i')),
        ]);
        debugPrint(
            '[site-benchmark-seed] ${batch + 64 > count ? count : batch + 64}/$count');
      }
    }
    final sizes = <double>[];
    final completions = <double>[];
    for (var sample = 0; sample < 42; sample++) {
      final tile = screen(SiteModeTile);
      final bloc = tile.read<SettingsBloc>();
      final target = !bloc.state.useExHentai;
      final control = elements(tile).singleWhere((e) => e.widget is Switch);
      final box = control.findRenderObject()! as RenderBox;
      final point = box.localToGlobal(box.size.center(Offset.zero));
      final clock = Stopwatch()..start();
      GestureBinding.instance.handlePointerEvent(
          PointerDownEvent(pointer: ++pointer, position: point));
      GestureBinding.instance.handlePointerEvent(
          PointerUpEvent(pointer: pointer, position: point));
      var feedback = false;
      while (clock.elapsedMilliseconds < 3000) {
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
        final value = elements(screen(SiteModeTile))
            .singleWhere((e) => e.widget is Switch)
            .widget as Switch;
        if (value.value == target) {
          feedback = true;
          break;
        }
      }
      if (!feedback) throw StateError('No switch feedback');
      final feedbackMs = clock.elapsedMicroseconds / 1000;
      while (bloc.state.switchingSite && clock.elapsedMilliseconds < 3000) {
        await settle(1);
      }
      if (bloc.state.useExHentai != target ||
          bloc.state.siteSwitchError != null) {
        throw StateError('Site did not commit');
      }
      if (sample >= 2) {
        sizes.add(feedbackMs);
        completions.add(clock.elapsedMicroseconds / 1000);
      }
      await settle(300);
    }
    sizes.sort();
    completions.sort();
    final p95 = sizes[(sizes.length * .95).ceil() - 1];
    if (count > 0 &&
        await cache.getFileFromCache(
                scope.key('https://example.invalid/site-benchmark/999')) ==
            null) {
      throw StateError('Switch deleted the disk cache');
    }
    debugPrint('[site-benchmark] ${jsonEncode({
          'entries': count,
          'samples': sizes.length,
          'feedback_median_ms': sizes[sizes.length ~/ 2],
          'feedback_p95_ms': p95,
          'feedback_max_ms': sizes.last,
          'commit_p95_ms': completions[(completions.length * .95).ceil() - 1],
          'retained_bytes': await cache.getSizeBytes(),
        })}');
    if (p95 > 100) throw StateError('Site switch feedback exceeded 100ms P95');
  }
  debugPrint('[site-benchmark] COMPLETE');
}
