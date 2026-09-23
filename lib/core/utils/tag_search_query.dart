/// E-Hentai displays a tag's alias after "|"; it is not part of its name.
String canonicalTagKey(String key) => key.split('|').first.trim();

String exactTagQuery(String namespace, String key) =>
    '$namespace:"${canonicalTagKey(key)}\$"';

/// Normalize only qualified tags, leaving title text and other query syntax
/// untouched. Tokenizing quotes first avoids rewriting text inside a title.
String normalizeTagSearchQuery(String query) {
  const namespaces = 'artist|a|character|c|char|cosplayer|cos|female|f|group|g|'
      'circle|language|l|lang|location|loc|male|m|mixed|x|other|o|parody|p|'
      'series|reclass|r|temp|misc|tag|weak';
  final qualified = RegExp(
    '^([-~]?(?:weak:)?(?:$namespaces):)'
    r'(?:"([^"]+)"(\$?)|([^"\s]+))$',
    caseSensitive: false,
  );
  return query.replaceAllMapped(
    RegExp(r'(?:[^\s"]+|"[^"]*"?)+'),
    (token) {
      final original = token.group(0)!;
      final match = qualified.firstMatch(original);
      if (match == null) return original;
      final value = match.group(2) ?? match.group(4)!;
      if (!value.contains('|')) return original;
      final key = canonicalTagKey(value);
      if (key.isEmpty ||
          value.split('|').last.replaceAll(r'$', '').trim().isEmpty) {
        return original;
      }
      final exact = value.trimRight().endsWith(r'$') ? r'$' : '';
      if (match.group(2) != null) {
        return '${match.group(1)}"$key$exact"${match.group(3)}';
      }
      return '${match.group(1)}$key$exact';
    },
  );
}
