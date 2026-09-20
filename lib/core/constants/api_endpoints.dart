import 'app_constants.dart';

class ApiEndpoints {
  ApiEndpoints._();

  static String get _base => AppConstants.baseUrl;

  // Gallery list
  static String galleryList({int page = 0}) => '$_base/?page=$page';
  static String popular() => '$_base/popular';
  static String watched({int page = 0}) => '$_base/watched?page=$page';
  static String favorites({int page = 0, int cat = -1}) =>
      '$_base/favorites.php?page=$page${cat >= 0 ? '&favcat=$cat' : ''}';

  // Gallery detail
  static String galleryDetail(int gid, String token) =>
      '$_base/g/$gid/$token/';

  // Gallery image page
  static String imagePage(String pageToken, int gid, int page) =>
      '$_base/s/$pageToken/$gid-${page + 1}';

  // Search
  static String search({String? keyword, int page = 0}) {
    final params = <String>['page=$page'];
    if (keyword != null && keyword.isNotEmpty) {
      params.add('f_search=${Uri.encodeComponent(keyword)}');
    }
    return '$_base/?${params.join('&')}';
  }

  // Login
  static String get loginPage =>
      'https://forums.e-hentai.org/index.php?act=Login';
  static String get userConfig => '$_base/uconfig.php';

  // Favorites operations
  static String addFavorite(int gid, String token) =>
      '$_base/gallerypopups.php?gid=$gid&t=$token&act=addfav';

  // Rating & API
  static String get apiEndpoint => '$_base/api.php';

  // Comment
  static String galleryComment(int gid, String token) =>
      '$_base/g/$gid/$token/';

  // Thumbnails
  static String galleryThumbnails(int gid, String token, {int page = 0}) =>
      '$_base/g/$gid/$token/?p=$page';

  // Tag translation data source
  static const String ehTagTranslationUrl =
      'https://github.com/EhTagTranslation/Database/releases/latest/download/db.text.json';

  // My Tags
  static String get myTags => '$_base/mytags';
}
