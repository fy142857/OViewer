import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'app.dart';
import 'core/network/dio_client.dart';
import 'core/network/cookie_manager.dart';
import 'core/network/eh_image_cache_manager.dart';
import 'core/network/system_proxy_detector.dart';
import 'core/storage/local_storage.dart';
import 'core/storage/database.dart';
import 'repositories/gallery_repository.dart';
import 'repositories/search_repository.dart';
import 'repositories/favorites_repository.dart';
import 'repositories/history_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/download_repository.dart';
import 'repositories/settings_repository.dart';
import 'repositories/tag_translation_repository.dart';

final sl = GetIt.instance;

Future<void> _initDependencies() async {
  // Core - Storage
  final localStorage = LocalStorage();
  await localStorage.init();
  sl.registerSingleton<LocalStorage>(localStorage);

  // Core - Cookie Manager
  final cookieManager = CookieManager();
  await cookieManager.init();
  sl.registerSingleton<CookieManager>(cookieManager);

  // Core - Image cache (must be before any image loading)
  EhImageCacheManager.init(cookieManager);

  // Core - Network
  final dioClient = DioClient(cookieManager);
  sl.registerSingleton<DioClient>(dioClient);

  // Apply proxy BEFORE any network requests:
  // Manual proxy takes priority; otherwise auto-detect (env proxy / VPN + local port).
  // Dart VM on Android doesn't route through VpnService, so we probe local proxy ports.
  final savedProxy = localStorage.getProxy();
  if (savedProxy != null && savedProxy.isNotEmpty) {
    dioClient.setProxy(savedProxy);
  } else if (localStorage.getAutoProxy()) {
    final result = await SystemProxyDetector.detect();
    if (result.proxyUrl != null) {
      dioClient.setProxy(result.proxyUrl);
    }
  }

  // Core - Database
  final database = AppDatabase();
  sl.registerSingleton<AppDatabase>(database);

  // Repositories
  sl.registerLazySingleton<GalleryRepository>(
    () => GalleryRepository(sl<DioClient>()),
  );
  sl.registerLazySingleton<SearchRepository>(
    () => SearchRepository(sl<DioClient>(), sl<LocalStorage>()),
  );
  sl.registerLazySingleton<FavoritesRepository>(
    () => FavoritesRepository(sl<DioClient>(), sl<AppDatabase>()),
  );
  sl.registerLazySingleton<HistoryRepository>(
    () => HistoryRepository(sl<AppDatabase>()),
  );
  sl.registerLazySingleton<AuthRepository>(
    () => AuthRepository(sl<DioClient>(), sl<CookieManager>()),
  );
  sl.registerLazySingleton<DownloadRepository>(
    () => DownloadRepository(
        sl<DioClient>(), sl<AppDatabase>(), sl<GalleryRepository>()),
  );
  sl.registerLazySingleton<SettingsRepository>(
    () => SettingsRepository(sl<LocalStorage>()),
  );
  sl.registerLazySingleton<TagTranslationRepository>(
    () => TagTranslationRepository(sl<DioClient>(), sl<LocalStorage>()),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initDependencies();

  // Load tag translations in background
  sl<TagTranslationRepository>().loadTranslations();

  runApp(const OViewerApp());
}
