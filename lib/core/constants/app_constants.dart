class AppConstants {
  AppConstants._();

  static const String appName = 'OViewer';
  static const String appVersion = '1.0.0';

  // E-Hentai base URLs
  static const String ehBaseUrl = 'https://e-hentai.org';
  static const String exBaseUrl = 'https://exhentai.org';

  // Dynamic site switching
  static bool _useExHentai = false;
  static bool get useExHentai => _useExHentai;
  static set useExHentai(bool value) => _useExHentai = value;
  static String get baseUrl => _useExHentai ? exBaseUrl : ehBaseUrl;
  static String get siteName => _useExHentai ? 'ExHentai' : 'E-Hentai';

  // Pagination
  static const int galleryPageSize = 25;
  static const int searchPageSize = 25;
  static const int thumbnailsPerPage = 40;

  // Image cache
  static const int maxCacheSizeMB = 500;
  static const int maxCacheAgeDays = 7;

  // Reader
  static const int preloadPageCount = 3;
  static const int maxZoomScale = 5;

  // Search history
  static const int maxSearchHistory = 20;

  // Network
  static const int connectTimeout = 15000; // ms
  static const int receiveTimeout = 30000; // ms

  // Cookie keys
  static const String cookieIpbMemberId = 'ipb_member_id';
  static const String cookieIpbPassHash = 'ipb_pass_hash';
  static const String cookieIgneous = 'igneous';
  static const String cookieSk = 'sk';

  // Categories
  static const List<String> categories = [
    'Doujinshi',
    'Manga',
    'Artist CG',
    'Game CG',
    'Western',
    'Non-H',
    'Image Set',
    'Cosplay',
    'Asian Porn',
    'Misc',
  ];

  // Site protocol bits for f_cats (1 means excluded), independent of UI order.
  static const Map<String, int> categoryBits = {
    'Doujinshi': 2,
    'Manga': 4,
    'Artist CG': 8,
    'Game CG': 16,
    'Western': 512,
    'Non-H': 256,
    'Image Set': 32,
    'Cosplay': 64,
    'Asian Porn': 128,
    'Misc': 1,
  };

  // Category colors (hex)
  static const Map<String, int> categoryColors = {
    'Doujinshi': 0xFFF44336,
    'Manga': 0xFFFF9800,
    'Artist CG': 0xFFFFC107,
    'Game CG': 0xFF4CAF50,
    'Western': 0xFF8BC34A,
    'Non-H': 0xFF2196F3,
    'Image Set': 0xFF3F51B5,
    'Cosplay': 0xFF9C27B0,
    'Asian Porn': 0xFF9E9E9E,
    'Misc': 0xFF607D8B,
  };
}
