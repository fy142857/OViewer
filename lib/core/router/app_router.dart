import 'package:flutter/material.dart';
import '../../screens/home/home_screen.dart';
import '../../screens/gallery_detail/gallery_detail_screen.dart';
import '../../screens/reader/reader_screen.dart';
import '../../screens/search/search_screen.dart';
import '../../screens/favorites/favorites_screen.dart';
import '../../screens/history/history_screen.dart';
import '../../screens/login/login_screen.dart';
import '../../screens/download/download_screen.dart';
import '../../screens/settings/settings_screen.dart';
import '../../screens/settings/my_tags_screen.dart';
import '../../screens/thumbnail_preview/thumbnail_preview_screen.dart';

class AppRouter {
  static const String home = '/';
  static const String gallery = '/gallery';
  static const String reader = '/reader';
  static const String search = '/search';
  static const String favorites = '/favorites';
  static const String history = '/history';
  static const String login = '/login';
  static const String downloads = '/downloads';
  static const String settings = '/settings';
  static const String myTags = '/my_tags';
  static const String thumbnailPreview = '/thumbnail_preview';

  static Route<dynamic> generateRoute(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case home:
        return MaterialPageRoute(builder: (_) => const HomeScreen());

      case gallery:
        final args = routeSettings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => GalleryDetailScreen(
            gid: args['gid'] as int,
            token: args['token'] as String,
          ),
        );

      case reader:
        final args = routeSettings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => ReaderScreen(
            gid: args['gid'] as int,
            token: args['token'] as String,
            initialPage: args['initialPage'] as int?,
          ),
        );

      case search:
        final args = routeSettings.arguments;
        String? keyword;
        bool saveHistory = true;
        if (args is String) {
          keyword = args;
        } else if (args is Map<String, dynamic>) {
          keyword = args['keyword'] as String?;
          saveHistory = args['saveHistory'] as bool? ?? true;
        }
        return MaterialPageRoute(
          builder: (_) => SearchScreen(
            initialKeyword: keyword,
            saveHistory: saveHistory,
          ),
        );

      case favorites:
        return MaterialPageRoute(
            builder: (_) => const FavoritesScreen());

      case history:
        return MaterialPageRoute(
            builder: (_) => const HistoryScreen());

      case login:
        return MaterialPageRoute(builder: (_) => const LoginScreen());

      case downloads:
        return MaterialPageRoute(
            builder: (_) => const DownloadScreen());

      case settings:
        return MaterialPageRoute(
            builder: (_) => const SettingsScreen());

      case myTags:
        return MaterialPageRoute(
            builder: (_) => const MyTagsScreen());

      case thumbnailPreview:
        final args = routeSettings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => ThumbnailPreviewScreen(
            gid: args['gid'] as int,
            token: args['token'] as String,
            fileCount: args['fileCount'] as int,
          ),
        );

      default:
        return MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(
              child: Text('No route defined for ${routeSettings.name}'),
            ),
          ),
        );
    }
  }
}
