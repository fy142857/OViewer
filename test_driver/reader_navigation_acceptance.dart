import 'dart:async';
import 'package:flutter/gestures.dart';
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

final _clock = Stopwatch()..start();
int _pointer = 100;
void send(PointerEvent event) =>
    GestureBinding.instance.handlePointerEvent(event);
Future<void> tap(Offset point) async {
  final id = ++_pointer;
  send(PointerDownEvent(
      pointer: id, position: point, timeStamp: _clock.elapsed));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  send(PointerUpEvent(pointer: id, position: point, timeStamp: _clock.elapsed));
  await Future<void>.delayed(const Duration(milliseconds: 600));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test') {
    throw StateError('Isolated offline_test package required');
  }
  try {
    await run();
  } catch (error, stack) {
    debugPrint('[reader-navigation-acceptance] FAIL $error\n$stack');
    rethrow;
  }
}

Future<void> run() async {
  await fixture('control?enabled=1&delay=0.02&pages=12&reset=1');
  await application.startOfflineValidation((c, d) => FixtureDioClient(c, d));
  await waitFor(() => WidgetsBinding.instance.rootElement != null);
  await waitFor(() => elements().any((e) => e.widget is HomeScreen));
  final coordinator = GetIt.I<OfflineDownloadCoordinator>();
  final repository = GetIt.I<OfflineRepository>();
  const key = OfflineKey(GallerySource.eh, 750077, 'abc123');
  await coordinator.delete(key.id);
  await coordinator.enqueue(key, 'Reader navigation acceptance', 12);
  await waitFor(() async => (await repository.get(key.id))?.complete == true);
  final home = screen(HomeScreen);
  final settings = home.read<SettingsBloc>();
  final navigator = Navigator.of(home);
  var cases = 0;
  for (final mode in [0, 1, 2]) {
    for (final layout in ReaderPageLayout.values) {
      for (final transition in ReaderPageTransition.values) {
        settings.add(UpdateReadingMode(mode));
        settings.add(UpdateReaderPageLayout(layout));
        final done = Completer<void>();
        settings.add(UpdateReaderPageTransition(transition, done));
        await done.future;
        await waitFor(() =>
            settings.state.readingMode == mode &&
            settings.state.pageLayout == layout);
        unawaited(navigator.pushNamed('/reader', arguments: {
          'gid': key.gid,
          'token': key.token,
          'source': key.source,
          'offlineId': key.id,
          'initialPage': 0,
        }));
        ReaderBloc? reader;
        await waitFor(() {
          for (final element in elements()) {
            try {
              reader = element.read<ReaderBloc>();
              break;
            } catch (_) {}
          }
          return reader?.state.readyResources.containsKey(0) == true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final viewport = elements().firstWhere((e) =>
            e.widget is Listener &&
            e.widget.key is GlobalKey &&
            (e.widget as Listener).onPointerMove != null);
        final box = viewport.findRenderObject()! as RenderBox;
        Offset point(double x, double y) =>
            box.localToGlobal(Offset(box.size.width * x, box.size.height * y));
        final next = point(mode == 1 ? .05 : .95, mode == 2 ? .7 : .5);
        final previous = point(mode == 1 ? .95 : .05, mode == 2 ? .3 : .5);
        await tap(point(.5, .5));
        check(reader!.state.showUI, 'Center tap shows controls');
        await tap(next);
        check(
            reader!.state.currentPage ==
                (layout == ReaderPageLayout.single ? 1 : 2),
            'Next edge: $mode/$layout/$transition');
        check(reader!.state.showUI, 'Turning must retain controls');
        await tap(previous);
        check(reader!.state.currentPage == 0, 'Previous edge');
        await tap(point(.5, .5));
        check(!reader!.state.showUI, 'Center tap hides controls');
        if (mode != 2) {
          final id = ++_pointer;
          final start = point(.5, .5);
          final end = point(mode == 0 ? .1 : .9, .5);
          send(PointerDownEvent(
              pointer: id, position: start, timeStamp: _clock.elapsed));
          for (var step = 1; step <= 5; step++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            send(PointerMoveEvent(
                pointer: id,
                position: Offset.lerp(start, end, step / 5)!,
                delta: (end - start) / 5,
                timeStamp: _clock.elapsed));
          }
          if (transition == ReaderPageTransition.none) {
            check(reader!.state.currentPage == 0, 'No transition during drag');
          }
          send(PointerUpEvent(
              pointer: id, position: end, timeStamp: _clock.elapsed));
          await Future<void>.delayed(const Duration(milliseconds: 700));
          check(
              reader!.state.currentPage ==
                  (layout == ReaderPageLayout.single ? 1 : 2),
              'Swipe navigation');
        }
        await waitFor(() => reader!.state.readyResources
            .containsKey(reader!.state.currentPage));
        final beforeZoom = reader!.state.currentPage;
        final first = ++_pointer;
        final second = ++_pointer;
        send(PointerDownEvent(
            pointer: first,
            position: point(.375, .475),
            timeStamp: _clock.elapsed));
        send(PointerDownEvent(
            pointer: second,
            position: point(.625, .525),
            timeStamp: _clock.elapsed));
        for (var step = 1; step <= 5; step++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          send(PointerMoveEvent(
              pointer: first,
              position: point(.375 - .035 * step, .475 - .01 * step),
              delta: Offset(-box.size.width * .035, -box.size.height * .01),
              timeStamp: _clock.elapsed));
          send(PointerMoveEvent(
              pointer: second,
              position: point(.625 + .035 * step, .525 + .01 * step),
              delta: Offset(box.size.width * .035, box.size.height * .01),
              timeStamp: _clock.elapsed));
        }
        send(PointerUpEvent(
            pointer: first,
            position: point(.2, .425),
            timeStamp: _clock.elapsed));
        send(PointerUpEvent(
            pointer: second,
            position: point(.8, .575),
            timeStamp: _clock.elapsed));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final controls = reader!.state.showUI;
        await tap(next);
        check(reader!.state.currentPage == beforeZoom,
            'Zoom must block edge navigation');
        check(reader!.state.showUI != controls, 'Zoomed tap toggles controls');
        cases++;
        navigator.pop();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }
  debugPrint('[reader-navigation-acceptance] PASS cases=$cases');
}
