import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LocalStorage {
  late final SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  SharedPreferences get prefs {
    assert(_initialized, 'LocalStorage not initialized. Call init() first.');
    return _prefs;
  }

  // Keep a detected update across settings visits and application restarts.
  static const _keyLatestReleaseVersion = 'latest_release_version';
  String? getLatestReleaseVersion() => _prefs.getString(_keyLatestReleaseVersion);
  Future<void> setLatestReleaseVersion(String? version) async {
    final saved = version == null
        ? await _prefs.remove(_keyLatestReleaseVersion)
        : await _prefs.setString(_keyLatestReleaseVersion, version);
    if (!saved) throw StateError('Could not persist the latest release version.');
  }

  // Theme
  static const _keyThemeMode = 'theme_mode';
  int getThemeMode() => _prefs.getInt(_keyThemeMode) ?? 0; // 0=system
  Future<void> setThemeMode(int mode) => _prefs.setInt(_keyThemeMode, mode);

  // Reading mode
  static const _keyReadingMode = 'reading_mode';
  int getReadingMode() => _prefs.getInt(_keyReadingMode) ?? 0; // 0=LR, 1=RL, 2=vertical
  Future<void> setReadingMode(int mode) => _prefs.setInt(_keyReadingMode, mode);

  // Search history
  static const _keySearchHistory = 'search_history';
  List<String> getSearchHistory() =>
      _prefs.getStringList(_keySearchHistory) ?? [];
  Future<void> setSearchHistory(List<String> history) =>
      _prefs.setStringList(_keySearchHistory, history);

  // Cache size limit (MB)
  static const _keyCacheLimit = 'cache_limit_mb';
  int getCacheLimit() => _prefs.getInt(_keyCacheLimit) ?? 500;
  Future<void> setCacheLimit(int mb) => _prefs.setInt(_keyCacheLimit, mb);

  // Proxy
  static const _keyProxy = 'proxy_url';
  String? getProxy() => _prefs.getString(_keyProxy);
  Future<void> setProxy(String? url) {
    if (url == null) return _prefs.remove(_keyProxy);
    return _prefs.setString(_keyProxy, url);
  }

  // Auto proxy detection
  static const _keyAutoProxy = 'auto_proxy';
  bool getAutoProxy() => _prefs.getBool(_keyAutoProxy) ?? true; // default ON
  Future<void> setAutoProxy(bool value) => _prefs.setBool(_keyAutoProxy, value);

  // Display mode
  static const _keyDisplayMode = 'display_mode';
  int getDisplayMode() => _prefs.getInt(_keyDisplayMode) ?? 0; // 0=list, 1=grid
  Future<void> setDisplayMode(int mode) => _prefs.setInt(_keyDisplayMode, mode);

  // ExHentai mode
  static const _keyUseExHentai = 'use_exhentai';
  bool getUseExHentai() => _prefs.getBool(_keyUseExHentai) ?? false;
  Future<void> setUseExHentai(bool value) => _prefs.setBool(_keyUseExHentai, value);

  // Hidden tags (My Tags)
  static const _keyHiddenTags = 'hidden_tags';
  List<String> getHiddenTags() {
    final json = _prefs.getString(_keyHiddenTags);
    if (json == null) return [];
    final list = jsonDecode(json);
    return (list as List).cast<String>();
  }
  Future<void> setHiddenTags(List<String> tags) =>
      _prefs.setString(_keyHiddenTags, jsonEncode(tags));

  // Locale (zh / en)
  static const _keyLocale = 'locale';
  String getLocale() => _prefs.getString(_keyLocale) ?? 'zh';
  Future<void> setLocale(String locale) =>
      _prefs.setString(_keyLocale, locale);
}
