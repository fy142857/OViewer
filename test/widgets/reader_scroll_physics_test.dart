import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/reader_scroll_physics.dart';

void main() {
  for (final parent in [
    const ClampingScrollPhysics(),
    const BouncingScrollPhysics()
  ]) {
    test('page snapping doubles spring frequency with $parent', () {
      final original = PageScrollPhysics(parent: parent);
      final faster =
          PageScrollPhysics(parent: ReaderScrollPhysics(parent: parent));
      final metrics = FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 1200,
          pixels: 230,
          viewportDimension: 400,
          axisDirection: AxisDirection.right,
          devicePixelRatio: 1);
      final before = original.createBallisticSimulation(metrics, 0)!;
      final after = faster.createBallisticSimulation(metrics, 0)!;
      for (final time in [0.01, 0.04, 0.08, 0.15, 0.3]) {
        expect(after.x(time), closeTo(before.x(time * 2), 0.0001));
        expect(after.dx(time), closeTo(before.dx(time * 2) * 2, 0.0001));
      }
      for (final velocity in [-1000.0, 1000.0]) {
        expect(
            faster.createBallisticSimulation(metrics, velocity)!.x(3),
            closeTo(original.createBallisticSimulation(metrics, velocity)!.x(3),
                0.01));
      }
      expect(faster.applyPhysicsToUserOffset(metrics, 40),
          original.applyPhysicsToUserOffset(metrics, 40));
    });
  }
}
