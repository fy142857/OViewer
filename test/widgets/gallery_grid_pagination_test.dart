import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/adaptive_gallery_grid.dart';

void main() {
  for (final width in [360.0, 600.0, 900.0]) {
    testWidgets('page append keeps row order at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final count = ValueNotifier(5);
      final controller = ScrollController();
      addTearDown(count.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: count,
            builder: (_, length, __) => AdaptiveGalleryGrid(
              controller: controller,
              itemCount: length,
              itemBuilder: (_, index) => SizedBox(
                key: ValueKey(index),
                height: index.isEven ? 180 : 120,
                child: Text('Gallery $index'),
              ),
            ),
          ),
        ),
      ));
      final columns = width == 360 ? 2 : (width == 600 ? 3 : 4);
      void expectRowOrder(int length) {
        for (var index = 0; index < length; index++) {
          final tile = find.byKey(ValueKey(index));
          if (tile.evaluate().isEmpty) continue;
          final rect = tester.getRect(tile);
          final previous = find.byKey(ValueKey(index - 1));
          if (index == 0 || previous.evaluate().isEmpty) continue;
          final before = tester.getRect(previous);
          if (index % columns == 0) {
            expect(rect.top, greaterThanOrEqualTo(before.bottom + 8));
            expect(rect.left, 8);
          } else {
            expect(rect.top, before.top, reason: 'row at item $index');
            expect(rect.left, greaterThan(before.left));
          }
        }
      }

      expectRowOrder(5);
      // An incomplete last row must fill in place, including repeated pages.
      for (final length in [12, 23, 40]) {
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pump();
        final offset = controller.offset;
        count.value = length;
        await tester.pump();
        expect(controller.offset, offset);
        expectRowOrder(length);
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pump();
        expectRowOrder(length);
      }
      controller.jumpTo(0);
      await tester.pump();
      expectRowOrder(40);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('footer stays below all cards through loading, retry and refresh',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final count = ValueNotifier(3);
    final footer = ValueNotifier<String?>('Loading');
    addTearDown(count.dispose);
    addTearDown(footer.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (_, length, __) => ValueListenableBuilder<String?>(
            valueListenable: footer,
            builder: (_, label, __) => AdaptiveGalleryGrid(
              itemCount: length,
              itemBuilder: (_, index) => SizedBox(
                  key: ValueKey(index), height: index.isEven ? 120 : 160),
              footer: label == null
                  ? null
                  : SizedBox(
                      key: const ValueKey('footer'),
                      height: 60,
                      child: Center(child: Text(label)),
                    ),
            ),
          ),
        ),
      ),
    ));
    final lastPosition = tester.getTopLeft(find.byKey(const ValueKey(2)));
    for (final label in ['Retry', 'Loading']) {
      footer.value = label;
      await tester.pump();
      final rect = tester.getRect(find.byKey(const ValueKey('footer')));
      expect(rect.left, 0);
      expect(rect.width, 360);
      expect(
          rect.top,
          greaterThanOrEqualTo(
              tester.getBottomLeft(find.byKey(const ValueKey(2))).dy));
      expect(tester.getTopLeft(find.byKey(const ValueKey(2))), lastPosition);
    }
    count.value = 4;
    footer.value = null;
    await tester.pump();
    expect(find.byKey(const ValueKey('footer')), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey(2))), lastPosition);
    expect(
        tester.getTopLeft(find.byKey(const ValueKey(3))).dy, lastPosition.dy);
    count.value = 0;
    await tester.pump();
    expect(find.byKey(const ValueKey(0)), findsNothing);
    expect(tester.takeException(), isNull);
    footer.value = 'Loading';
    await tester.pump();
    expect(find.text('Loading'), findsOneWidget);
    count.value = 1;
    footer.value = null;
    await tester.pump();
    expect(
        tester.getTopLeft(find.byKey(const ValueKey(0))), const Offset(8, 8));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
