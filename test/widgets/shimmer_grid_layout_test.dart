import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/adaptive_gallery_grid.dart';
import 'package:oviewer/widgets/shimmer_loading.dart';

void main() {
  for (final textScale in [1.0, 2.0]) {
    testWidgets(
        'skeleton and loaded grid share geometry at text scale $textScale',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final loading = ValueNotifier(true);
      final width = ValueNotifier(320.0);
      addTearDown(loading.dispose);
      addTearDown(width.dispose);
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(
            size: const Size(1920, 1080), textScaleFactor: textScale),
        child: Scaffold(
            body: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (context, availableWidth, _) => SizedBox(
              width: availableWidth,
              child: ValueListenableBuilder<bool>(
                valueListenable: loading,
                builder: (context, pending, _) => pending
                    ? const ShimmerGalleryGrid()
                    : AdaptiveGalleryGrid(
                        itemCount: 30,
                        itemBuilder: (_, index) => SizedBox(
                            key: ValueKey('result-$index'), height: 180)),
              ),
            ),
          ),
        )),
      )));
      // Different available widths also simulate portrait/landscape and a
      // constrained panel inside a wider screen. Expectations are independent
      // of the implementation's column-count helper.
      final cases = textScale == 1
          ? <double, int>{150: 1, 320: 2, 600: 3, 900: 4, 1200: 6, 1920: 9}
          : <double, int>{150: 1, 320: 1, 600: 2, 900: 2, 1200: 3, 1920: 5};
      for (final entry in cases.entries) {
        loading.value = true;
        width.value = entry.key;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final skeleton =
            tester.widget<MasonryGridView>(find.byType(MasonryGridView));
        final delegate = skeleton.gridDelegate
            as SliverSimpleGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, entry.value);
        expect(skeleton.padding, const EdgeInsets.all(8));
        expect(skeleton.physics, isA<NeverScrollableScrollPhysics>());
        expect(skeleton.childrenDelegate.estimatedChildCount, entry.value * 3);
        final covers = find.byType(AspectRatio);
        final positions =
            List.generate(entry.value, (i) => tester.getRect(covers.at(i)));
        for (final rect in positions) {
          expect(rect.width / rect.height, closeTo(2 / 3, 0.001));
        }
        loading.value = false;
        await tester.pump();
        final results =
            tester.widget<MasonryGridView>(find.byType(MasonryGridView));
        expect(
            (results.gridDelegate
                    as SliverSimpleGridDelegateWithFixedCrossAxisCount)
                .crossAxisCount,
            entry.value);
        expect(results.physics, isA<AlwaysScrollableScrollPhysics>());
        for (var i = 0; i < entry.value; i++) {
          final rect = tester.getRect(find.byKey(ValueKey('result-$i')));
          expect(rect.left, positions[i].left);
          expect(rect.width, positions[i].width);
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('explicit skeleton item count remains supported', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ShimmerGalleryGrid(itemCount: 4))));
    expect(
        tester
            .widget<MasonryGridView>(find.byType(MasonryGridView))
            .childrenDelegate
            .estimatedChildCount,
        4);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
