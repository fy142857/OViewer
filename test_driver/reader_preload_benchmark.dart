import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:oviewer/main.dart' as application;
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/core/network/reader_image_provider.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/router/reader_route.dart';
import 'package:oviewer/core/storage/reader_reentry_cache.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/models/reader_preload_window.dart';
import 'package:oviewer/screens/home/home_screen.dart';
import 'package:oviewer/screens/reader/reader_screen.dart';
import 'offline_validation.dart' show FixtureDioClient;
import 'reader_entry_benchmark.dart' show elements, screen, settle;

class PreloadFixtureClient extends FixtureDioClient {
  PreloadFixtureClient(super.cookies, super.database);
  @override
  String target(String url) =>
      super.target(url).replaceFirst('10.0.2.2', '127.0.0.1');
}

Future<dynamic> control(String path, [Object? body]) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final uri = Uri.parse('http://127.0.0.1:8765/$path');
    final request =
        body == null ? await client.getUrl(uri) : await client.postUrl(uri);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError('Fixture ${response.statusCode}');
    }
    return jsonDecode(await utf8.decoder.bind(response).join());
  } finally {
    client.close(force: true);
  }
}

Future<void> frame() async {
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
}

Future<bool> until(bool Function() ready, {int timeoutMs = 12000}) async {
  final timer = Stopwatch()..start();
  while (timer.elapsedMilliseconds < timeoutMs) {
    await frame();
    if (ready()) return true;
  }
  return false;
}

