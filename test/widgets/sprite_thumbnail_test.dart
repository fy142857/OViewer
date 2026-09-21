import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';
import 'package:oviewer/widgets/sprite_thumbnail.dart';

class CountingImage extends MemoryImage {
  final List<int> loads = [0];
  CountingImage(super.bytes);

  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    loads[0]++;
    return super.loadImage(key, decode);
  }
}

Future<Uint8List> spritePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const colors = [
    Colors.red,
    Colors.yellow,
    Colors.blue,
    Colors.purple,
    Color(0xff00ff00),
    Colors.orange
  ];
  for (var i = 0; i < colors.length; i++) {
    canvas.drawRect(Rect.fromLTWH((i % 3) * 60.0, (i ~/ 3) * 90.0, 60, 90),
        Paint()..color = colors[i]);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(180, 180);
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  const greenTile = ThumbnailInfo(
      pageToken: 'a',
      pageIndex: 4,
      thumbUrl: '',
      isSprite: true,
      spriteWidth: 60,
      spriteHeight: 90,
      spriteOffsetX: 60,
      spriteOffsetY: 90);

  testWidgets(
      'portrait-landscape-portrait crops the same tile without adjacent images or another load',
      (tester) async {
    final provider = CountingImage((await tester.runAsync(spritePng))!);
    final boundaryKey = GlobalKey();
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final viewport in [
      const Size(360, 720),
      const Size(840, 360),
      const Size(360, 720)
    ]) {
      await tester.binding.setSurfaceSize(viewport);
      await tester.pumpWidget(
          MaterialApp(home: LayoutBuilder(builder: (_, constraints) {
        // Match the four-column preview grid's tile size in both orientations.
        final width = (constraints.maxWidth - 12) / 4;
        return Center(
            child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                    width: width,
                    height: width / 0.7,
                    child: SpriteThumbnail(
                        thumbnail: greenTile, image: provider))));
      })));
      await tester.runAsync(() => precacheImage(
          provider, tester.element(find.byType(SpriteThumbnail))));
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final rendered = await boundary.toImage(pixelRatio: 1);
        final rgba =
            (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        for (final x in [0.1, 0.5, 0.9]) {
          for (final y in [0.1, 0.5, 0.9]) {
            final offset = ((y * rendered.height).floor() * rendered.width +
                    (x * rendered.width).floor()) *
                4;
            expect([for (var i = 0; i < 4; i++) rgba.getUint8(offset + i)],
                [0, 255, 0, 255],
                reason:
                    'Only the selected tile should be visible at $viewport ($x, $y)');
          }
        }
        rendered.dispose();
      });
      expect(tester.takeException(), isNull);
    }
    expect(provider.loads.single, 1);
  });

  testWidgets(
      'invalid sprite dimensions show a usable fallback instead of scaling by zero',
      (tester) async {
    var retried = false;
    final provider = CountingImage(Uint8List(0));
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
                width: 220,
                height: 300,
                child: SpriteThumbnail(
                  thumbnail: const ThumbnailInfo(
                      pageToken: 'a',
                      pageIndex: 0,
                      thumbUrl: '',
                      isSprite: true),
                  image: provider,
                  errorBuilder: (_, __, ___) => TextButton(
                      onPressed: () => retried = true,
                      child: const Text('Retry')),
                )))));
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
    expect(provider.loads.single, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reader strip uses the same source crop at its smaller aspect ratio',
      (tester) async {
    final provider = CountingImage((await tester.runAsync(spritePng))!);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                    width: 36,
                    height: 52,
                    child: SpriteThumbnail(
                        thumbnail: greenTile, image: provider))))));
    await tester.runAsync(() =>
        precacheImage(provider, tester.element(find.byType(SpriteThumbnail))));
    await tester.pump();
    await tester.runAsync(() async {
      final rendered = await (boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage(pixelRatio: 1);
      final rgba =
          (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      for (final point in [
        const Offset(2, 2),
        const Offset(18, 26),
        const Offset(33, 49)
      ]) {
        final offset =
            (point.dy.toInt() * rendered.width + point.dx.toInt()) * 4;
        expect([for (var i = 0; i < 4; i++) rgba.getUint8(offset + i)],
            [0, 255, 0, 255]);
      }
      rendered.dispose();
    });
  });
}
