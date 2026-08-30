import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart';
import '../../models/gallery_preview.dart';

class GalleryListParser {
  static final _galleryUrlRegex = RegExp(r'/g/(\d+)/([a-f0-9]+)/');

  /// Parse gallery list page HTML into a list of GalleryPreview.
  /// Handles Extended, Compact, Minimal, and Thumbnail display modes.
  static List<GalleryPreview> parse(String htmlString) {
    final document = html_parser.parse(htmlString);
    final galleries = <GalleryPreview>[];

    // Strategy 1: Extended mode (table.itg.glte) - most common default
    var rows = document.querySelectorAll('table.itg.glte > tbody > tr');
    if (rows.isNotEmpty) {
      for (final row in rows) {
        final g = _parseExtendedRow(row);
        if (g != null) galleries.add(g);
      }
      return galleries;
    }

    // Strategy 2: Compact mode (table.itg.gltc)
    rows = document.querySelectorAll('table.itg.gltc > tbody > tr');
    if (rows.isNotEmpty) {
      for (final row in rows.skip(1)) {
        // skip header row
        final g = _parseCompactRow(row);
        if (g != null) galleries.add(g);
      }
      return galleries;
    }

    // Strategy 3: Minimal / Minimal+ mode (table.itg.gltm)
    rows = document.querySelectorAll('table.itg.gltm > tbody > tr');
    if (rows.isNotEmpty) {
      for (final row in rows.skip(1)) {
        final g = _parseMinimalRow(row);
        if (g != null) galleries.add(g);
      }
      return galleries;
    }

    // Strategy 4: Thumbnail mode (div.itg.gld)
    final thumbDivs = document.querySelectorAll('div.itg.gld > div');
    if (thumbDivs.isNotEmpty) {
      for (final div in thumbDivs) {
        final g = _parseThumbnailItem(div);
        if (g != null) galleries.add(g);
      }
      return galleries;
    }

    // Fallback: generic - find all gallery links
    final allLinks = document.querySelectorAll('a[href*="/g/"]');
    final seen = <int>{};
    for (final link in allLinks) {
      final href = link.attributes['href'] ?? '';
      final match = _galleryUrlRegex.firstMatch(href);
      if (match == null) continue;
      final gid = int.parse(match.group(1)!);
      if (seen.contains(gid)) continue;
      seen.add(gid);

      final title =
          link.querySelector('.glink')?.text.trim() ?? link.text.trim();
      if (title.isEmpty) continue;

      // Try to find thumbnail near this link
      final parent = link.parent;
      final img = parent?.querySelector('img') ?? link.querySelector('img');
      final thumbUrl = _extractImgSrc(img);

      galleries.add(GalleryPreview(
        gid: gid,
        token: match.group(2)!,
        title: title,
        thumbUrl: thumbUrl,
        category: 'Misc',
        rating: 0.0,
        uploader: '',
        fileCount: 0,
        postedAt: DateTime.now(),
      ));
    }

    return galleries;
  }

