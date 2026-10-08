import '../core/storage/local_storage.dart';

class SettingsRepository {
  final LocalStorage _storage;

  SettingsRepository(this._storage);

  int? getFavoriteCategory() => _storage.getFavoriteCategory();
  Future<void> setFavoriteCategory(int category) =>
      _storage.setFavoriteCategory(category);

  int getFavoriteDestination() => _storage.getFavoriteDestination();
  Future<void> setFavoriteDestination(int slot) =>
      _storage.setFavoriteDestination(slot);

  // Theme (0=system, 1=light, 2=dark)
  int getThemeMode() => _storage.getThemeMode();
  Future<void> setThemeMode(int mode) => _storage.setThemeMode(mode);

  // Reading mode (0=left-to-right, 1=right-to-left, 2=vertical)
  int getReadingMode() => _storage.getReadingMode();
  Future<void> setReadingMode(int mode) => _storage.setReadingMode(mode);

  // Display mode (0=list, 1=grid/waterfall)
  int getDisplayMode() => _storage.getDisplayMode();
  Future<void> setDisplayMode(int mode) => _storage.setDisplayMode(mode);

  // Cache limit
  int getCacheLimit() => _storage.getCacheLimit();
  Future<void> setCacheLimit(int mb) => _storage.setCacheLimit(mb);

  // Proxy
  String? getProxy() => _storage.getProxy();
  Future<void> setProxy(String? url) => _storage.setProxy(url);

  // Auto proxy detection
  bool getAutoProxy() => _storage.getAutoProxy();
  Future<void> setAutoProxy(bool value) => _storage.setAutoProxy(value);

  // Site mode
  bool getUseExHentai() => _storage.getUseExHentai();
  Future<void> setUseExHentai(bool value) => _storage.setUseExHentai(value);

  // Hidden tags (My Tags)
  List<String> getHiddenTags() => _storage.getHiddenTags();
  Future<void> setHiddenTags(List<String> tags) => _storage.setHiddenTags(tags);

  // Locale
  String getLocale() => _storage.getLocale();
  Future<void> setLocale(String locale) => _storage.setLocale(locale);
}
