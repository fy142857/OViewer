import 'package:html/parser.dart' as html;
import 'package:html/dom.dart';
import '../../repositories/auth_repository.dart';

class DawnResult {
  final bool confirmed;
  final String rewards;
  const DawnResult({this.confirmed = false, this.rewards = ''});
}

class DawnParser {
  static bool _insideUserContent(Element element) {
    for (var parent = element.parent; parent != null; parent = parent.parent) {
      if (parent.id == 'nt' ||
          parent.id == 'cdiv' ||
          parent.classes.contains('newstext')) return true;
    }
    return false;
  }

  static DawnResult parse(String source) {
    if (AuthRepository.isLoginPageHtml(source)) {
      throw const FormatException('Login required');
    }
    final doc = html.parse(source);
    final title = doc.querySelector('title')?.text.toLowerCase() ?? '';
    if (title.contains('just a moment') ||
        title.contains('attention required') ||
        doc.querySelector('#challenge-form, #cf-challenge-running') != null) {
      throw const FormatException('Verification required');
    }
    final pane = doc.querySelector('#eventpane');
    if (pane != null && pane.parent != null && !_insideUserContent(pane)) {
      pane.querySelectorAll('script, style, a').forEach((e) => e.remove());
      pane.querySelectorAll('br').forEach((e) => e.replaceWith(Text('\n')));
      pane.querySelectorAll('p').forEach((e) => e.append(Text('\n')));
      final text = pane.text.replaceAll(RegExp(r'[ \t\r]+'), ' ').trim();
      final dawn =
          RegExp(r'^It is the dawn of a new day[!.]?', caseSensitive: false);
      if (dawn.hasMatch(text)) {
        return DawnResult(
            confirmed: true, rewards: text.replaceFirst(dawn, '').trim());
      }
    }
    // Normal news pages can omit the event even after rewards were granted.
    if (doc.querySelector('#newsinner #nt') != null &&
        doc.querySelector('#nb a[href="https://e-hentai.org/"]') != null) {
      return const DawnResult();
    }
    throw const FormatException('Unrecognized check-in response');
  }
}
