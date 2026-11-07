import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/adaptive_thumbnail_grid.dart';

void main() {
  for (final embedded in [true, false]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'preview columns follow local width (embedded=$embedded, scale=$scale)',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(1920, 1080));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final width = ValueNotifier(320.0);
        addTearDown(width.dispose);
        int? selected;
        final pages = List.generate(30, (i) => i * 3);
        await tester.pumpWidget(MaterialApp(
            home: MediaQuery(
          data: MediaQueryData(
              size: const Size(1920, 1080), textScaleFactor: scale),
          child: Scaffold(
              body: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<double>(
                valueListenable: width,
                builder: (_, value, __) {
                  final grid = AdaptiveThumbnailGrid(
                    itemCount: pages.length,
                    shrinkWrap: embedded,
                    padding:
                        embedded ? EdgeInsets.zero : const EdgeInsets.all(8),
                    physics:
                        embedded ? const NeverScrollableScrollPhysics() : null,
                    itemBuilder: (_, index) => GestureDetector(
                        onTap: () => selected = pages[index],
                        child: ColoredBox(
                            key: ValueKey('thumb-$index'), color: Colors.blue)),
                  );
                  return SizedBox(
                      width: value,
                      child:
                          embedded ? SingleChildScrollView(child: grid) : grid);
                }),
          )),
        )));
        final cases = scale == 1
            ? <double, int>{
                80: 1,
                320: embedded ? 4 : 3,
                416: embedded ? 5 : 4,
                599: 6,
                600: 4,
                900: 6,
                1200: 8,
                1920: 13
              }
            : <double, int>{
                80: 1,
                320: 2,
                416: embedded ? 3 : 2,
                599: 3,
                600: 2,
                900: 3,
                1200: 4,
                1920: 7
              };
        for (final entry in cases.entries) {
          width.value = entry.key;
          await tester.pumpAndSettle();
          final view = tester.widget<GridView>(find.byType(GridView));
          expect(
              (view.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
                  .crossAxisCount,
              entry.value);
          final first = tester.getRect(find.byKey(const ValueKey('thumb-0')));
          expect(first.width / first.height, closeTo(0.7, 0.001));
          expect(first.width,
              lessThanOrEqualTo((entry.key >= 600 ? 150 : 100) * scale + 0.01));
          if (entry.key >= 600) {
            // Check rendered size, so merely reducing columns without making
            // the preview easier to inspect cannot satisfy the regression.
            expect(first.width, greaterThan(125 * scale));
          }
          final last =
              tester.getRect(find.byKey(ValueKey('thumb-${entry.value - 1}')));
          expect(last.top, first.top);
          expect(last.right, lessThanOrEqualTo(entry.key));
          if (entry.value > 1) {
            final second =
                tester.getRect(find.byKey(const ValueKey('thumb-1')));
            expect(second.left - first.right, closeTo(4, 0.01));
          }
          await tester.tap(find.byKey(ValueKey('thumb-${entry.value - 1}')));
          expect(selected, pages[entry.value - 1]);
          expect(tester.takeException(), isNull);
        }
        width.value = 320;
        await tester.pumpAndSettle();
        expect(
            (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                    as SliverGridDelegateWithFixedCrossAxisCount)
                .crossAxisCount,
            scale == 1 ? (embedded ? 4 : 3) : 2);
      });
    }
  }

  testWidgets('empty detail preview occupies no height', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AdaptiveThumbnailGrid(
                    itemCount: 0,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemBuilder: (_, __) =>
                        throw StateError('No thumbnail should be built'))))));
    expect(tester.getSize(find.byType(GridView)).height, 0);
    expect(tester.takeException(), isNull);
  });
}