  /// Parse the "next page" URL from the pagination HTML.
  /// Supports both E-Hentai (`table.ptt`) and ExHentai (`div.searchnav`).
  /// Returns the full/relative URL, or null if on the last page.
  static String? parseNextPageUrl(String htmlString) {
    final document = html_parser.parse(htmlString);

    // === Strategy 1: table.ptt (E-Hentai standard) ===
    final ptt = document.querySelector('table.ptt');
    if (ptt != null) {
      // 1a: <a id="unext"> is the "next" button
      final unext = ptt.querySelector('a#unext');
      if (unext != null) {
        final href = unext.attributes['href'];
        if (href != null && href.isNotEmpty) return href;
      }

      // 1b: Ehviewer approach — last <td>'s <a> in the row
      final tds = ptt.querySelectorAll('td');
      if (tds.isNotEmpty) {
        final lastTd = tds.last;
        final lastLink = lastTd.querySelector('a');
        if (lastLink != null) {
          final href = lastLink.attributes['href'];
          if (href != null && href.isNotEmpty) {
            // Verify this is the "next" link, not the current page
            final text = lastLink.text.trim();
            if (text == '>' ||
                text == '\u203A' ||
                text.contains('Next') ||
                RegExp(r'page=\d+').hasMatch(href)) {
              return href;
            }
          }
        }
      }

      // 1c: Any <a> with text ">" in the ptt table
      for (final link in ptt.querySelectorAll('a')) {
        final text = link.text.trim();
        if (text == '>' || text == '\u203A') {
          final href = link.attributes['href'];
          if (href != null && href.isNotEmpty) return href;
        }
      }
    }

    // === Strategy 2: div.searchnav (ExHentai cursor-based) ===
    final searchNav = document.querySelector('.searchnav');
    if (searchNav != null) {
      final unext = searchNav.querySelector('#unext');
      if (unext != null) {
        final href = unext.attributes['href'];
        if (href != null && href.isNotEmpty) return href;
      }
    }

    // === Strategy 3: Any element with id="unext" anywhere ===
    final globalUnext = document.querySelector('#unext');
    if (globalUnext != null) {
      final href = globalUnext.attributes['href'];
      if (href != null && href.isNotEmpty) return href;
    }

    // === Strategy 4: Find next page link from any pagination-like structure ===
    // Look for links containing page= or next= parameters
    final currentPage = _extractCurrentPage(document);
    if (currentPage != null) {
      final nextPageNum = currentPage + 1;
      for (final link in document.querySelectorAll('a[href]')) {
        final href = link.attributes['href'] ?? '';
        final pageMatch = RegExp(r'[?&]page=(\d+)').firstMatch(href);
        if (pageMatch != null) {
          final p = int.parse(pageMatch.group(1)!);
          if (p == nextPageNum) return href;
        }
      }
    }

    return null;
  }

  /// Extract the current page number from the HTML document.
  static int? _extractCurrentPage(Document document) {
    // From table.ptt: the <td> with class "ptds" (selected page)
    final selected = document.querySelector('table.ptt td.ptds a');
    if (selected != null) {
      final num = int.tryParse(selected.text.trim());
      if (num != null) return num - 1; // pages are 0-indexed in URLs
    }

    // From URL-like patterns in the page
    final canonLink = document.querySelector('link[rel="canonical"]');
    if (canonLink != null) {
      final href = canonLink.attributes['href'] ?? '';
      final pageMatch = RegExp(r'[?&]page=(\d+)').firstMatch(href);
      if (pageMatch != null) return int.parse(pageMatch.group(1)!);
    }

    return null;
  }

  /// Parse total page count from the pagination HTML.
  /// Returns the number of pages, or -1 if pagination is cursor-based
  /// (ExHentai searchnav), or 0 if no pagination found.
  static int parsePageCount(String htmlString) {
    final document = html_parser.parse(htmlString);

    // === table.ptt based page count ===
    final cells = document.querySelectorAll('table.ptt td');
    if (cells.length >= 2) {
      // The second-to-last cell typically has the last page number;
      // the very last cell is the ">" (next) button.
      final secondToLast = cells[cells.length - 2];
      final link = secondToLast.querySelector('a');
      final text = link?.text.trim() ?? secondToLast.text.trim();
      final num = int.tryParse(text);
      if (num != null) return num;
    }

    // Find the highest page= value in any pagination link
    final pttLinks = document.querySelectorAll('table.ptt a[href]');
    int maxPage = -1;
    for (final link in pttLinks) {
      final href = link.attributes['href'] ?? '';
      final pageMatch = RegExp(r'[?&]page=(\d+)').firstMatch(href);
      if (pageMatch != null) {
        final p = int.parse(pageMatch.group(1)!);
        if (p > maxPage) maxPage = p;
      }
    }
    if (maxPage >= 0) return maxPage + 1; // page is 0-based

    // === searchnav based (ExHentai cursor pagination) ===
    final searchNav = document.querySelector('.searchnav');
    if (searchNav != null) {
      // Cursor-based: total pages unknown, return -1
      return -1;
    }

    // Broad search across all links
    final allLinks = document.querySelectorAll('a[href*="page="]');
    for (final link in allLinks) {
      final href = link.attributes['href'] ?? '';
      final pageMatch = RegExp(r'[?&]page=(\d+)').firstMatch(href);
      if (pageMatch != null) {
        final p = int.parse(pageMatch.group(1)!);
        if (p > maxPage) maxPage = p;
      }
    }
    if (maxPage >= 0) return maxPage + 1;

    // No pagination found — still at least 1 page (the current one)
    return 1;
  }

