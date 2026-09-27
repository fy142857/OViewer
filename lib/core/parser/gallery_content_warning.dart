import 'package:html/parser.dart' as html;

class GalleryContentWarning implements Exception {
  final String message;
  const GalleryContentWarning(this.message);

  static GalleryContentWarning? parse(String source, Uri gallery) {
    final document = html.parse(source);
    if (document.querySelector('#gdd') != null) return null;
    final heading = document
        .querySelectorAll('h1')
        .where((h) => h.text.trim().toLowerCase() == 'content warning');
    if (heading.isEmpty) return null;
    final hasContinue = document.querySelectorAll('a[href]').any((link) {
      final linkUri = Uri.tryParse(link.attributes['href']!);
      if (linkUri == null) return false;
      final target = gallery.resolveUri(linkUri);
      if (target.scheme != 'https' && target.scheme != 'http') return false;
      return target.origin == gallery.origin &&
          target.path == gallery.path &&
          target.queryParameters['nw'] == 'session';
    });
    if (!hasContinue) return null;
    final paragraphs = heading.first.parent?.querySelectorAll('p') ?? [];
    return GalleryContentWarning(paragraphs
        .where((p) => p.querySelector('a') == null)
        .take(2)
        .map((p) => p.text.trim())
        .join('\n\n'));
  }

  @override
  String toString() => message;
}
