import 'tag_search_query.dart';

String normalizeHistoryText(String text) =>
    text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

List<String> literalHistoryMatches(String query, List<String> history) {
  final needle = normalizeHistoryText(query);
  if (needle.isEmpty) return [];
  final seen = <String>{};
  return history.where((entry) {
    final value = normalizeHistoryText(entry);
    return value.contains(needle) && seen.add(value);
  }).toList();
}

/// Built once with the dictionary, never by searching the entire dictionary
/// for each saved query. History documents are reused until their text changes.
class TagHistoryMatcher {
  final _names = <String, List<_TagNames>>{};
  int _maxWords = 1;
  Map<String, List<_HistoryTerm>> _documents = {};

  TagHistoryMatcher(Map<String, Map<String, String>> translations) {
    for (final namespace in translations.entries) {
      for (final entry in namespace.value.entries) {
        final names = {
          normalizeHistoryText(entry.key),
          ...entry.key.split('|').map(normalizeHistoryText),
          normalizeHistoryText(entry.value),
          ...entry.value
              .split(RegExp(r'[|/／、,，;；\n（）()]'))
              .map(normalizeHistoryText),
        }..remove('');
        final tag = _TagNames(
            namespace.key,
            '${namespace.key}:${normalizeHistoryText(canonicalTagKey(entry.key))}',
            names,
            [
              ...entry.value.split(RegExp(r'[|/／、,，;；\n（）()]')),
              ...entry.key.split('|'),
            ]
                .map((name) => name.trim())
                .where((name) => name.isNotEmpty)
                .toList());
        for (final name in names) {
          (_names[name] ??= []).add(tag);
          final words = name.split(' ').length;
          if (words > _maxWords) _maxWords = words;
        }
      }
    }
  }

  List<String> match(String query, List<String> history) {
    final needle = normalizeHistoryText(query);
    if (needle.isEmpty) return [];
    final queryTerms = _terms(needle);
    // Rebuild only changed entries and drop removed history; preserve ordering
    // and spelling from the caller, including a repeated search moved to top.
    final documents = <String, List<_HistoryTerm>>{};
    final result = <String>[];
    final seen = <String>{};
    for (final original in history) {
      final normalized = normalizeHistoryText(original);
      final terms =
          documents[normalized] ?? _documents[normalized] ?? _terms(normalized);
      documents[normalized] = terms;
      var semantic = false;
      final matches = normalized.contains(needle) ||
          (queryTerms.isNotEmpty &&
              queryTerms.every((queryTerm) {
                var matched = false;
                for (final term in terms) {
                  if (!queryTerm.matches(term)) continue;
                  matched = true;
                  if (term.tags.isNotEmpty || queryTerm.tags.isNotEmpty)
                    semantic = true;
                }
                return matched;
              }) &&
              semantic);
      if (matches && seen.add(normalized)) result.add(original);
    }
    _documents = documents;
    return result;
  }

  /// Display dictionary spelling, excluding names already shown in the query.
  List<String> aliasesForHistory(String query) {
    final normalized = normalizeHistoryText(query);
    final terms = _documents[normalized] ?? _terms(normalized);
    final seen = <String>{
      for (final term in terms)
        ...term.value
            .split(RegExp(r'[|/／、,，;；\n（）()]'))
            .map(normalizeHistoryText),
    };
    return [
      for (final term in terms)
        if (!term.literal)
          for (final tag in term.tags)
            for (final name in tag.displayNames)
              if (seen.add(normalizeHistoryText(name))) name,
    ];
  }

  List<_TagNames> _lookup(String name, String? namespace) => (_names[name] ??
          const <_TagNames>[])
      .where((tag) =>
          namespace == null || namespace == '*' || tag.namespace == namespace)
      .toList();

