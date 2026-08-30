import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';
import '../../models/gallery_detail.dart';
import '../../models/gallery_tag.dart';
import '../../models/gallery_comment.dart';

class GalleryDetailParser {
  /// Parse gallery detail page HTML into GalleryDetail
  static GalleryDetail parse(String htmlString, int gid, String token) {
    final document = html_parser.parse(htmlString);

    // Title (English from #gn, Japanese from #gj)
    final title = document.querySelector('#gn')?.text.trim() ?? '';
    final titleJpnRaw = document.querySelector('#gj')?.text.trim() ?? '';
    final titleJpn = titleJpnRaw.isNotEmpty ? titleJpnRaw : null;

    // Cover thumbnail – may be an <img> or a CSS background on a child <div>
    var thumbUrl = '';
    final coverImg = document.querySelector('#gd1 img');
    if (coverImg != null) {
      final source = coverImg.attributes['src'] ?? '';
      thumbUrl = source;
    }
    if (thumbUrl.isEmpty) {
      final coverDiv = document.querySelector('#gd1 div');
      final style = coverDiv?.attributes['style'] ?? '';
      final bgMatch = RegExp(r'url\(([^)]+)\)').firstMatch(style);
      if (bgMatch != null) {
        final source =
            bgMatch.group(1)!.trim().replaceAll(RegExp(r'''['"]'''), '');
        thumbUrl = source;
      }
    }

    // Category
    final category = document.querySelector('#gdc div')?.text.trim() ??
        document.querySelector('#gdc a')?.text.trim() ??
        'Misc';

    // Uploader
    final uploader = document.querySelector('#gdn a')?.text.trim() ?? 'Unknown';

    // ---- Metadata table (#gdd) ----
    final metaRows = document.querySelectorAll('#gdd tr');
    var language = 'Japanese';
    var fileCount = 0;
    var fileSize = 0;
    String? parent;
    var visible = true;
    var postedAt = DateTime.now();

    for (final row in metaRows) {
      final label =
          (row.querySelector('.gdt1')?.text ?? '').trim().toLowerCase();
      final valueEl = row.querySelector('.gdt2');
      final value = (valueEl?.text ?? '').trim();

      if (label.contains('posted')) {
        postedAt = _parseDate(value);
      } else if (label.contains('parent')) {
        final parentLink = valueEl?.querySelector('a');
        parent = parentLink?.attributes['href'];
      } else if (label.contains('visible')) {
        visible = value.toLowerCase() != 'no';
      } else if (label.contains('language')) {
        language = value.replaceAll(RegExp(r'\s+.*'), '').trim();
      } else if (label.contains('length')) {
        fileCount = _extractInt(value);
      } else if (label.contains('file size')) {
        fileSize = _parseFileSize(value);
      }
    }

    // ---- Rating ----
    final ratingLabel =
        document.querySelector('#rating_label')?.text.trim() ?? '';
    final rating = _parseRatingFromLabel(ratingLabel);
    final ratingCount = int.tryParse(
            document.querySelector('#rating_count')?.text.trim() ?? '0') ??
        0;

    // ---- Favorites ----
    final favCountText =
        document.querySelector('#favcount')?.text.trim() ?? '0';
    final favoriteCount = _extractInt(favCountText);
    final favoritedSlot = _parseFavoritedSlot(document);

    // ---- Tags ----
    final tags = _parseTags(document);

    // ---- Comments ----
    final comments = _parseComments(document);

    // ---- Thumbnails ----
    final thumbnails = parseThumbnails(htmlString);

    // ---- Archive URL ----
    final archiveLink = document.querySelector('a[onclick*="archiver"]');
    final archiveUrl =
        archiveLink?.attributes['href'] ?? archiveLink?.attributes['onclick'];

    return GalleryDetail(
      gid: gid,
      token: token,
      title: title,
      titleJpn: titleJpn,
      thumbUrl: thumbUrl,
      category: category,
      uploader: uploader,
      postedAt: postedAt,
      parent: parent,
      visible: visible,
      language: language,
      fileCount: fileCount,
      fileSize: fileSize,
      rating: rating,
      ratingCount: ratingCount,
      favoriteCount: favoriteCount,
      favoritedSlot: favoritedSlot,
      tags: tags,
      comments: comments,
      thumbnails: thumbnails,
      archiveUrl: archiveUrl,
    );
  }

