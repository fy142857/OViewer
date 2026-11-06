import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/favorites/favorites_bloc.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/theme/app_theme.dart';
import 'package:oviewer/widgets/favorites_filter_button.dart';
import 'favorites_search_ui_test.dart' show Auth, Settings, Repo;

void main() {
  for (final locale in ['zh', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('group field layout and system back $locale/$dark/$scale',
            (tester) async {
          final auth = Auth();
          final settings = Settings();
          final bloc = FavoritesBloc(Repo());
          addTearDown(bloc.close);
          when(() => auth.state)
              .thenReturn(const AuthState(status: AuthStatus.authenticated));
          when(() => auth.stream).thenAnswer((_) => const Stream.empty());
          when(() => settings.state).thenReturn(SettingsState(locale: locale));
          when(() => settings.stream).thenAnswer((_) => const Stream.empty());
          await tester.binding.setSurfaceSize(const Size(360, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(MultiBlocProvider(
              providers: [
                BlocProvider<AuthBloc>.value(value: auth),
                BlocProvider<SettingsBloc>.value(value: settings),
                BlocProvider<FavoritesBloc>.value(value: bloc),
              ],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  home: const Scaffold(
                      floatingActionButton:
                          FavoritesFilterButton(heroTag: 'group-layout')))));
          await tester.tap(find.byType(FloatingActionButton));
          await tester.pumpAndSettle();
          final groupTitle =
              find.text(locale == 'zh' ? '收藏分组' : 'Favorite categories');
          final categoryTitle = find.text(locale == 'zh' ? '分类' : 'Categories');
          expect(tester.widget<Text>(groupTitle).style,
              tester.widget<Text>(categoryTitle).style);
          expect(tester.getTopLeft(groupTitle).dx,
              tester.getTopLeft(categoryTitle).dx);
          final field = find.byKey(const ValueKey('favorite-group-selector'));
          final decoration =
              find.descendant(of: field, matching: find.byType(InputDecorator));
          final dropdown = find.descendant(
              of: field, matching: find.byType(DropdownButton<int>));
          final valueText = find.descendant(
              of: field,
              matching: find
                  .text(locale == 'zh' ? '显示全部' : 'All favorites')
                  .hitTestable());
          // The selected value occupies the center of the actual painted field,
          // rather than sharing space with a floating label.
          expect(valueText, findsOneWidget);
          final valueStyle =
              DefaultTextStyle.of(tester.element(valueText)).style;
          expect(valueStyle.fontSize, 14);
          expect(tester.getCenter(valueText).dy,
              closeTo(tester.getCenter(decoration).dy, 1));
          expect(tester.getTopLeft(valueText).dx,
              closeTo(tester.getTopLeft(decoration).dx + 12, 1));
          expect(tester.getSize(field).height, inInclusiveRange(40, 80));
          final before = tester.getRect(decoration);
          await tester.tap(field);
          await tester.pumpAndSettle();
          expect(
              find.byKey(const ValueKey('favorite-category-0'),
                  skipOffstage: false),
              findsNWidgets(2));
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(
              find.byKey(const ValueKey('favorite-category-0'),
                  skipOffstage: false),
              findsOneWidget);
          expect(find.byKey(const ValueKey('favorite-filters-apply')),
              findsOneWidget);
          expect(tester.getRect(decoration), before);
          final ink = tester.widget<InkWell>(
              find.descendant(of: dropdown, matching: find.byType(InkWell)));
          expect(ink.focusNode!.hasFocus, isTrue);
          expect(ink.borderRadius, BorderRadius.circular(12));
          expect(tester.getCenter(valueText).dy,
              closeTo(tester.getCenter(decoration).dy, 1));
          // A second open/close follows the same cancel path without changing
          // the selected group or applying the draft filter.
          await tester.tap(field);
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(tester.widget<DropdownButton<int>>(dropdown).value, -1);
          expect(bloc.state.category, -1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        });
      }
    }
  }
}
