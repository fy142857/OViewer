import 'package:flutter/services.dart';
import '../../repositories/tag_translation_repository.dart';

/// A suggestion owns the same text range that was used to find its tag.
class TagSuggestion {
  final TagSearchResult tag;
  final TextRange range;
  final String source;

  const TagSuggestion(this.tag, this.range, this.source);

  TextEditingValue apply() {
    final replacement = '${tag.namespace}:"${tag.key}\$"';
    final suffix = source.substring(range.end);
    final separator = suffix.isEmpty ? ' ' : '';
    final text =
        source.replaceRange(range.start, range.end, '$replacement$separator');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
          offset: range.start + replacement.length + separator.length),
    );
  }
}

/// Try the longest plain-text phrase ending at the caret first. Quoted tags
/// and scoped search terms form boundaries, so existing filters stay intact.
List<TagSuggestion> tagSuggestions(
  TextEditingValue value,
  List<TagSearchResult> Function(String) search,
) {
  final text = value.text;
  final selection = value.selection;
  if (!selection.isValid || selection.end > text.length) return [];
  if (!value.composing.isCollapsed) return [];

  List<TagSuggestion> match(int start, int queryEnd, int replaceEnd) {
    final query =
        text.substring(start, queryEnd).trim().replaceAll(RegExp(r'\s+'), ' ');
    if (query.isEmpty) return [];
    return search(query)
        .map((tag) =>
            TagSuggestion(tag, TextRange(start: start, end: replaceEnd), text))
        .toList();
  }

  if (!selection.isCollapsed) {
    return match(selection.start, selection.end, selection.end);
  }

  final cursor = selection.extentOffset;
  // Keep spaces inside quotes in one token, including unfinished quotes.
  final tokens = RegExp(r'(?:[^\s"]+|"[^"]*"?)+').allMatches(text).toList();
  final active = tokens.indexWhere((t) => t.start < cursor && cursor <= t.end);
  if (active < 0) return [];
  bool isPlain(RegExpMatch token) {
    final term = token.group(0)!;
    return !term.contains(RegExp(r'[:"]')) &&
        !term.startsWith('-') &&
        !term.startsWith('~');
  }

  if (!isPlain(tokens[active])) return [];
  var first = active;
  while (first > 0 && isPlain(tokens[first - 1])) {
    first--;
  }
  for (var i = first; i <= active; i++) {
    final results = match(tokens[i].start, cursor, tokens[active].end);
    if (results.isNotEmpty) return results;
  }
  return [];
}
