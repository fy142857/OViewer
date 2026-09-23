import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/network/cookie_manager.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';
import 'package:oviewer/core/parser/gallery_list_parser.dart';
import 'package:oviewer/widgets/gallery_card.dart';
import 'package:oviewer/widgets/gallery_grid_item.dart';

class MockCookies extends Mock implements CookieManager {}

void main() {
  testWidgets('cloud favorite marker displays red hearts in list and grid',
      (tester) async {
    const url = 'https://example.test/favorite.png';
    EhImageCacheManager.init(MockCookies());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final pixels = await tester.runAsync(() => picture.toImage(1, 1));
    picture.dispose();
    PaintingBinding.instance.imageCache.putIfAbsent(
      const CachedNetworkImageProvider(url),
      () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: pixels!))),
    );
    for (final favorited in [true, false]) {
      final parsed = GalleryListParser.parse('''
        <div class="itg gld"><div>
          <a href="/g/42/abc/"><div class="glink">Gallery</div><img src="$url"></a>
          <div id="posted_42" style="${favorited ? 'background-color:rgba(0,0,0,0.1)' : ''}">2026-09-23 12:00</div>
        </div></div>''').single;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Row(children: [
        SizedBox(width: 300, height: 240, child: GalleryCard(gallery: parsed)),
        SizedBox(
            width: 200, height: 300, child: GalleryGridItem(gallery: parsed)),
      ]))));
      await tester.pumpAndSettle();
      final hearts = tester.widgetList<Icon>(find.byIcon(Icons.favorite));
      expect(hearts.length, favorited ? 2 : 0);
      expect(hearts.every((icon) => icon.color == Colors.red), isTrue);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
}
