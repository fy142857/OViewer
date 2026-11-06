import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/favorites/favorites_bloc.dart';
import '../blocs/favorites/favorites_state.dart';
import '../blocs/favorites/favorites_event.dart';
import '../core/l10n/s.dart';
import 'search_filter_controls.dart';

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
    if (!context.watch<AuthBloc>().state.isLoggedIn)
      return const SizedBox.shrink();
    final s = S.of(context);
    final bloc = context.read<FavoritesBloc>().forEntry(entry);
    return BlocBuilder<FavoritesBloc, FavoritesState>(
        bloc: bloc,
        builder: (context, state) => Padding(
            padding:
                EdgeInsets.only(bottom: bottomInset < 24 ? 24 : bottomInset),
            child: SearchFilterAction(
                heroTag: heroTag,
                tooltip: s.searchFilters,
                onPressed: state.savingCategory
                    ? null
                    : () async {
                        final scope = bloc.sessionScope;
                        final selection =
                            await showModalBottomSheet<(int, List<String>)>(
                                context: context,
                                isScrollControlled: true,
                                builder: (_) => _FavoritesFiltersSheet(
                                    state: state,
                                    bottomInset: bottomInset,
                                    strings: s));
                        if (selection != null &&
                            !bloc.isClosed &&
                            scope == bloc.sessionScope) {
                          bloc.add(ApplyFavoriteFilters(
                              selection.$1, selection.$2,
                              entry: entry));
                        }
                      })));
  }
}

class _FavoritesFiltersSheet extends StatefulWidget {
  final FavoritesState state;
  final double bottomInset;
  final S strings;
  const _FavoritesFiltersSheet(
      {required this.state, required this.bottomInset, required this.strings});
  @override
  State<_FavoritesFiltersSheet> createState() => _FavoritesFiltersSheetState();
}

class _FavoritesFiltersSheetState extends State<_FavoritesFiltersSheet> {
  late int _group = widget.state.category;
  late final _categories = [...widget.state.galleryCategories];
  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return DraggableScrollableSheet(
        initialChildSize: .6,
        maxChildSize: .85,
        minChildSize: .4,
        expand: false,
        builder: (_, scroll) => SafeArea(
                child: Column(children: [
              Expanded(
                  child: ListView(
                      controller: scroll,
                      padding: const EdgeInsets.all(16),
                      children: [
                    Row(children: [
                      Expanded(
                          child: Text(s.searchFilters,
                              style: Theme.of(context).textTheme.titleLarge)),
                      TextButton(
                          onPressed: () => setState(() {
                                _group = -1;
                                _categories.clear();
                              }),
                          child: Text(s.reset))
                    ]),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                        key: const ValueKey('favorite-group-selector'),
                        value: _group,
                        isExpanded: true,
                        decoration:
                            InputDecoration(labelText: s.favoriteCategories),
                        items: [
                          for (var i = -1; i <= 9; i++)
                            DropdownMenuItem(
                                key: ValueKey('favorite-category-$i'),
                                value: i,
                                child: Text(s.favoriteCategory(i)))
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _group = value);
                        }),
                    const SizedBox(height: 20),
                    Text(s.categories,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    GalleryCategoryFilters(
                        selected: _categories,
                        onSelected: (category, value) => setState(() {
                              value
                                  ? _categories.add(category)
                                  : _categories.remove(category);
                            })),
                  ])),
              Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16,
                      widget.bottomInset < 24 ? 24 : widget.bottomInset),
                  child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                          key: const ValueKey('favorite-filters-apply'),
                          onPressed: () => Navigator.pop(
                              context, (_group, [..._categories])),
                          child: Text(s.applyFilters)))),
            ])));
  }
}
