class TitleExtractor {
  /// A gallery title is data, not EH search syntax. Qualifying and quoting it
  /// prevents ~, -, : and short words from being interpreted as tag filters.
  static String similarSearchQuery(String title) {
    final core = extractCoreTitle(title);
    final phrase = (core.isEmpty ? title : core)
        .replaceAll('"', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return phrase.isEmpty ? '' : 'title:"$phrase"';
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
