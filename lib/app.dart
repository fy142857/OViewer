import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get_it/get_it.dart';
import 'widgets/daily_check_in_host.dart';
import 'widgets/favorites_session_host.dart';
import 'core/router/app_router.dart';
import 'core/network/network_preparation.dart';
import 'core/router/route_observer.dart';
import 'core/theme/app_theme.dart';
import 'blocs/auth/auth_bloc.dart';
import 'blocs/auth/auth_event.dart';
import 'blocs/favorites/favorites_bloc.dart';
import 'blocs/history/history_bloc.dart';
import 'blocs/history/history_event.dart';
import 'blocs/settings/settings_bloc.dart';
import 'blocs/settings/settings_event.dart';
import 'blocs/settings/settings_state.dart';
import 'blocs/download/download_bloc.dart';
import 'blocs/download/download_event.dart';
import 'core/services/offline_platform.dart';
import 'core/services/apk_update_platform.dart';
import 'core/services/release_link_opener.dart';
import 'blocs/update/update_cubit.dart';
import 'widgets/android_update_dialog.dart';
import 'repositories/search_repository.dart';
import 'repositories/favorites_repository.dart';
import 'repositories/history_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/settings_repository.dart';
import 'core/services/offline_download_coordinator.dart';

class OViewerApp extends StatelessWidget {
  final SettingsState? initialSettings;
  final NetworkPreparation? network;
  const OViewerApp({super.key, this.initialSettings, this.network});

  @override
  Widget build(BuildContext context) {
    final sl = GetIt.I;

    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) =>
              AuthBloc(sl<AuthRepository>())..add(CheckLoginStatus()),
        ),
        BlocProvider(
          create: (_) => FavoritesBloc(sl<FavoritesRepository>(),
              settings: sl<SettingsRepository>(),
              search: sl<SearchRepository>()),
        ),
        BlocProvider(
          lazy: false,
          create: (_) =>
              HistoryBloc(sl<HistoryRepository>())..add(LoadHistory()),
        ),
        BlocProvider(
          create: (_) => SettingsBloc(sl<SettingsRepository>(),
              initialState: initialSettings, network: network)
            ..add(LoadSettings()),
        ),
        BlocProvider(
          create: (_) => DownloadBloc(sl<OfflineDownloadCoordinator>())
            ..add(LoadDownloads()),
        ),
      ],
      child: FavoritesSessionHost(
          child: DailyCheckInHost(
              builder: (navigatorKey, checkInObserver) =>
                  BlocBuilder<SettingsBloc, SettingsState>(
                    buildWhen: (prev, curr) =>
                        prev.themeMode != curr.themeMode ||
                        prev.locale != curr.locale,
                    builder: (context, settingsState) {
                      if (sl.isRegistered<ApkUpdatePlatform>()) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          final platform = sl<ApkUpdatePlatform>();
                          platform.onOpen = (id, install) async {
                            final navigator = navigatorKey.currentState;
                            if (navigator == null || !navigator.mounted) return;
                            final cubit = sl<UpdateCubit>();
                            final dialog = showAndroidUpdateDialog(
                                navigator.context,
                                cubit: cubit,
                                openRelease: sl<ReleaseLinkOpener>().open);
                            await cubit.check();
                            if (install)
                              await cubit.installFromNotification(id);
                            await dialog;
                          };
                          platform.drainOpen();
                        });
                      }
                      if (sl.isRegistered<OfflinePlatform>()) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          sl<OfflinePlatform>().attachNavigator(() =>
                              navigatorKey.currentState
                                  ?.pushNamed('/downloads'));
                        });
                      }
                      return MaterialApp(
                        title: kDebugMode ? 'OViewer Debug' : 'OViewer',
                        navigatorKey: navigatorKey,
                        debugShowCheckedModeBanner: false,
                        theme: AppTheme.light,
                        darkTheme: AppTheme.dark,
                        themeMode: _mapThemeMode(settingsState.themeMode),
                        locale: Locale(settingsState.locale),
                        supportedLocales: const [Locale('zh'), Locale('en')],
                        localizationsDelegates: const [
                          GlobalMaterialLocalizations.delegate,
                          GlobalWidgetsLocalizations.delegate,
                          GlobalCupertinoLocalizations.delegate,
                        ],
                        initialRoute: AppRouter.home,
                        onGenerateRoute: AppRouter.generateRoute,
                        navigatorObservers: [appRouteObserver, checkInObserver],
                      );
                    },
                  ))),
    );
  }

  ThemeMode _mapThemeMode(int mode) {
    switch (mode) {
      case 1:
        return ThemeMode.light;
      case 2:
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
