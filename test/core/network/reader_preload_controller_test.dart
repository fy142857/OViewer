import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/reader_preload_controller.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/models/reader_preload_window.dart';

void main() {
  test('horizontal drag anchors background range at current group', () {
    final window = ReaderPreloadWindow(
        const ReaderSpreads(50, ReaderPageLayout.single), 10, 1,
        visiblePages: {10, 11}, expandAroundVisible: false);
    expect(window.visible, {10, 11});
    expect(window.targets, {9, 10, 11});
    expect(window.neighbours, [9]);
  });

  test('discarded work can be revisited without a false error or stale queue',
      () async {
    final discarded = Completer<bool?>();
    var calls = 0;
    final controller = ReaderPreloadController(load: (page, _) {
      if (page == 11 && ++calls == 1) return discarded.future;
      return Future.value(true);
    });
    addTearDown(controller.dispose);
    controller.update(
        ReaderPreloadWindow(
            const ReaderSpreads(100, ReaderPageLayout.single), 10, 1),
        {});
    controller.update(
        ReaderPreloadWindow(
            const ReaderSpreads(100, ReaderPageLayout.single), 40, 1),
        {});
    discarded.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(controller.failed(11, 0), false);
    controller.update(
        ReaderPreloadWindow(
            const ReaderSpreads(100, ReaderPageLayout.single), 10, 1),
        {});
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    expect(controller.permits(11, 0), true);
  });
  for (final layout in ReaderPageLayout.values) {
    for (final n in [1, 2, 3, 4, 5]) {
      for (final total in [0, 1, 19, 50]) {
        test('window $layout N=$n total=$total preserves bounds and metadata',
            () {
          final spreads = ReaderSpreads(total, layout);
          for (var page = 0; page < total; page++) {
            final window = ReaderPreloadWindow(spreads, page, n);
            final group = page ~/ spreads.pagesPerSpread;
            final first =
                ((group - n) * spreads.pagesPerSpread).clamp(0, total);
            final last =
                ((group + n + 1) * spreads.pagesPerSpread).clamp(0, total);
            expect(window.targets, {for (var p = first; p < last; p++) p});
            expect(window.addresses, containsAll(window.targets));
            final radius = n + ReaderPreloadWindow.addressLeadForCount(n);
            expect(window.addresses, {
              for (var p = ((group - radius) * spreads.pagesPerSpread)
                      .clamp(0, total);
                  p <
                      ((group + radius + 1) * spreads.pagesPerSpread)
                          .clamp(0, total);
                  p++)
                p,
            });
            expect(window.neighbours.toSet().length, window.neighbours.length);
          }
          if (total == 0)
            expect(ReaderPreloadWindow(spreads, 0, n).targets, isEmpty);
        });
      }
    }
  }

  test('vertical viewport expands around all visible groups', () {
    final window = ReaderPreloadWindow(
        const ReaderSpreads(50, ReaderPageLayout.doublePage), 11, 3,
        visiblePages: {11, 12, 13, 14});
    expect(window.visible, {10, 11, 12, 13, 14, 15});
    expect(window.targets, {for (var p = 4; p <= 21; p++) p});
    expect(window.neighbours, [16, 17, 8, 9, 18, 19, 6, 7, 20, 21, 4, 5]);
  });

  test('link lead follows groups without enlarging the image window', () {
    for (final lead in [0, 1, 2, 3, 4]) {
      final single = ReaderPreloadWindow(
          const ReaderSpreads(100, ReaderPageLayout.single), 20, 3,
          addressLead: lead);
      expect(single.targets, {for (var p = 17; p <= 23; p++) p});
      expect(
          single.addresses, {for (var p = 17 - lead; p <= 23 + lead; p++) p});
      final paired = ReaderPreloadWindow(
          const ReaderSpreads(100, ReaderPageLayout.doublePage), 20, 3,
          addressLead: lead);
      expect(paired.targets, {for (var p = 14; p <= 27; p++) p});
      expect(paired.addresses,
          {for (var p = 14 - 2 * lead; p <= 27 + 2 * lead; p++) p});
    }
  });

  test(
      'larger image windows retain link headroom without unnecessary expansion',
      () {
    for (final layout in ReaderPageLayout.values) {
      final spreads = ReaderSpreads(100, layout);
      final small = ReaderPreloadWindow(spreads, 40, 3);
      final large = ReaderPreloadWindow(spreads, 40, 4);
      expect(small.addresses, large.addresses);
      expect(small.targets.length, lessThan(large.targets.length));
      expect(small.addresses.difference(small.targets).length,
          4 * spreads.pagesPerSpread);
      expect(large.addresses.difference(large.targets).length,
          2 * spreads.pagesPerSpread);
    }
  });

  ReaderPreloadWindow window(int page, int n, {Set<int> visible = const {}}) =>
      ReaderPreloadWindow(
          const ReaderSpreads(100, ReaderPageLayout.single), page, n,
          visiblePages: visible);
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test(
      'two slots span whole jobs, nearest first; visible takeover bypasses queue',
      () async {
    final jobs = <ReaderPreloadKey, Completer<bool>>{};
    final started = <ReaderPreloadKey>[];
    final controller = ReaderPreloadController(load: (page, attempt) {
      final key = (page, attempt);
      started.add(key);
      return (jobs[key] = Completer<bool>()).future;
    });
    addTearDown(controller.dispose);
    controller.update(window(10, 3), {});
    expect(started, [(11, 0), (9, 0)]);
    controller.update(window(11, 3), {});
    expect(started.last, (12, 0));
    expect(controller.backgroundCount, 2);
    expect(started.where((k) => k == (11, 0)), hasLength(1));
    jobs[(9, 0)]!.complete(true);
    await flush();
    expect(started.last, (10, 0));
    expect(controller.backgroundCount, 2);
    controller.dispose();
    for (final job in jobs.values) {
      if (!job.isCompleted) job.complete(true);
    }
    await flush();
    expect(started, hasLength(4));
  });

  for (final jump in [false, true]) {
    test('shrinking/jumping drops only queued work (jump=$jump)', () async {
      final jobs = <int, Completer<bool>>{};
      final controller = ReaderPreloadController(
          load: (p, _) => (jobs[p] = Completer<bool>()).future);
      addTearDown(controller.dispose);
      controller.update(window(10, 5), {});
      controller.update(window(jump ? 40 : 10, 1), {});
      jobs[11]!.complete(true);
      jobs[9]!.complete(true);
      await flush();
      expect(jobs.keys.toSet(), jump ? {11, 9, 41, 39} : {11, 9});
      controller.dispose();
      for (final job in jobs.values) {
        if (!job.isCompleted) job.complete(true);
      }
    });
  }

  test('failure does not loop; retry attempt and increased N are independent',
      () async {
    final started = <ReaderPreloadKey>[];
    final controller = ReaderPreloadController(load: (p, a) async {
      started.add((p, a));
      return p != 11 || a == 1;
    });
    addTearDown(controller.dispose);
    controller.update(window(10, 1), {});
    await flush();
    for (var i = 0; i < 5; i++) controller.update(window(10, 1), {});
    expect(started, [(11, 0), (9, 0)]);
    expect(controller.failed(11, 0), true);
    controller.update(window(10, 3), {11: 1});
    await flush();
    expect(
        started, [(11, 0), (9, 0), (11, 1), (12, 0), (8, 0), (13, 0), (7, 0)]);
    expect(controller.permits(11, 1), true);
  });
}
