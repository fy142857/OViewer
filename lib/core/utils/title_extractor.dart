class TitleExtractor {
  /// A gallery title is data, not EH search syntax. Qualifying and quoting it
  /// prevents ~, -, : and short words from being interpreted as tag filters.
  static String similarSearchQuery(String title, {String? titleJpn}) {
    // Each pipe-separated title is an alternative. OR is resolved by the
    // app because the site does not support OR between title: terms.
    final seen = <String>{};
    final phrases = [title, if (titleJpn != null) titleJpn]
        .expand((value) {
          // Strip each field's author/format groups before splitting aliases;
          // pipes inside those groups are not alternative gallery titles.
          final core = extractCoreTitle(value);
          return (core.isEmpty ? value : core).split(RegExp(r'[|｜]'));
        })
        .map((part) =>
            part.replaceAll('"', ' ').replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((part) => part.isNotEmpty && seen.add(part.toLowerCase()));
    return phrases.map((phrase) => 'title:"$phrase"').join(' OR ');
  }

  /// Extracts the core title from an E-Hentai gallery title by stripping
  /// leading bracketed groups (circle/author, convention markers) and
  /// trailing bracketed groups (language, format, origin).
  ///
  /// Examples:
  ///   "(C103) [Circle (Author)] My Title (Original) [English]" → "My Title"
  ///   "[Author] Title [Spanish] [Digital]" → "Title"
  static String extractCoreTitle(String title) {
    var s = title.trim();

    // Strip leading (...) and [...] groups (handles nested brackets like [Circle (Author)])
    s = s.replaceFirst(RegExp(r'^(\s*(\([^)]*\)|\[[^\]]*\])\s*)+'), '');

    // Strip trailing (...) and [...] groups
    s = s.replaceFirst(RegExp(r'(\s*(\([^)]*\)|\[[^\]]*\])\s*)+$'), '');

    return s.trim();
  }
}
