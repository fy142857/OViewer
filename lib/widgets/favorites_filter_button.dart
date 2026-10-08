import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/favorites/favorites_bloc.dart';
import '../blocs/favorites/favorites_state.dart';
import '../blocs/favorites/favorites_event.dart';
import '../core/l10n/s.dart';

class FavoritesFilterButton extends StatelessWidget {
  final String heroTag;
  final FavoritesEntry entry;
  final double bottomInset;
  const FavoritesFilterButton(
      {super.key,
      required this.heroTag,
      this.bottomInset = 0,
      this.entry = FavoritesEntry.home});
  @override
  Widget build(BuildContext context) {
    if (!context.watch<AuthBloc>().state.isLoggedIn) {
      return const SizedBox.shrink();
    }
    final s = S.of(context);
    return BlocBuilder<FavoritesBloc, FavoritesState>(
        bloc: context.read<FavoritesBloc>().forEntry(entry),
        builder: (context, state) => Padding(
            padding:
                EdgeInsets.only(bottom: bottomInset < 24 ? 24 : bottomInset),
            child: Semantics(
                label:
                    '${s.favoriteCategories}: ${s.favoriteCategory(state.category)}',
                child: FloatingActionButton.small(
                    heroTag: heroTag,
                    tooltip:
                        '${s.favoriteCategories}: ${s.favoriteCategory(state.category)}',
                    onPressed: state.savingCategory
                        ? null
                        : () async {
                            final bloc =
                                context.read<FavoritesBloc>().forEntry(entry);
                            final selected = await showModalBottomSheet<int>(
                                context: context,
                                builder: (context) => SafeArea(
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                          Padding(
                                              padding: const EdgeInsets.all(16),
                                              child: Text(s.favoriteCategories,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium)),
                                          Flexible(
                                              child: ListView(
                                                  shrinkWrap: true,
                                                  // Some Android gesture bars report no Flutter inset.
                                                  // Keep the last option fully reachable in that case.
                                                  padding: EdgeInsets.only(
                                                      bottom: bottomInset < 48
                                                          ? 48
                                                          : bottomInset),
                                                  children: [
                                                for (var category = -1;
                                                    category <= 9;
                                                    category++)
                                                  ListTile(
                                                      key: ValueKey(
                                                          'favorite-category-$category'),
                                                      title: Text(
                                                          s.favoriteCategory(
                                                              category)),
                                                      selected: category ==
                                                          state.category,
                                                      trailing: category ==
                                                              state.category
                                                          ? const Icon(
                                                              Icons.check)
                                                          : null,
                                                      onTap: () =>
                                                          Navigator.pop(context,
                                                              category)),
                                              ])),
                                        ])));
                            if (selected != null && !bloc.isClosed) {
                              bloc.add(SelectFavoriteCategory(selected,
                                  entry: entry));
                            }
                          },
                    child: const Icon(Icons.menu)))));
  }
}
