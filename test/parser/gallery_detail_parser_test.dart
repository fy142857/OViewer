import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/parser/gallery_detail_parser.dart';

void main() {
  for (var slot = 0; slot <= 9; slot++) {
    test('favorite slot $slot comes from sprite even with a renamed folder',
        () {
      final detail = GalleryDetailParser.parse(
          '<div id="fav"><div class="i" style="background-position:0px -${2 + slot * 19}px" title="Custom folder"></div></div>'
              '<a id="favoritelink">Custom folder</a>',
          42,
          'abc');
      expect(detail.favoritedSlot, slot);
      for (final label in ['Favorite $slot', 'Favorites $slot']) {
        expect(
            GalleryDetailParser.parse(
                    '<a id="favoritelink">$label</a>', 42, 'abc')
                .favoritedSlot,
            slot);
      }
    });
  }
  test('unfavorited and unknown folders never fabricate Favorite 0', () {
    expect(
        GalleryDetailParser.parse(
                '<a id="favoritelink">Add to Favorites</a>', 42, 'abc')
            .favoritedSlot,
        isNull);
    expect(GalleryDetailParser.parse('', 42, 'abc').favoritedSlot, isNull);
    for (final style in [
      '',
      'background-position:0px -999px',
      'background-position:0px 21px'
    ]) {
      final detail = GalleryDetailParser.parse(
          '<div id="fav"><div class="i" style="$style"></div></div><a id="favoritelink">My folder</a>',
          42,
          'abc');
      expect(detail.isFavorited, true);
      expect(detail.favoritedSlot, -1);
    }
  });

  group('GalleryDetailParser', () {
    test('parseThumbnails extracts page tokens from thumbnail links', () {
      const html = '''
      <html><body>
        <div id="gdt">
          <a href="https://e-hentai.org/s/aaa111/12345-1">
            <img src="https://thumb1.jpg" />
          </a>
          <a href="https://e-hentai.org/s/bbb222/12345-2">
            <img src="https://thumb2.jpg" />
          </a>
          <a href="https://e-hentai.org/s/ccc333/12345-3">
            <img src="https://thumb3.jpg" />
          </a>
        </div>
      </body></html>
      ''';

      final thumbs = GalleryDetailParser.parseThumbnails(html);
      expect(thumbs.length, 3);
      expect(thumbs[0].pageToken, 'aaa111');
      expect(thumbs[0].pageIndex, 0);
      expect(thumbs[1].pageToken, 'bbb222');
      expect(thumbs[1].pageIndex, 1);
      expect(thumbs[2].pageToken, 'ccc333');
      expect(thumbs[2].pageIndex, 2);
    });

    test('parse extracts basic metadata from detail page', () {
      const html = '''
      <html><body>
        <h1 id="gn">Test Gallery</h1>
        <h1 id="gj">テストギャラリー</h1>
        <div id="gd1"><img src="https://cover.jpg" /></div>
        <div id="gdc"><div>Manga</div></div>
        <div id="gdn"><a href="#">uploader_name</a></div>
        <div id="rating_label">Average: 4.25</div>
        <div id="rating_count">42</div>
        <div id="favcount">100</div>
        <table id="gdd">
          <tr><td class="gdt1">Posted:</td><td class="gdt2">2024-01-15 12:30</td></tr>
          <tr><td class="gdt1">Language:</td><td class="gdt2">Japanese</td></tr>
          <tr><td class="gdt1">Length:</td><td class="gdt2">50 pages</td></tr>
          <tr><td class="gdt1">File Size:</td><td class="gdt2">125.5 MB</td></tr>
        </table>
        <div id="taglist"></div>
        <div id="gdt"></div>
      </body></html>
      ''';

      final detail = GalleryDetailParser.parse(html, 12345, 'abc123');
      expect(detail.gid, 12345);
      expect(detail.token, 'abc123');
      expect(detail.title, 'Test Gallery');
      expect(detail.titleJpn, 'テストギャラリー');
      expect(detail.category, 'Manga');
      expect(detail.uploader, 'uploader_name');
      expect(detail.rating, 4.25);
      expect(detail.ratingCount, 42);
      expect(detail.favoriteCount, 100);
      expect(detail.language, 'Japanese');
      expect(detail.fileCount, 50);
    });

    test('parseThumbnails parses sprite mode offsets correctly', () {
      const html = '''
      <html><body>
        <div id="gdt">
          <a href="https://e-hentai.org/s/aaa111/12345-1">
            <div style="width:100px;height:145px;background:transparent url(https://ehgt.org/sprite.jpg) 0 0 no-repeat"></div>
          </a>
          <a href="https://e-hentai.org/s/bbb222/12345-2">
            <div style="width:100px;height:145px;background:transparent url(https://ehgt.org/sprite.jpg) -100px 0 no-repeat"></div>
          </a>
          <a href="https://e-hentai.org/s/ccc333/12345-3">
            <div style="width:100px;height:145px;background:transparent url(https://ehgt.org/sprite.jpg) -200px 0 no-repeat"></div>
          </a>
        </div>
      </body></html>
      ''';

      final thumbs = GalleryDetailParser.parseThumbnails(html);
      expect(thumbs.length, 3);

      // All share the same sprite URL
      expect(thumbs[0].thumbUrl, 'https://ehgt.org/sprite.jpg');
      expect(thumbs[0].isSprite, true);
      expect(thumbs[0].spriteWidth, 100);
      expect(thumbs[0].spriteHeight, 145);

      // Offsets: CSS uses negative, parser stores as positive
      expect(thumbs[0].spriteOffsetX, 0);
      expect(thumbs[0].spriteOffsetY, 0);
      expect(thumbs[1].spriteOffsetX, 100);
      expect(thumbs[1].spriteOffsetY, 0);
      expect(thumbs[2].spriteOffsetX, 200);
      expect(thumbs[2].spriteOffsetY, 0);
    });

    test('parse handles missing optional fields gracefully', () {
      const html = '<html><body></body></html>';
      final detail = GalleryDetailParser.parse(html, 1, 'token');
      expect(detail.gid, 1);
      expect(detail.title, '');
      expect(detail.titleJpn, isNull);
      expect(detail.rating, 0.0);
    });
  });
}
