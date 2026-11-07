import 'package:flutter/services.dart';
import '../../repositories/tag_translation_repository.dart';
import 'tag_search_query.dart';
import 'tag_history_matcher.dart';

/// A suggestion owns the same text range that was used to find its tag.
class TagSuggestion {
  final TagSearchResult tag;
  final TextRange range;
  final String source;

  const TagSuggestion(this.tag, this.range, this.source);

  TextEditingValue apply() {
    final replacement = exactTagQuery(tag.namespace, tag.key);
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

/// History is already stored newest first. Match and deduplicate without
/// changing the user's saved text or ordering.
List<String> matchingSearchHistory(String query, List<String> history,
        {TagHistoryMatcher? aliases}) =>
    aliases?.match(query, history) ?? literalHistoryMatches(query, history);

/// Complete the current term while retaining already entered filters. Full
/// query history has precedence when the same entry matches both searches.
Map<String, TextEditingValue> searchHistoryCompletions(
    TextEditingValue value, List<String> history,
    {TagHistoryMatcher? aliases}) {
  if (!value.composing.isCollapsed) return {};
  final result = <String, TextEditingValue>{};
  void addMatches(String query, int start, int end) {
    for (final entry
        in matchingSearchHistory(query, history, aliases: aliases)) {
      result.putIfAbsent(entry, () {
        final replacement =
            end == value.text.length ? '${entry.trimRight()} ' : entry;
        final text = value.text.replaceRange(start, end, replacement);
        return TextEditingValue(
            text: text,
            selection:
                TextSelection.collapsed(offset: start + replacement.length));
      });
    }
  }

  addMatches(value.text, 0, value.text.length);
  final selection = value.selection;
  if (!selection.isValid || selection.end > value.text.length) return result;
  if (!selection.isCollapsed) {
    addMatches(value.text.substring(selection.start, selection.end),
        selection.start, selection.end);
    return result;
  }
  final tokens =
      RegExp(r'(?:[^\s"]+|"[^"]*"?)+').allMatches(value.text).toList();
  final cursor = selection.extentOffset;
  final active = tokens.indexWhere((t) => t.start < cursor && cursor <= t.end);
  if (active > 0) {
    final token = tokens[active];
    addMatches(
        value.text.substring(token.start, cursor), token.start, token.end);
  }
  return result;
}

/// Try the longest plain-text phrase ending at the caret first. Quoted tags
/// and scoped search terms form boundaries, so existing filters stay intact.
List<TagSuggestion> tagSuggestions(
  TextEditingValue value,
  List<TagSearchResult> Function(String) search, {
  TagPhraseMatch? Function(List<String>)? searchPhrases,
}) {
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
  if (searchPhrases != null) {
    final queries = [
      for (var i = first; i <= active; i++)
        text
            .substring(tokens[i].start, cursor)
            .trim()
            .replaceAll(RegExp(r'\s+'), ' '),
    ];
    final result = searchPhrases(queries);
    if (result == null) return [];
    final range = TextRange(
        start: tokens[first + result.queryIndex].start,
        end: tokens[active].end);
    return result.tags.map((tag) => TagSuggestion(tag, range, text)).toList();
  }
  for (var i = first; i <= active; i++) {
    final results = match(tokens[i].start, cursor, tokens[active].end);
    if (results.isNotEmpty) return results;
  }
  return [];
}
