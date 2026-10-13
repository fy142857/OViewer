import 'dart:async';
import 'dart:io';
import 'package:package_info_plus/package_info_plus.dart';
import 'blocs/update/update_cubit.dart';
import 'core/services/apk_download_service.dart';
import 'core/services/apk_installer.dart';
import 'package:flutter/material.dart';
import 'blocs/settings/settings_bloc.dart';
import 'core/constants/app_constants.dart';
import 'core/network/network_preparation.dart';
import 'core/network/network_proxy_io.dart';
import 'core/services/startup_tasks.dart';
import 'core/services/startup_timings.dart';
import 'package:get_it/get_it.dart';
import 'app.dart';
import 'repositories/daily_check_in_repository.dart';
import 'blocs/daily_check_in/daily_check_in_cubit.dart';
import 'core/network/dio_client.dart';
import 'core/network/cookie_manager.dart';
import 'core/network/eh_image_cache_manager.dart';
import 'core/storage/local_storage.dart';
import 'core/storage/database.dart';
import 'repositories/gallery_repository.dart';
import 'repositories/search_repository.dart';
import 'repositories/favorites_repository.dart';
import 'repositories/history_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/settings_repository.dart';
import 'repositories/tag_translation_repository.dart';
import 'repositories/update_repository.dart';
import 'core/services/release_link_opener.dart';
import 'core/services/offline_download_coordinator.dart';
import 'core/services/offline_platform.dart';
import 'core/storage/offline_files.dart';
import 'core/network/offline_download_network.dart';
import 'repositories/offline_repository.dart';

final sl = GetIt.instance;

Future<void> _initDependencies(
    {DioClient Function(CookieManager, AppDatabase)? dioFactory}) async {
  // Core - Storage
  final localStorage = LocalStorage();
  await localStorage.init();

  // Core - Cookie Manager
  final cookieManager = CookieManager();
  await cookieManager.init();
  sl.registerSingleton<LocalStorage>(localStorage);
  sl.registerSingleton<CookieManager>(cookieManager);
  AppConstants.useExHentai = localStorage.getUseExHentai();

  // Core - Image cache (must be before any image loading)
  EhImageCacheManager.init(cookieManager,
      limitMB: localStorage.getCacheLimit());
  sl.registerSingleton<EhImageCacheManager>(EhImageCacheManager.instance,
      dispose: (cache) => cache.dispose());

  // Core - Database
  final database = AppDatabase();
  sl.registerSingleton<AppDatabase>(database, dispose: (db) => db.close());

  // Core - Network
  final dioClient = dioFactory?.call(cookieManager, database) ??
      DioClient(cookieManager, database);
  sl.registerSingleton<DioClient>(dioClient);

  final network = NetworkPreparation(
      manualProxy: localStorage.getProxy(),
      autoProxy: localStorage.getAutoProxy(),
      apply: dioClient.setProxy);
  NetworkProxy.beforeRequest = network.waitUntilReady;
  sl.registerSingleton<NetworkPreparation>(network,
      dispose: (value) => value.dispose());

  final checkIn =
      DailyCheckInCubit(DailyCheckInRepository(dioClient, localStorage));
  dioClient.captureResponseScope = checkIn.captureResponseScope;
  dioClient.onHtmlResponse = checkIn.observeResponse;
  sl.registerSingleton<DailyCheckInCubit>(checkIn, dispose: (value) async {
    dioClient.captureResponseScope = null;
    dioClient.onHtmlResponse = null;
    await value.close();
  });

  // Repositories
  sl.registerLazySingleton<UpdateRepository>(
      () => UpdateRepository(storage: sl<LocalStorage>()));
  sl.registerLazySingleton<ApkDownloadService>(() => ApkDownloadService());
  sl.registerLazySingleton<UpdateCubit>(
      () => UpdateCubit(sl<UpdateRepository>(), sl<ApkDownloadService>(),
          ApkInstaller(language: localStorage.getLocale)),
      dispose: (value) => value.close());
  sl.registerLazySingleton<ReleaseLinkOpener>(() => ReleaseLinkOpener());
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
  sl.registerLazySingleton<SettingsRepository>(
    () => SettingsRepository(sl<LocalStorage>()),
  );
  final offline = OfflineRepository(database, OfflineFiles());
  sl.registerSingleton<OfflineRepository>(offline, dispose: (r) => r.dispose());
  final offlinePlatform = OfflinePlatform(localStorage.getLocale);
  sl.registerSingleton<OfflinePlatform>(offlinePlatform,
      dispose: (p) => p.dispose());
  final downloads = OfflineDownloadCoordinator(
      offline, SiteOfflineDownloadNetwork(dioClient, cookieManager),
      galleryLimit: localStorage.getOfflineParallelGalleries(),
      pageLimit: localStorage.getOfflineParallelPages(),
      startBackground: offlinePlatform.start,
      stopBackground: offlinePlatform.stop);
  sl.registerSingleton<OfflineDownloadCoordinator>(downloads,
      dispose: (c) => c.dispose());
  offlinePlatform.bind(downloads);
  cookieManager.onSessionChanged =
      () => unawaited(downloads.pauseAll(reason: 'session_changed'));
  AppConstants.onSiteChanged =
      () => unawaited(downloads.pauseAll(reason: 'source_changed'));
  sl.registerLazySingleton<TagTranslationRepository>(
    () => TagTranslationRepository(sl<DioClient>(), sl<LocalStorage>()),
    dispose: (repository) => repository.dispose(),
  );
}

