import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:oviewer/main.dart' as application;
import 'offline_validation.dart' show FixtureDioClient;
import 'reader_entry_benchmark.dart' show elements, screen, settle;
import 'package:oviewer/repositories/offline_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/screens/home/home_screen.dart';
import 'package:oviewer/screens/gallery_detail/gallery_detail_screen.dart';
import 'package:oviewer/screens/download/download_screen.dart';
import 'package:oviewer/blocs/reader/reader_bloc.dart';
import 'package:oviewer/blocs/reader/reader_event.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.oviewer.oviewer.offline_test')
    throw StateError('Isolated test package required');
  await application.startOfflineValidation((c, d) => FixtureDioClient(c, d));
  await settle(1200);
  final repo = GetIt.I<OfflineRepository>();
  const key = OfflineKey(GallerySource.eh, 1001, 'abc123');
  final book = await repo.create(key, 'Offline Fixture EH 1001', 12);
  if (!book.complete) {
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
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGMU0bBhYGBgYmBgYGBgAAAFogB8q5SvRgAAAABJRU5ErkJggg==');
    for (var i = 0; i < 12; i++) {
      final file = await repo.files
          .write(book.id, i, Stream.value(bytes), current: () => true);
      await repo.savePage(book.id, i, file, current: () => true);
    }
    await repo.setStatus(book.id, OfflineStatus.completed);
  }
  final nav = Navigator.of(screen(HomeScreen));
  for (final mode in [0, 1, 2]) {
    await GetIt.I<SettingsRepository>().setReadingMode(mode);
    for (final source in ['download', 'offline_detail', 'online_detail']) {
      nav.popUntil((r) => r.isFirst);
      await settle(400);
      final gid = source == 'online_detail' ? 1002 : 1001;
      unawaited(nav.pushNamed(source == 'download' ? '/downloads' : '/gallery',
          arguments: {'gid': gid, 'token': 'abc123'}));
      await settle(1500);
      final root =
          screen(source == 'download' ? DownloadScreen : GalleryDetailScreen);
      final route = ModalRoute.of(root)!;
      final scaffold = elements(root).firstWhere((e) => e.widget is Scaffold)
          as StatefulElement;
      final initialState = scaffold.state;
      final header = elements(root).firstWhere((e) => e.widget is AppBar);
      final body = elements(root).firstWhere((e) => ((e.widget is Text &&
              (e.widget as Text).data == 'Offline Fixture EH $gid') ||
          (e.widget is SelectableText &&
              (e.widget as SelectableText).data == 'Offline Fixture EH $gid')));
      Rect rect(Element e) {
        final box = e.findRenderObject()! as RenderBox;
        return Rect.fromPoints(box.localToGlobal(Offset.zero),
            box.localToGlobal(box.size.bottomRight(Offset.zero)));
      }

      final before = [rect(header), rect(body)];
      final initialPadding = MediaQuery.of(root).padding;
      final initialWindowSize =
          WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
      for (final controls in [false, true]) {
        for (var repetition = 0;
            repetition <
                const int.fromEnvironment('BACKGROUND_REPEATS',
                    defaultValue: 3);
            repetition++) {
          var tracking = true;
          var phase = 'enter';
          var count = 0;
          var delta = 0.0;
          var secondary = 0.0;
          var stateChanged = false;
          var windowChanged = false;
          void frame(Duration _) {
            if (!tracking) return;
            if (phase != 'covered') {
              count++;
              windowChanged = windowChanged ||
                  WidgetsBinding.instance.platformDispatcher.views.first
                          .physicalSize !=
                      initialWindowSize;
              final current = [rect(header), rect(body)];
              for (var i = 0; i < current.length; i++) {
                delta = math.max(
                    delta,
                    math.max((current[i].left - before[i].left).abs(),
                        (current[i].top - before[i].top).abs()));
                delta = math.max(
                    delta,
                    math.max((current[i].width - before[i].width).abs(),
                        (current[i].height - before[i].height).abs()));
              }
              secondary =
                  math.max(secondary, route.secondaryAnimation?.value ?? 0);
              stateChanged = stateChanged ||
                  !identical(
                      (elements(root).firstWhere((e) => e.widget is Scaffold)
                              as StatefulElement)
                          .state,
                      initialState);
            }
            WidgetsBinding.instance.addPostFrameCallback(frame);
            WidgetsBinding.instance.scheduleFrame();
          }

          WidgetsBinding.instance.addPostFrameCallback(frame);
          if (source == 'download') {
            elements(root)
                .map((e) => e.widget)
                .whereType<InkWell>()
                .firstWhere((w) => w.onTap != null)
                .onTap!();
          } else {
            (elements(root)
                    .firstWhere(
                        (e) => e.widget.key == const ValueKey('read-gallery'))
                    .widget as FilledButton)
                .onPressed!();
          }
          await settle(380);
          phase = 'covered';
          if (controls) {
            final view = elements().lastWhere(
                (e) => e.widget.runtimeType.toString() == '_ReaderView');
            view.read<ReaderBloc>().add(ToggleReaderUI());
          }
          await settle(250);
          phase = 'exit';
          nav.pop();
          await settle(450);
          tracking = false;
          final afterPadding = MediaQuery.of(root).padding;
          debugPrint('[reader-background] ${jsonEncode({
                'mode': mode,
                'source': source,
                'controls': controls,
                'sample': repetition,
                'frames': count,
                'max_delta': delta,
                'max_secondary': secondary,
                'state_changed': stateChanged,
                'padding_equal': initialPadding == afterPadding,
                'live_padding_equal': afterPadding ==
                    nav.context
                        .getInheritedWidgetOfExactType<MediaQuery>()!
                        .data
                        .padding,
                'window_changed': windowChanged
              })}');
        }
      }
    }
  }
  await settle(400);
  debugPrint('[reader-background] complete');
}