  /// Parse thumbnail page tokens for reader navigation.
  /// Each thumbnail links to /s/{pageToken}/{gid}-{pageNum}
  ///
  /// E-Hentai thumbnail modes:
  /// - **Large** (gdtl): `<a><img src="thumbUrl"></a>` — each has unique URL.
  /// - **Normal** (gt200 etc): `<a><div style="width:W;height:H;background:url(sprite) -Xpx -Ypx">`.
  ///   Multiple thumbnails share one sprite sheet; offset selects the region.
  static List<ThumbnailInfo> parseThumbnails(String htmlString) {
    final document = html_parser.parse(htmlString);
    final results = <ThumbnailInfo>[];

    final bgUrlRegex = RegExp(r'url\(([^)]+)\)');
    final offsetRegex = RegExp(r'(-?\d+)(?:px)?\s+(-?\d+)(?:px)?');
    final sizeRegex = RegExp(r'width:\s*(\d+)px.*?height:\s*(\d+)px');

    final links = document.querySelectorAll('#gdt a');
    for (final a in links) {
      final href = a.attributes['href'] ?? '';
      final tokenMatch = RegExp(r'/s/([a-f0-9]+)/(\d+)-(\d+)').firstMatch(href);
      if (tokenMatch == null) continue;

      final pageToken = tokenMatch.group(1)!;
      final pageIndex = int.parse(tokenMatch.group(3)!) - 1; // 0-based

      String thumbUrl = '';
      bool isSprite = false;
      double spriteWidth = 0;
      double spriteHeight = 0;
      double spriteOffsetX = 0;
      double spriteOffsetY = 0;

      // Try large-mode: img with a real src
      final img = a.querySelector('img');
      final imgSrc =
          img?.attributes['data-src'] ?? img?.attributes['src'] ?? '';
      if (imgSrc.isNotEmpty &&
          !imgSrc.contains('blank.gif') &&
          !imgSrc.contains('data:')) {
        thumbUrl = imgSrc;
      }

      // Normal mode: CSS background sprite on a child div inside <a>
      if (thumbUrl.isEmpty) {
        final childDiv = a.querySelector('div');
        if (childDiv != null) {
          final style = childDiv.attributes['style'] ?? '';
          final bgMatch = bgUrlRegex.firstMatch(style);
          if (bgMatch != null) {
            thumbUrl = bgMatch.group(1)!;
            isSprite = true;

            // Parse width/height
            final sizeMatch = sizeRegex.firstMatch(style);
            if (sizeMatch != null) {
              spriteWidth = double.parse(sizeMatch.group(1)!);
              spriteHeight = double.parse(sizeMatch.group(2)!);
            }

            // Parse background offset (after the URL)
            final afterUrl = style.substring(bgMatch.end);
            final offMatch = offsetRegex.firstMatch(afterUrl);
            if (offMatch != null) {
              // CSS uses negative offsets; store as positive for clipping
              spriteOffsetX = -double.parse(offMatch.group(1)!);
              spriteOffsetY = -double.parse(offMatch.group(2)!);
            }
          }
        }
      }

      results.add(ThumbnailInfo(
        pageToken: pageToken,
        pageIndex: pageIndex,
        thumbUrl: thumbUrl,
        isSprite: isSprite,
        spriteWidth: spriteWidth,
        spriteHeight: spriteHeight,
        spriteOffsetX: spriteOffsetX,
        spriteOffsetY: spriteOffsetY,
      ));
    }

    return results;
  }

  /// Parse how many thumbnail pages exist (for pagination)
  static int parseThumbnailPageCount(String htmlString) {
    final document = html_parser.parse(htmlString);
    final cells = document.querySelectorAll('table.ptt td');
    if (cells.length >= 2) {
      final secondToLast = cells[cells.length - 2];
      final link = secondToLast.querySelector('a');
      final text = link?.text.trim() ?? secondToLast.text.trim();
      return int.tryParse(text) ?? 1;
    }
    return 1;
  }

  // ---- Tag Parsing ----
  static List<GalleryTag> _parseTags(Document document) {
    final tags = <GalleryTag>[];
    final tagRows = document.querySelectorAll('#taglist tr');

    for (final row in tagRows) {
      final nsEl = row.querySelector('td.tc');
      final namespace =
          (nsEl?.text ?? 'misc').trim().replaceAll(':', '').toLowerCase();

      final tagLinks =
          row.querySelectorAll('td:last-child div a, td:last-child a');
      for (final link in tagLinks) {
        final tagKey = link.text.trim();
        if (tagKey.isEmpty) continue;

        final classes = link.className;
        tags.add(GalleryTag(
          namespace: namespace,
          key: tagKey,
          isUpvoted: classes.contains('tup'),
          isDownvoted: classes.contains('tdn'),
        ));
      }
    }

    return tags;
  }