  // ---- Extended Mode ----
  static GalleryPreview? _parseExtendedRow(Element row) {
    try {
      // Find gallery link
      final link = row.querySelector('a[href*="/g/"]');
      if (link == null) return null;
      final parsed = _parseGalleryUrl(link.attributes['href'] ?? '');
      if (parsed == null) return null;

      final title = row.querySelector('.glink')?.text.trim() ?? '';
      if (title.isEmpty) return null;

      // Thumbnail: in gl1e td
      final img = row.querySelector('td.gl1e img, .glthumb img, img');
      final thumbUrl = _extractImgSrc(img);

      // Right column info (gl3e): category, date, rating, uploader, pages
      final infoDiv = row.querySelector('td.gl3e');
      final infoDivs = infoDiv?.querySelectorAll('div') ?? [];

      var category = 'Misc';
      var uploader = '';
      var postedAt = DateTime.now();
      var rating = 0.0;

      for (final div in infoDivs) {
        final cls = div.className;
        final text = div.text.trim();

        if (cls.contains('cn') || cls.contains('cs')) {
          category = text;
        } else if (cls.contains('ir')) {
          rating = parseRating(div.attributes['style'] ?? '');
        } else if (RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(text)) {
          postedAt = _parseDate(text);
        } else if (div.querySelector('a') != null) {
          uploader = div.querySelector('a')?.text.trim() ?? '';
        }
      }

      // Page count, language, posted date via robust extraction
      final fileCount = _extractFileCount(row);
      final language = _extractLanguage(row);
      postedAt = _extractPostedAt(row, parsed.$1);

      // Also try uploader from outside gl3e
      if (uploader.isEmpty) {
        uploader = row.querySelector('a[href*="uploader"]')?.text.trim() ?? '';
      }

      return GalleryPreview(
        gid: parsed.$1,
        token: parsed.$2,
        title: title,
        thumbUrl: thumbUrl,
        category: category,
        rating: rating,
        uploader: uploader,
        fileCount: fileCount,
        language: language,
        postedAt: postedAt,
        tags: _extractTags(row),
      );
    } catch (_) {
      return null;
    }
  }

  // ---- Compact Mode ----
  static GalleryPreview? _parseCompactRow(Element row) {
    try {
      final tds = row.querySelectorAll('td');
      if (tds.length < 3) return null;

      // Gallery link with title
      final link = row.querySelector('a[href*="/g/"]');
      if (link == null) return null;
      final parsed = _parseGalleryUrl(link.attributes['href'] ?? '');
      if (parsed == null) return null;

      final title = row.querySelector('.glink')?.text.trim() ?? '';

      // Thumbnail
      final img = row.querySelector('.glthumb img, img');
      final thumbUrl = _extractImgSrc(img);

      // Category
      final catEl = row.querySelector('.cn, .cs');
      final category = catEl?.text.trim() ?? 'Misc';

      // Rating
      final ratingEl = row.querySelector('.ir');
      final rating = parseRating(ratingEl?.attributes['style'] ?? '');

      // Page count, language, posted date via robust extraction
      final fileCount = _extractFileCount(row);
      final language = _extractLanguage(row);

      // Date & uploader
      var uploader = '';
      final postedAt = _extractPostedAt(row, parsed.$1);

      uploader = row
              .querySelector('td:last-child a, a[href*="uploader"]')
              ?.text
              .trim() ??
          '';

      return GalleryPreview(
        gid: parsed.$1,
        token: parsed.$2,
        title: title,
        thumbUrl: thumbUrl,
        category: category,
        rating: rating,
        uploader: uploader,
        fileCount: fileCount,
        language: language,
        postedAt: postedAt,
        tags: _extractTags(row),
      );
    } catch (_) {
      return null;
    }
  }

