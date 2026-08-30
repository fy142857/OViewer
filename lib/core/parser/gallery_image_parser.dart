import 'package:html/parser.dart' as html_parser;
import '../../models/gallery_image.dart';

class GalleryImageParser {
  /// Parse image page HTML to extract the actual image URL and metadata.
  ///
  /// Key selectors from the E-Hentai image page:
  /// - `#img` src          → the image URL (possibly resized via xres param)
  /// - `#img` style        → inline width/height for layout
  /// - `#i3 a` onclick     → `load_image(N, 'token')` for next page
  /// - `#img` onerror      → `nl('key')` for server failover
  /// - `#i2 div`           → original dimensions "W x H"
  static GalleryImage parse(String htmlString, int index) {
    final document = html_parser.parse(htmlString);

    // Main image: <img id="img" src="...">
    final imgEl = document.querySelector('#img');
    final imageSource = imgEl?.attributes['src'] ?? '';
    final imageUrl = imageSource;

    // Dimensions: prefer original size from #i2 info line ":: 1200 x 1800 ::"
    var width = 0;
    var height = 0;
    final infoDiv = document.querySelector('#i2');
    if (infoDiv != null) {
      for (final div in infoDiv.querySelectorAll('div')) {
        final dimMatch = RegExp(r'(\d+)\s*x\s*(\d+)').firstMatch(div.text);
        if (dimMatch != null) {
          width = int.parse(dimMatch.group(1)!);
          height = int.parse(dimMatch.group(2)!);
          break;
        }
      }
    }
    // Fallback: extract from #img style="width: Wpx; height: Hpx"
    if (width == 0 || height == 0) {
      final style = imgEl?.attributes['style'] ?? '';
      final wMatch = RegExp(r'width:\s*(\d+)px').firstMatch(style);
      final hMatch = RegExp(r'height:\s*(\d+)px').firstMatch(style);
      if (wMatch != null) width = int.parse(wMatch.group(1)!);
      if (hMatch != null) height = int.parse(hMatch.group(1)!);
    }

    // Navigation link for next page
    final nextLink = document.querySelector('#i3 a');
    final nextHref = nextLink?.attributes['href'] ?? '';

    // Extract nl (network location) key from onerror="... nl('key') ..."
    // Used for server failover when image load fails
    final onerror = imgEl?.attributes['onerror'] ?? '';
    final nlMatch = RegExp(r"nl\('([^']+)'\)").firstMatch(onerror);
    final nlKey = nlMatch?.group(1);

    return GalleryImage(
      index: index,
      pageUrl: nextHref,
      imageUrl: imageUrl,
      width: width,
      height: height,
      nlKey: nlKey,
    );
  }

  /// Extract the showkey variable needed for E-Hentai image API calls.
  static String? parseShowKey(String htmlString) {
    final match =
        RegExp(r'var\s+showkey\s*=\s*"([^"]+)"').firstMatch(htmlString);
    return match?.group(1);
  }

  /// Extract next page's token from the image page link.
  static String? parseNextPageToken(String htmlString) {
    final document = html_parser.parse(htmlString);
    final nextLink = document.querySelector('#i3 a');
    final href = nextLink?.attributes['href'] ?? '';
    final match = RegExp(r'/s/([a-f0-9]+)/').firstMatch(href);
    return match?.group(1);
  }

  /// Parse image URL from the E-Hentai JSON API response (showpage).
  /// The API returns: {"i":"imageUrl", "s":"showkey", ...}
  static String? parseApiImageUrl(String jsonString) {
    // Simple extraction without full JSON parse
    final match = RegExp(r'"i"\s*:\s*"([^"]+)"').firstMatch(jsonString);
    if (match == null) return null;
    return match.group(1)!.replaceAll(r'\/', '/');
  }
}
