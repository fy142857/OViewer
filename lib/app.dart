import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get_it/get_it.dart';
import 'widgets/daily_check_in_host.dart';
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
import 'repositories/gallery_repository.dart';
import 'repositories/favorites_repository.dart';
import 'repositories/history_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/settings_repository.dart';
import 'repositories/download_repository.dart';

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
          create: (_) => FavoritesBloc(sl<FavoritesRepository>()),
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
          create: (_) =>
              DownloadBloc(sl<DownloadRepository>(), sl<GalleryRepository>()),
        ),
      ],
      child: DailyCheckInHost(
          builder: (navigatorKey, checkInObserver) =>
              BlocBuilder<SettingsBloc, SettingsState>(
                buildWhen: (prev, curr) =>
                    prev.themeMode != curr.themeMode ||
                    prev.locale != curr.locale,
                builder: (context, settingsState) {
                  return MaterialApp(
                    title: 'OViewer',
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
              )),
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