  // ---- Minimal Mode ----
  static GalleryPreview? _parseMinimalRow(Element row) {
    try {
      final link = row.querySelector('a[href*="/g/"]');
      if (link == null) return null;
      final parsed = _parseGalleryUrl(link.attributes['href'] ?? '');
      if (parsed == null) return null;

      final title =
          row.querySelector('.glink')?.text.trim() ?? link.text.trim();

      final img = row.querySelector('img');
      final thumbUrl = _extractImgSrc(img);

      final catEl = row.querySelector('.cn, .cs');
      final category = catEl?.text.trim() ?? 'Misc';

      final ratingEl = row.querySelector('.ir');
      final rating = parseRating(ratingEl?.attributes['style'] ?? '');

      // Page count, language, posted date via robust extraction
      final fileCount = _extractFileCount(row);
      final language = _extractLanguage(row);
      final postedAt = _extractPostedAt(row, parsed.$1);

      return GalleryPreview(
        gid: parsed.$1,
        token: parsed.$2,
        title: title,
        thumbUrl: thumbUrl,
        category: category,
        rating: rating,
        uploader: '',
        fileCount: fileCount,
        language: language,
        postedAt: postedAt,
        tags: _extractTags(row),
      );
    } catch (_) {
      return null;
    }
  }

  // ---- Thumbnail Mode ----
  static GalleryPreview? _parseThumbnailItem(Element div) {
    try {
      final link = div.querySelector('a[href*="/g/"]');
      if (link == null) return null;
      final parsed = _parseGalleryUrl(link.attributes['href'] ?? '');
      if (parsed == null) return null;

      final title = div.querySelector('.glink')?.text.trim() ?? '';
      final img = div.querySelector('img');
      final thumbUrl = _extractImgSrc(img);

      final catEl = div.querySelector('.cn, .cs');
      final category = catEl?.text.trim() ?? 'Misc';

      // Page count, language, posted date via robust extraction
      final fileCount = _extractFileCount(div);
      final language = _extractLanguage(div);
      final postedAt = _extractPostedAt(div, parsed.$1);

      return GalleryPreview(
        gid: parsed.$1,
        token: parsed.$2,
        title: title,
        thumbUrl: thumbUrl,
        category: category,
        rating: 0.0,
        uploader: '',
        fileCount: fileCount,
        language: language,
        postedAt: postedAt,
        tags: _extractTags(div),
      );
    } catch (_) {
      return null;
    }
  }

  // ---- Utilities ----

  static (int, String)? _parseGalleryUrl(String href) {
    final match = _galleryUrlRegex.firstMatch(href);
    if (match == null) return null;
    return (int.parse(match.group(1)!), match.group(2)!);
  }

  static String _extractImgSrc(Element? img) {
    if (img == null) return '';
    final url = img.attributes['data-src'] ?? img.attributes['src'] ?? '';
    return url;
  }

  /// Parse E-Hentai star rating from inline CSS style.
  /// The rating sprite uses 16px per star, with y=-1px for full stars
  /// and y=-21px for half-star offset.
  static double parseRating(String style) {
    final match = RegExp(r'background-position:\s*(-?\d+)px\s+(-?\d+)px')
        .firstMatch(style);
    if (match == null) return 0.0;

    final x = int.parse(match.group(1)!);
    final y = int.parse(match.group(2)!);

    // x offset: 0px=5stars, -16px=4stars, -32px=3stars, -48px=2stars, -64px=1star, -80px=0stars
    double rating = 5.0 + x / 16.0;
    // y=-21px means subtract half a star
    if (y == -21) rating -= 0.5;

    return rating.clamp(0.0, 5.0);
  }

