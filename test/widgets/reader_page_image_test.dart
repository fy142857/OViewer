import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/reader_page_image.dart';

class PendingCompleter extends ImageStreamCompleter {
  void complete(ui.Image image) => setImage(ImageInfo(image: image));
  void progress() => reportImageChunkEvent(const ImageChunkEvent(
      cumulativeBytesLoaded: 100, expectedTotalBytes: 100));
  void fail() =>
      reportError(exception: StateError('stalled decode'), silent: true);
}

class PendingImage extends ImageProvider<PendingImage> {
  final PendingCompleter completer = PendingCompleter();
  @override
  Future<PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          PendingImage key, ImageDecoderCallback decode) =>
      completer;
}

void main() {
  testWidgets(
      'no byte progress or completed download stays loading until first frame; failures can retry',
      (tester) async {
    final first = PendingImage();
    final second = PendingImage();
    var current = first;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      backgroundColor: Colors.black,
      body: StatefulBuilder(
          builder: (context, setState) => ReaderPageImage(
                image: current,
                errorBuilder: (_, __, ___) => TextButton(
                    onPressed: () => setState(() => current = second),
                    child: const Text('Retry')),
              )),
    )));
    await tester.pump();
    // No chunk event: waiting for HTTP headers or a cache read cannot be blank.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    first.completer.progress();
    await tester.pump();
    // Download completion still isn't a decoded frame.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    first.completer.fail();
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(2, 2));
    picture.dispose();
    second.completer.complete(image!);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}
