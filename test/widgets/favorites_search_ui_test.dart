import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/favorites/favorites_bloc.dart';
import 'package:oviewer/blocs/favorites/favorites_event.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/router/route_observer.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/screens/favorites/favorites_screen.dart';
import 'package:oviewer/screens/search/search_screen.dart';
import 'package:oviewer/widgets/favorites_content.dart';
import 'package:oviewer/widgets/favorites_filter_button.dart';
import 'package:oviewer/widgets/favorites_session_host.dart';

class Auth extends Mock implements AuthBloc {}

class Settings extends Mock implements SettingsBloc {}

class Repo extends Mock implements FavoritesRepository {}

class DioMock extends Mock implements DioClient {}

void main() {
  setUpAll(() => registerFallbackValue(CancelToken()));
  tearDown(() => GetIt.I.reset());
  for (final locale in ['zh', 'en']) {
    testWidgets(
        'independent entries submit/cancel/clear, retain group and share history ($locale)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStorage();
      await store.init();
      final dio = DioMock();
      final search = SearchRepository(dio, store);
      await search.addSearchHistory('old shared query');
      GetIt.I.registerSingleton<SearchRepository>(search);
      final settings = Settings();
      final auth = Auth();
      final repo = Repo();
      when(() => settings.state).thenReturn(SettingsState(locale: locale));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      when(() => auth.state)
          .thenReturn(const AuthState(status: AuthStatus.authenticated));
      when(() => auth.stream).thenAnswer((_) => const Stream.empty());
      final calls = <(String?, int)>[];
      when(() => repo.fetchCloudFavorites(
          page: any(named: 'page'),
          cat: any(named: 'cat'),
          keyword: any(named: 'keyword'),
          nextUrl: any(named: 'nextUrl'),
          cancelToken: any(named: 'cancelToken'))).thenAnswer((call) async {
        calls.add((
          call.namedArguments[#keyword] as String?,
          call.namedArguments[#cat] as int
        ));
        if (call.namedArguments[#keyword] == 'failure')
          throw StateError('offline');
        return const FavoritesResult(galleries: [], totalPages: 1);
      });
      when(() => repo.rebuildCache(any(), isCurrent: any(named: 'isCurrent')))
          .thenAnswer((_) async {});
      when(() => repo.clearConfirmationCache()).thenAnswer((_) async {});
      final bloc = FavoritesBloc(repo,
          settings: SettingsRepository(store), search: search);
      addTearDown(bloc.close);
      final navigator = GlobalKey<NavigatorState>();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settings),
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<FavoritesBloc>.value(value: bloc),
          ],
          child: FavoritesSessionHost(
              child: MaterialApp(
                  navigatorKey: navigator,
                  theme: locale == 'en'
                      ? ThemeData.dark(useMaterial3: true)
                      : ThemeData(useMaterial3: true),
                  navigatorObservers: [appRouteObserver],
                  routes: {'/favorites': (_) => const FavoritesScreen()},
                  home: const Scaffold(
                      body: FavoritesContent(storageKey: 'home-favorites'),
                      floatingActionButton:
                          FavoritesFilterButton(heroTag: 'home-filter'))))));
      await tester.pumpAndSettle();
      Future<void> input(String value, String entry) async {
        await tester.tap(find.byKey(ValueKey('favorites-search-$entry')));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.tune), findsNothing);
        await tester.enterText(find.byType(TextField), value);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byKey(const ValueKey('favorites-search-home')));
      await tester.pumpAndSettle();
      expect(find.text('old shared query'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'draft');
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(bloc.state.keyword, '');
      expect(calls.length, 1);
      await input('home query', 'home');
      expect(bloc.state.keyword, 'home query');
      bloc.add(const SelectFavoriteCategory(2));
      await tester.pumpAndSettle();
      bloc.add(const SearchFavorites('failure'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('favorites-search-home')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('favorites-clear-home')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('favorites-clear-home')));
      await tester.pumpAndSettle();
      expect(bloc.state.category, 2);
      await input('home query', 'home');
      final homeState = bloc.state;
      final homeBucket = bloc.scrollStorage;
      navigator.currentState!.pushNamed('/favorites');
      await tester.pumpAndSettle();
      final side = bloc.forEntry(FavoritesEntry.sidebar);
      expect(side.state.keyword, '');
      expect(side.state.category, -1);
      await tester.tap(find.byKey(const ValueKey('favorites-search-sidebar')));
      await tester.pumpAndSettle();
      expect(find.text('home query'), findsOneWidget);
      await tester.longPress(find.text('old shared query'));
      await tester.pumpAndSettle();
      expect(search.getSearchHistory(), isNot(contains('old shared query')));
      await tester.enterText(find.byType(TextField), 'sidebar query');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('favorite-category-4'));
      await tester.scrollUntilVisible(group, 150,
          scrollable: find.descendant(
              of: find.byType(BottomSheet), matching: find.byType(Scrollable)));
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(side.state.keyword, 'sidebar query');
      expect(side.state.category, 4);
      expect(bloc.state, same(homeState));
      expect(bloc.scrollStorage, same(homeBucket));
      expect(
          find.text(locale == 'zh'
              ? '当前分组没有匹配的收藏'
              : 'No matching favorites in this category'),
          findsOneWidget);
      final count = calls.length;
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(bloc.state, same(homeState));
      expect(calls.length, count);
      await tester.tap(find.byKey(const ValueKey('favorites-clear-home')));
      await tester.pumpAndSettle();
      expect(bloc.state.keyword, '');
      expect(bloc.state.category, 2);
      expect(side.state.keyword, 'sidebar query');
      expect(side.state.category, 4);
      navigator.currentState!.pushNamed('/favorites');
      await tester.pumpAndSettle();
      expect(side.state.keyword, 'sidebar query');
      await input('', 'sidebar');
      expect(side.state.keyword, '');
      expect(side.state.category, 4);
      expect(search.getSearchHistory(),
          containsAll(['home query', 'sidebar query']));
      verifyNever(() => dio.get(any()));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
  testWidgets(
      'input-only returns a gallery URL unchanged and retains suggestions after keyboard blur',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStorage();
    await store.init();
    final dio = DioMock();
    final search = SearchRepository(dio, store);
    await search.addSearchHistory('shared phrase');
    GetIt.I.registerSingleton<SearchRepository>(search);
    final settings = Settings();
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    String? result;
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings,
        child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          result = await Navigator.push<String>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const SearchScreen(
                                      inputOnly: true, initialKeyword: 'sha')));
                        },
                        child: const Text('Open')))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'shared');
    await tester.pumpAndSettle();
    expect(find.text('shared phrase'), findsOneWidget);
    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('shared phrase'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField), 'https://exhentai.org/g/42/abc/');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(result, 'https://exhentai.org/g/42/abc/');
    verifyNever(() => dio.get(any()));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