// This observes rendered pixels rather than URL availability or resource-ready
// events. Every target page must have a decoded RawImage intersecting the screen.
bool painted(int gid, List<int> pages) {
  final found = <int>{};
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final viewport = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  for (final element in elements()) {
    if (element.widget is! RawImage ||
        (element.widget as RawImage).image == null) continue;
    ReaderImageProvider? provider;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Image && widget.image is ReaderImageProvider) {
        provider = widget.image as ReaderImageProvider;
        return false;
      }
      return true;
    });
    final parts =
        provider == null ? <String>[] : Uri.parse(provider!.url).pathSegments;
    if (parts.length != 3 || parts[0] != 'image' || parts[1] != '$gid') {
      continue;
    }
    final box = element.findRenderObject();
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.intersect(viewport).width > 20 &&
        rect.intersect(viewport).height > 20) {
      found.add(int.parse(parts[2]));
    }
  }
  return found.containsAll(pages);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.preload_bench') {
    throw StateError('Requires isolated preload_bench package');
  }
  try {
    await application
        .startOfflineValidation((c, d) => PreloadFixtureClient(c, d));
    await settle(1200);
    final plans = await control('plan') as List;
    final nav = Navigator.of(screen(HomeScreen));
    final settings = screen(HomeScreen).read<SettingsBloc>();
    for (final raw in plans) {
      final plan = Map<String, dynamic>.from(raw as Map);
      final mode = plan['mode'] as int;
      final n = plan['n'] as int;
      final lead = ReaderPreloadWindow.addressLeadForCount(n);
      final layout = plan['double'] == true
          ? ReaderPageLayout.doublePage
          : ReaderPageLayout.single;
      settings.add(UpdateReadingMode(mode));
      settings.add(UpdateReaderPageLayout(layout));
      final saved = Completer<void>();
      settings.add(UpdateReaderPreloadCount(n, completer: saved));
      await saved.future;
      await until(() =>
          settings.state.readingMode == mode &&
          settings.state.pageLayout == layout);
      ReaderReentryCache.shared.clear();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      // Unique URLs prevent hits but do not control quota-scan cost. Start each
      // case with the same empty disk cache as well as empty memory caches.
      await EhImageCacheManager.instance.emptyCache();
      final cacheBeforeBytes =
          await EhImageCacheManager.instance.getSizeBytes();
      if (cacheBeforeBytes != 0) {
        throw StateError('Benchmark cache is not empty');
      }
      final config = await control('case', plan) as Map;
      final gid = config['gid'] as int;
      const start = 40;
      final spreads = ReaderSpreads(120, layout);
      final entry = Stopwatch()..start();
      unawaited(nav.push(ReaderRoute<void>(
          builder: (_) =>
              ReaderScreen(gid: gid, token: 'abc123', initialPage: start))));
      final entered =
          await until(() => painted(gid, spreads.containing(start)));
      if (!entered) throw StateError('Entry timeout for $gid $plan');
      final entryMs = entry.elapsedMicroseconds / 1000;
      if (mode == 2) {
        // Real drag start releases the explicit entry-page focus. Directly
        // calling scrollTo alone intentionally preserves that focus in the app.
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final size = view.physicalSize / view.devicePixelRatio;
        final startPoint = Offset(size.width / 2, size.height * .7);
        GestureBinding.instance.handlePointerEvent(
            PointerDownEvent(pointer: 71, position: startPoint));
        await settle(16);
        GestureBinding.instance.handlePointerEvent(PointerMoveEvent(
            pointer: 71,
            position: startPoint - const Offset(0, 40),
            delta: const Offset(0, -40)));
        await settle(16);
        GestureBinding.instance.handlePointerEvent(PointerCancelEvent(
            pointer: 71, position: startPoint - const Offset(0, 40)));
        await frame();
        final list = elements(screen(ReaderScreen))
            .map((e) => e.widget)
            .whereType<ScrollablePositionedList>()
            .first;
        await list.itemScrollController!.scrollTo(
            index: spreads.spreadOf(start),
            duration: const Duration(milliseconds: 180));
      }
      await settle(plan['warmup_ms'] as int? ?? 2000);
      final samples = <Map<String, dynamic>>[];
      var group = spreads.spreadOf(start);
      final direction = plan['backward'] == true ? -1 : 1;
      for (var step = 0; step < (plan['turns'] as int? ?? 12); step++) {
        group += direction;
        final pages = spreads.pages(group);
        final root = screen(ReaderScreen);
        final content = elements(root).firstWhere((e) =>
            e.widget is PhotoViewGallery ||
            e.widget is ScrollablePositionedList);
        final bloc = content.read<ReaderBloc>();
        final linksReady = pages.every(bloc.state.loadedImages.containsKey);
        final filesReady = pages.every(bloc.state.readyResources.containsKey);
        final timer = Stopwatch()..start();
        if (mode == 2) {
          await (content.widget as ScrollablePositionedList)
              .itemScrollController!
              .scrollTo(
                  index: group,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.linear);
        } else {
          await (content.widget as PhotoViewGallery)
              .pageController!
              .animateToPage(group,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.linear);
        }
        final settledMs = timer.elapsedMicroseconds / 1000;
        final visible =
            await until(() => painted(gid, pages), timeoutMs: 10000);
        final displayMs = timer.elapsedMicroseconds / 1000;
        final sample = <String, dynamic>{
          'step': step,
          'pages': pages,
          'links_ready': linksReady,
          'files_ready': filesReady,
          'settled_ms': settledMs,
          'display_ms': displayMs,
          'wait_after_scroll_ms': displayMs - settledMs,
          'timeout': !visible,
          'current_page': bloc.state.currentPage,
          'visible_pages': bloc.state.visiblePages.toList()..sort(),
        };
        samples.add(sample);
        debugPrint('[preload-turn] ${jsonEncode({
              'gid': gid,
              'lead': lead,
              ...sample
            })}');
        final remaining = (plan['pace_ms'] as int) - timer.elapsedMilliseconds;
        if (remaining > 0) await settle(remaining);
      }
      nav.pop();
      await settle(500);
      await control('result', {
        'gid': gid,
        'lead': lead,
        'plan': plan,
        'entry_ms': entryMs,
        'image_bytes': config['image_bytes'],
        'cache_before_bytes': cacheBeforeBytes,
        'driver_revision': 2,
        'parameter_override': const bool.hasEnvironment('READER_ADDRESS_LEAD'),
        'samples': samples,
      });
      debugPrint(
          '[preload-case] ${jsonEncode({'gid': gid, 'lead': lead, ...plan})}');
    }
    debugPrint('[preload-bench] complete');
  } catch (error, stack) {
    debugPrint('[preload-bench] FAILED $error\n$stack');
  }
}