  static int extractInt(String text) {
    final match = RegExp(r'(\d[\d,]*)').firstMatch(text);
    if (match == null) return 0;
    return int.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0;
  }

  /// Regex matching "N page" or "N pages" (same as EhViewer's PATTERN_PAGES).
  static final _pagesPattern = RegExp(r'(\d[\d,]*)\s*page');

  /// Extract page count from text containing "N page(s)".
  /// Matches both singular "1 page" and plural "123 pages".
  static int extractPageCount(String text) {
    final match = _pagesPattern.firstMatch(text);
    if (match != null) {
      return int.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0;
    }
    return 0;
  }

  /// Extract page count from an element by locating td.gl4c which contains
  /// uploader and "NN pages" divs in every gallery row.
  static int _extractFileCount(Element element) {
    // Primary: td.gl4c > div with "page" text
    final gl4c = element.querySelector('td.gl4c');
    if (gl4c != null) {
      for (final div in gl4c.querySelectorAll('div')) {
        final text = div.text.trim();
        if (text.contains('page')) {
          final count = extractPageCount(text);
          if (count > 0) return count;
        }
      }
    }

    // Strategy 2: sibling div right after .ir rating div (favorites page)
    final irDiv = element.querySelector('.ir');
    if (irDiv != null) {
      final next = irDiv.nextElementSibling;
      if (next != null && next.text.contains('page')) {
        final count = extractPageCount(next.text);
        if (count > 0) return count;
      }
    }

    // Fallback: search entire row for "N page(s)" pattern
    final allText = element.text;
    if (allText.contains('page')) {
      return extractPageCount(allText);
    }

    return 0;
  }

  /// Language abbreviation mapping.
  static const _langMap = {
    'japanese': null, // don't display
    'english': 'EN',
    'chinese': 'ZH',
    'korean': 'KO',
    'french': 'FR',
    'spanish': 'ES',
    'german': 'DE',
    'russian': 'RU',
    'thai': 'TH',
    'vietnamese': 'VI',
    'portuguese': 'PT',
    'italian': 'IT',
    'dutch': 'NL',
    'polish': 'PL',
    'hungarian': 'HU',
    'czech': 'CS',
    'arabic': 'AR',
    'turkish': 'TR',
  };

  /// Extract all tags from an element's div.gt[title] and div.gtl[title] elements.
  /// Returns a list of tag strings (e.g., "language:chinese", "other:ai generated").
  static List<String> _extractTags(Element element) {
    final tagElements =
        element.querySelectorAll('div.gt[title], div.gtl[title]');
    final tags = <String>[];
    for (final el in tagElements) {
      final title = el.attributes['title']?.trim();
      if (title != null && title.isNotEmpty) {
        tags.add(title);
      }
    }
    return tags;
  }

  /// Extract language from div.gt[title^="language:"] tag element.
  static String? _extractLanguage(Element element) {
    final langTag = element.querySelector(
        'div.gt[title^="language:"], div.gtl[title^="language:"]');
    if (langTag == null) return null;
    final title = langTag.attributes['title'] ?? '';
    // title format: "language:english"
    final lang = title.replaceFirst('language:', '').trim().toLowerCase();
    return _langMap[lang];
  }

  /// Extract posted date from div#posted_{gid}.
  static DateTime _extractPostedAt(Element element, int gid) {
    final postedDiv = element.querySelector('#posted_$gid');
    if (postedDiv != null) {
      return _parseDate(postedDiv.text.trim());
    }
    // Fallback: try date pattern in text
    final dateMatch =
        RegExp(r'\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}').firstMatch(element.text);
    if (dateMatch != null) {
      return _parseDate(dateMatch.group(0)!);
    }
    return DateTime.now();
  }

  static DateTime _parseDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return DateTime.now();
    try {
      // E-Hentai format: "2024-01-15 12:30"
      return DateTime.parse(dateStr.trim().replaceAll(' ', 'T'));
    } catch (_) {
      return DateTime.now();
    }
  }
}
