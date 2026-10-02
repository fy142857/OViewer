import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/storage/tag_translation_cache.dart';
import 'package:logger/logger.dart';
import '../core/network/dio_client.dart';
import '../core/constants/api_endpoints.dart';
import '../core/storage/local_storage.dart';

class TagTranslationRepository extends ChangeNotifier {
  static final _log = Logger();
  final DioClient _dio;
  final LocalStorage _storage;

  /// namespace -> { tagKey -> translatedName }
  Map<String, Map<String, String>> _translations = {};
  bool _loaded = false;
  List<_SearchEntry> _searchEntries = [];

  final TagTranslationCache _cache;
  Future<void>? _loading;
  Future<void>? _refreshing;
  bool _disposed = false;
  TagTranslationRepository(this._dio, this._storage,
      {TagTranslationCache? cache})
      : _cache = cache ?? TagTranslationCache();

  bool get isLoaded => _loaded;

  Future<void> loadTranslations() => _loading ??= _load();

  Future<void> _load() async {
    String? stored;
    try {
      stored = await _cache.read();
    } catch (_) {}
    if (stored != null) {
      try {
        _install(await compute(_parseTranslations, stored,
            debugLabel: 'tag-index-cache'));
        await _removeLegacy();
        unawaited(refresh());
        return;
      } catch (_) {/* Try the upgrade-era preferences cache next. */}
    }
    final legacy = _storage.prefs.getString(_cacheKey);
    if (legacy != null) {
      try {
        final parsed = await compute(_parseTranslations, legacy,
            debugLabel: 'tag-index-legacy');
        _install(parsed);
        try {
          await _cache.write(legacy);
          await _removeLegacy();
        } catch (_) {
          // Do not discard the only offline copy if migration could not finish.
        }
        unawaited(refresh());
        return;
      } catch (_) {/* Download a fresh dictionary; preserve existing state. */}
    }
    await refresh();
  }

  Future<void> _removeLegacy() async {
    if (_storage.prefs.containsKey(_cacheKey)) {
      await _storage.prefs.remove(_cacheKey);
    }
  }

  Future<void> refresh() =>
      _refreshing ??= _fetchAndCache().whenComplete(() => _refreshing = null);
  Future<void> _fetchAndCache() async {
    try {
      final json = await _dio.get(ApiEndpoints.ehTagTranslationUrl);
      final parsed = await compute(_parseTranslations, json,
          debugLabel: 'tag-index-refresh');
      try {
        await _cache.write(json);
        await _removeLegacy();
      } catch (_) {
        // A valid downloaded dictionary is useful even when storage is full.
      }
      _install(parsed);
    } catch (_) {
      _log.w(
          'Tag translation refresh failed; keeping the available dictionary');
    }
  }

  void _install(_TranslationIndex index) {
    if (_disposed) return;
    _translations = index.translations;
    _searchEntries = index.searchEntries;
    _loaded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Get translation for a specific tag.
  String? getTranslation(String namespace, String key) {
    return _translations[namespace]?[key];
  }

  /// Get all translations for a namespace.
  Map<String, String>? getNamespaceTranslations(String namespace) {
    return _translations[namespace];
  }

  /// Search tags by translated name (for autocomplete).
  List<TagSearchResult> searchByTranslation(String query, {int limit = 20}) {
    if (!_loaded || query.isEmpty) return [];
    final results = <TagSearchResult>[];
    final lowerQuery = query.toLowerCase();

    for (final entry in _searchEntries) {
      if (entry.contains(lowerQuery)) {
        results.add(entry.tag);
        if (results.length >= limit) return results;
      }
    }
    return results;
  }

  /// Queries are nested suffixes, longest first. Scan the dictionary once,
  /// considering ALL short-phrase matches before applying the result limit.
  /// Otherwise an earlier group of short matches can hide a longer tag.
  TagPhraseMatch? searchPhrases(List<String> queries, {int limit = 20}) {
    if (!_loaded || queries.isEmpty || limit <= 0) return null;
    final lower = queries.map((q) => q.toLowerCase()).toList();
    if (lower.last.isEmpty) return null;
    var best = lower.length;
    final results = <TagSearchResult>[];
    for (final entry in _searchEntries) {
      if (!entry.contains(lower.last)) continue;
      var low = 0;
      var high = lower.length - 1;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if (entry.contains(lower[mid])) {
          high = mid;
        } else {
          low = mid + 1;
        }
      }
      if (low < best) {
        best = low;
        results.clear();
      }
      if (low == best && results.length < limit) results.add(entry.tag);
      if (best == 0 && results.length == limit) break;
    }
    return results.isEmpty ? null : TagPhraseMatch(best, results);
  }

  static const _cacheKey = 'eh_tag_translations_cache';
}

class TagSearchResult {
  final String namespace;
  final String key;
  final String translation;

  const TagSearchResult({
    required this.namespace,
    required this.key,
    required this.translation,
  });

  String get fullTag => '$namespace:$key';
}

class TagPhraseMatch {
  final int queryIndex;
  final List<TagSearchResult> tags;
  const TagPhraseMatch(this.queryIndex, this.tags);
}

class _SearchEntry {
  final TagSearchResult tag;
  final String key;
  final String translation;
  _SearchEntry(this.tag)
      : key = tag.key.toLowerCase(),
        translation = tag.translation.toLowerCase();
  bool contains(String query) =>
      key.contains(query) || translation.contains(query);
}

class _TranslationIndex {
  final Map<String, Map<String, String>> translations;
  final List<_SearchEntry> searchEntries;
  _TranslationIndex(this.translations, this.searchEntries);
}

_TranslationIndex _parseTranslations(String jsonStr) {
  final data = json.decode(jsonStr);
  if (data is! Map || data['data'] is! List) {
    throw const FormatException('Invalid translation dictionary');
  }
  final result = <String, Map<String, String>>{};
  for (final entry in data['data'] as List) {
    final namespace = entry['namespace'] as String;
    final tags = entry['data'] as Map<String, dynamic>;
    final translated = <String, String>{};
    for (final tag in tags.entries) {
      if (tag.value is Map && tag.value['name'] is String) {
        translated[tag.key] = tag.value['name'] as String;
      }
    }
    if (translated.isNotEmpty) result[namespace] = translated;
  }
  if (result.isEmpty) {
    throw const FormatException('Empty translation dictionary');
  }
  return _TranslationIndex(result, [
    for (final namespace in result.entries)
      for (final tag in namespace.value.entries)
        _SearchEntry(TagSearchResult(
            namespace: namespace.key, key: tag.key, translation: tag.value)),
  ]);
}
