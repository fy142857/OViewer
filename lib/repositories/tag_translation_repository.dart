import 'dart:convert';
import 'package:logger/logger.dart';
import '../core/network/dio_client.dart';
import '../core/constants/api_endpoints.dart';
import '../core/storage/local_storage.dart';

class TagTranslationRepository {
  static final _log = Logger();
  final DioClient _dio;
  final LocalStorage _storage;

  /// namespace -> { tagKey -> translatedName }
  Map<String, Map<String, String>> _translations = {};
  bool _loaded = false;
  List<_SearchEntry> _searchEntries = [];

  TagTranslationRepository(this._dio, this._storage);

  bool get isLoaded => _loaded;

  /// Load translations: try local cache first, then fetch remote.
  Future<void> loadTranslations() async {
    // Try loading from local cache
    final cached = _storage.prefs.getString(_cacheKey);
    if (cached != null) {
      try {
        _parseJsonData(cached);
        _loaded = true;
        _log.i('Tag translations loaded from cache '
            '(${_translations.length} namespaces)');
        // Refresh in background
        _fetchAndCache();
        return;
      } catch (_) {
        // Cache corrupted, fetch fresh
      }
    }

    await _fetchAndCache();
  }

  Future<void> _fetchAndCache() async {
    try {
      final jsonStr = await _dio.get(ApiEndpoints.ehTagTranslationUrl);
      _parseJsonData(jsonStr);
      _loaded = true;
      // Cache locally
      await _storage.prefs.setString(_cacheKey, jsonStr);
      _log.i('Tag translations fetched and cached '
          '(${_translations.length} namespaces)');
    } catch (e) {
      _log.w('Failed to fetch tag translations: $e');
    }
  }

  void _parseJsonData(String jsonStr) {
    final data = json.decode(jsonStr);
    final result = <String, Map<String, String>>{};

    // EhTagTranslation db.text.json format:
    // { "data": [ { "namespace": "...", "data": { "tagKey": { "name": "..." } } } ] }
    if (data is Map && data.containsKey('data')) {
      final dataList = data['data'] as List;
      for (final nsEntry in dataList) {
        final namespace = nsEntry['namespace'] as String? ?? '';
        final tags = nsEntry['data'] as Map<String, dynamic>? ?? {};
        final nsMap = <String, String>{};
        for (final entry in tags.entries) {
          final tagData = entry.value;
          if (tagData is Map && tagData.containsKey('name')) {
            nsMap[entry.key] = tagData['name'] as String;
          }
        }
        if (nsMap.isNotEmpty) {
          result[namespace] = nsMap;
        }
      }
    }

    _translations = result;
    _searchEntries = [
      for (final namespace in result.entries)
        for (final tag in namespace.value.entries)
          _SearchEntry(TagSearchResult(
              namespace: namespace.key, key: tag.key, translation: tag.value)),
    ];
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