Future<void> main() async {
  StartupTimings.start();
  WidgetsFlutterBinding.ensureInitialized();
  await _startApp();
}

/// Separate debug entrypoint used by the emulator fixture APK only. Production
/// main never accepts transport overrides or contacts the fixture server.
Future<void> startOfflineValidation(
    DioClient Function(CookieManager, AppDatabase) dioFactory) async {
  WidgetsFlutterBinding.ensureInitialized();
  const release = bool.fromEnvironment('dart.vm.product');
  if (release) throw StateError('Offline validation is debug-only');
  await _initDependencies(dioFactory: dioFactory);
  await sl<LocalStorage>().setLocale('en');
  await sl<LocalStorage>().setAutoProxy(false);
  await sl<NetworkPreparation>().configure(manualProxy: null, autoProxy: false);
  await sl<OfflineDownloadCoordinator>().initialize();
  runApp(OViewerApp(
      initialSettings: SettingsBloc.readSaved(sl<SettingsRepository>()),
      network: sl<NetworkPreparation>()));
}

Future<void> _startApp() async {
  try {
    await StartupTimings.measure('essential_init', _initDependencies);
    final network = sl<NetworkPreparation>();
    final initial = SettingsBloc.readSaved(sl<SettingsRepository>());
    final tasks = StartupTasks(
      prepareNetwork: network.start,
      maintainCache: () async {
        await Future.wait([
          sl<OfflineDownloadCoordinator>().initialize(),
          EhImageCacheManager.instance.enforceLimit(),
          if (Platform.isAndroid)
            (() async {
              final installed = await PackageInfo.fromPlatform();
              await sl<ApkDownloadService>()
                  .maintain(int.parse(installed.buildNumber));
              await sl<UpdateRepository>().restoreUpdateStatus();
            })(),
        ]);
      },
      loadTranslations: () async {
        final translations = sl<TagTranslationRepository>();
        await translations.loadTranslations();
        if (!translations.isLoaded) {
          throw StateError('Translations unavailable');
        }
      },
    );
    runApp(OViewerApp(initialSettings: initial, network: network));
    unawaited(tasks.afterFirstFrame(
        WidgetsBinding.instance.waitUntilFirstFrameRasterized));
  } catch (_) {
    NetworkProxy.beforeRequest = null;
    await sl.reset();
    runApp(_StartupFailure(onRetry: () async {
      StartupTimings.start();
      await _startApp();
    }));
  }
}

class _StartupFailure extends StatefulWidget {
  final Future<void> Function() onRetry;
  const _StartupFailure({required this.onRetry});
  @override
  State<_StartupFailure> createState() => _StartupFailureState();
}

class _StartupFailureState extends State<_StartupFailure> {
  bool _retrying = false;
  @override
  Widget build(BuildContext context) {
    final chinese =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    return MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        home: Scaffold(
            body: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(chinese ? '启动失败，请重试' : 'Startup failed. Please retry.'),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: _retrying
                  ? null
                  : () async {
                      setState(() => _retrying = true);
                      await widget.onRetry();
                      if (mounted) setState(() => _retrying = false);
                    },
              child: Text(chinese ? '重试' : 'Retry')),
        ]))));
  }
}