  // ---- Comment Parsing ----
  static List<GalleryComment> _parseComments(Document document) {
    final comments = <GalleryComment>[];
    final commentDivs = document.querySelectorAll('div.c1');

    for (final div in commentDivs) {
      // ID from parent: comment_12345
      final parentId = div.parent?.attributes['id'] ?? '';
      final idMatch = RegExp(r'comment_(\d+)').firstMatch(parentId);
      final id = idMatch != null ? int.parse(idMatch.group(1)!) : 0;

      // Author & date from c3 div
      final c3 = div.querySelector('.c3');
      final c3Text = c3?.text ?? '';

      final author = c3?.querySelector('a')?.text.trim() ?? 'Anonymous';
      final dateMatch =
          RegExp(r'Posted on (.+?) (?:UTC|by)').firstMatch(c3Text);
      final postedAt = _parseDate(dateMatch?.group(1)?.trim() ?? '');

      // Comment body (HTML)
      final contentEl = div.querySelector('.c6');
      final content = contentEl?.innerHtml ?? '';

      // Score
      final scoreEl = div.querySelector('.c5 span');
      final scoreText = scoreEl?.text.trim() ?? '';
      final score = int.tryParse(scoreText.replaceAll('+', '')) ?? 0;

      // Is uploader comment
      final isUploader =
          div.querySelector('.c4')?.text.contains('Uploader') == true;

      comments.add(GalleryComment(
        id: id,
        author: author,
        postedAt: postedAt,
        content: content,
        score: score,
        isUploader: isUploader,
      ));
    }

    return comments;
  }

  // ---- Favorite slot detection ----
  static int? _parseFavoritedSlot(Document document) {
    // Check for favorited state via the #fav div or gdf id
    final favDiv = document.querySelector('#fav .i, #favoritelink');
    if (favDiv == null) return null;

    // "Add to Favorites" means not favorited
    final favText = favDiv.text.trim();
    if (favText.contains('Add to Favorites')) return null;

    // If favorited, try to determine slot from style or text
    final style = favDiv.attributes['style'] ?? '';
    final bgPos =
        RegExp(r'background-position:\s*0px\s+(-?\d+)px').firstMatch(style);
    if (bgPos != null) {
      final y = int.parse(bgPos.group(1)!).abs();
      return (y ~/ 19).clamp(0, 9);
    }

    // Already favorited but can't determine slot
    return 0;
  }

  // ---- Utilities ----
  static DateTime _parseDate(String dateStr) {
    if (dateStr.isEmpty) return DateTime.now();
    try {
      return DateTime.parse(dateStr.trim().replaceAll(' ', 'T'));
    } catch (_) {
      return DateTime.now();
    }
  }

  static double _parseRatingFromLabel(String label) {
    // "Average: 4.56" or "Not Yet Rated"
    final match = RegExp(r'([\d.]+)').firstMatch(label);
    return match != null ? (double.tryParse(match.group(1)!) ?? 0.0) : 0.0;
  }

  static int _extractInt(String text) {
    final match = RegExp(r'(\d[\d,]*)').firstMatch(text);
    if (match == null) return 0;
    return int.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0;
  }

  static int _parseFileSize(String text) {
    final match =
        RegExp(r'([\d.]+)\s*(KB|MB|GB)', caseSensitive: false).firstMatch(text);
    if (match == null) return 0;
    final value = double.parse(match.group(1)!);
    switch (match.group(2)!.toUpperCase()) {
      case 'KB':
        return (value * 1024).round();
      case 'MB':
        return (value * 1024 * 1024).round();
      case 'GB':
        return (value * 1024 * 1024 * 1024).round();
      default:
        return value.round();
    }
  }
}

class ThumbnailInfo {
  final String pageToken;
  final int pageIndex;
  final String thumbUrl;

  /// Sprite mode: the image is a sprite sheet and needs clipping.
  final bool isSprite;
  final double spriteWidth;
  final double spriteHeight;
  final double spriteOffsetX;
  final double spriteOffsetY;

  const ThumbnailInfo({
    required this.pageToken,
    required this.pageIndex,
    required this.thumbUrl,
    this.isSprite = false,
    this.spriteWidth = 0,
    this.spriteHeight = 0,
    this.spriteOffsetX = 0,
    this.spriteOffsetY = 0,
  });
}
