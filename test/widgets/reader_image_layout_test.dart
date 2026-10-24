import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/reader_image_layout.dart';

void main() {
  test('height fit makes the taller equal-width page fill the viewport', () {
    final sizes = heightFittedPages([0.5, 3], const Size(800, 360));
    expect(sizes, [const Size(180, 360), const Size(180, 60)]);
    expect(
        heightFittedPages([0.5], const Size(800, 360)), [const Size(180, 360)]);
  });
  test('wide images shrink together to remain completely visible', () {
    final sizes = heightFittedPages([3, 2], const Size(800, 360));
    expect(sizes[0].width + sizes[1].width + readerSpreadGap, 800);
    expect(sizes[0].width, sizes[1].width);
    expect(sizes[1].height, lessThan(360));
    expect(sizes[0].aspectRatio, 3);
    expect(sizes[1].aspectRatio, 2);
  });
  test('horizontal landscape pages use actual image sizes and a small gutter',
      () {
    final sizes = compactHorizontalPages([0.5, 0.7], const Size(800, 360));
    expect(sizes[0], const Size(180, 360));
    expect(sizes[1].width, closeTo(252, 0.01));
    expect(sizes[1].height, 360);
    expect(sizes.fold<double>(readerSpreadGap, (w, s) => w + s.width),
        lessThan(800));
  });
}