  List<_HistoryTerm> _terms(String text) {
    final prefix = RegExp(r'^[-~]?(?:weak:)?([a-z]+):').firstMatch(text)?[1];
    if (prefix == null || !_literalQualifiers.contains(prefix)) {
      // Real display names can themselves look like syntax (C:drive., P:P,
      // or a trailing $). Resolve a complete known name before stripping it.
      var fullName = text;
      var tags = _lookup(fullName, null);
      if (tags.isEmpty) {
        fullName = _unquote(text);
        tags = _lookup(fullName, null);
      }
      if (tags.isNotEmpty) return [_HistoryTerm(fullName, tags)];
    }
    final tokens = RegExp(r'(?:[^\s"]+|"[^"]*"?)+')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toList();
    final result = <_HistoryTerm>[];
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final qualified =
          RegExp(r'^([-~]?)(weak:)?([a-z]+):(.*)$').firstMatch(token);
      if (qualified != null) {
        final namespace = _namespaces[qualified[3]];
        if (namespace == null) {
          // Known search fields remain literal. Other colons can be part of a
          // dictionary name, for example Re:CREATORS or MO:OKU.
          result.add(_HistoryTerm(token, _lookup(token, null),
              literal: _literalQualifiers.contains(qualified[3])));
          continue;
        }
        final value = _unquote(qualified[4]!);
        result.add(_HistoryTerm(value, _lookup(value, namespace),
            exact: qualified[4]!.replaceAll('"', '').endsWith(r'$'),
            namespace: namespace,
            modifier:
                '${qualified[1]}${qualified[2] ?? ''}${qualified[3] == 'weak' ? 'weak:' : ''}'));
        continue;
      }
      if (token.contains(':')) {
        result.add(_HistoryTerm(token, _lookup(token, null)));
        continue;
      }
      // Resolve the longest dictionary phrase, so "nanao yukiji" is not
      // confused with an unrelated single-word tag named "nanao".
      var end = i;
      var value = _unquote(token);
      var tags = _lookup(value, null);
      final limit =
          i + _maxWords < tokens.length ? i + _maxWords : tokens.length;
      for (var j = i + 1; j < limit; j++) {
        if (tokens[j].contains(RegExp(r'[:"]')) || token.contains('"')) break;
        final phrase = tokens.sublist(i, j + 1).join(' ');
        final found = _lookup(phrase, null);
        if (found.isNotEmpty) {
          end = j;
          value = phrase;
          tags = found;
        }
      }
      result.add(_HistoryTerm(value, tags));
      i = end;
    }
    return result;
  }

  String _unquote(String value) =>
      value.replaceAll('"', '').replaceFirst(RegExp(r'\$$'), '').trim();

  static const _namespaces = {
    'artist': 'artist',
    'a': 'artist',
    'character': 'character',
    'c': 'character',
    'char': 'character',
    'cosplayer': 'cosplayer',
    'cos': 'cosplayer',
    'female': 'female',
    'f': 'female',
    'male': 'male',
    'm': 'male',
    'group': 'group',
    'g': 'group',
    'circle': 'group',
    'language': 'language',
    'l': 'language',
    'lang': 'language',
    'location': 'location',
    'loc': 'location',
    'mixed': 'mixed',
    'x': 'mixed',
    'other': 'other',
    'o': 'other',
    'parody': 'parody',
    'p': 'parody',
    'series': 'parody',
    'reclass': 'reclass',
    'r': 'reclass',
    'temp': 'temp',
    'misc': 'other',
    'tag': '*',
    'weak': '*',
  };

  static const _literalQualifiers = {
    'title',
    'uploader',
    'gid',
    'gdid',
    'comment',
    'favnote',
  };
}

class _TagNames {
  final String namespace;
  final String identity;
  final Set<String> names;
  final List<String> displayNames;
  _TagNames(this.namespace, this.identity, this.names, this.displayNames);
}

class _HistoryTerm {
  final String value;
  final List<_TagNames> tags;
  final String? namespace;
  final String modifier;
  final bool literal;
  final bool exact;
  _HistoryTerm(this.value, this.tags,
      {this.namespace,
      this.modifier = '',
      this.literal = false,
      this.exact = false});

  bool matches(_HistoryTerm history) {
    if (literal || history.literal)
      return namespace == null && history.value.contains(value);
    if (value.isEmpty) return false;
    if (namespace != null &&
        (modifier != history.modifier ||
            history.namespace != null &&
                namespace != '*' &&
                history.namespace != '*' &&
                namespace != history.namespace)) return false;
    final historical = history.tags.where((t) =>
        namespace == null || namespace == '*' || t.namespace == namespace);
    for (final tag in historical) {
      if (tag.names
              .any((name) => exact ? name == value : name.contains(value)) ||
          tags.any((other) => other.identity == tag.identity)) return true;
    }
    if (namespace != null && history.namespace == null && historical.isEmpty)
      return false;
    return exact ? history.value == value : history.value.contains(value);
  }
}
