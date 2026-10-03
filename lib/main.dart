import 'dart:async';
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
import 'repositories/download_repository.dart';
import 'repositories/settings_repository.dart';
import 'repositories/tag_translation_repository.dart';
import 'repositories/update_repository.dart';
import 'core/services/release_link_opener.dart';

final sl = GetIt.instance;

Future<void> _initDependencies() async {
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
  final dioClient = DioClient(cookieManager, database);
  sl.registerSingleton<DioClient>(dioClient);

  final network = NetworkPreparation(
      manualProxy: localStorage.getProxy(),
      autoProxy: localStorage.getAutoProxy(),
      apply: dioClient.setProxy);
  NetworkProxy.beforeRequest = network.waitUntilReady;
  sl.registerSingleton<NetworkPreparation>(network,
      dispose: (value) => value.dispose());

  final checkIn = DailyCheckInCubit(DailyCheckInRepository(dioClient, localStorage));
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
  sl.registerLazySingleton<DownloadRepository>(
    () => DownloadRepository(
        sl<DioClient>(), sl<AppDatabase>(), sl<GalleryRepository>()),
  );
  sl.registerLazySingleton<SettingsRepository>(
    () => SettingsRepository(sl<LocalStorage>()),
  );
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

Future<void> _startApp() async {
  try {
    await StartupTimings.measure('essential_init', _initDependencies);
    final network = sl<NetworkPreparation>();
    final initial = SettingsBloc.readSaved(sl<SettingsRepository>());
    final tasks = StartupTasks(
      prepareNetwork: network.start,
      maintainCache: EhImageCacheManager.instance.enforceLimit,
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
