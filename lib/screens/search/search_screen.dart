import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../blocs/search/search_bloc.dart';
import '../../blocs/search/search_event.dart';
import '../../blocs/search/search_state.dart';
import '../../blocs/settings/settings_bloc.dart';
import '../../blocs/settings/settings_event.dart';
import '../../core/constants/app_constants.dart';
import '../../core/l10n/s.dart';
import '../../core/utils/eh_url_parser.dart';
import '../../core/utils/tag_autocomplete.dart';
import '../../core/utils/tag_search_query.dart';
import '../../models/search_filter.dart';
import '../../models/gallery_preview.dart';
import '../../repositories/search_repository.dart';
import '../../repositories/tag_translation_repository.dart';
import '../../widgets/gallery_card.dart';
import '../../widgets/gallery_grid_item.dart';
import '../../widgets/adaptive_gallery_grid.dart';
import '../../widgets/shimmer_loading.dart';

class SearchScreen extends StatelessWidget {
  final String? initialKeyword;
  final bool saveHistory;
  final bool inputOnly;

  const SearchScreen(
      {super.key,
      this.initialKeyword,
      this.saveHistory = true,
      this.inputOnly = false});

  @override
  Widget build(BuildContext context) {
    // Nested searches keep their own results, filters and pagination until pop.
    return BlocProvider(
      create: (_) => SearchBloc(GetIt.I<SearchRepository>()),
      child: _SearchView(
        initialKeyword: initialKeyword,
        saveHistory: saveHistory,
        inputOnly: inputOnly,
      ),
    );
  }
}

class _SearchView extends StatefulWidget {
  final String? initialKeyword;
  final bool saveHistory;
  final bool inputOnly;

  const _SearchView(
      {this.initialKeyword,
      required this.saveHistory,
      required this.inputOnly});

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _gridScrollController = ScrollController();
  final _focusNode = FocusNode();
  PageStorageBucket _resultScrollStorage = PageStorageBucket();
  List<String> _selectedCategories = [];
  int? _minRating;
  bool _showHistory = true;
  Timer? _suggestionTimer;
  TagTranslationRepository? _tagRepository;
  final _suggestionRevision = ValueNotifier<int>(0);
  final _hasText = ValueNotifier<bool>(false);
  TextEditingValue? _suggestedValue;
  List<TagSuggestion> _suggestions = [];
  List<String> _historySuggestions = [];

  @override
  void initState() {
    super.initState();
    if (GetIt.I.isRegistered<TagTranslationRepository>()) {
      _tagRepository = GetIt.I<TagTranslationRepository>()
        ..addListener(_translationChanged);
    }
    if (widget.initialKeyword != null) {
      _controller.text = widget.initialKeyword!;
      if (!widget.inputOnly) {
        _showHistory = false;
        _performSearch();
      }
    }
    _hasText.value = _controller.text.isNotEmpty;
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && !_showHistory) {
        setState(() => _showHistory = true);
        context.read<SearchBloc>().add(LoadSearchHistory());
      }
      if (_focusNode.hasFocus) {
        _scheduleSuggestions();
      } else if (!widget.inputOnly) {
        _clearSuggestions();
      }
    });
    context.read<SearchBloc>().add(LoadSearchHistory());
    _scrollController.addListener(() => _onScroll(_scrollController));
    _gridScrollController.addListener(() => _onScroll(_gridScrollController));
    _controller.addListener(_scheduleSuggestions);
  }

  void _onScroll(ScrollController controller) {
    if (controller.position.pixels >=
        controller.position.maxScrollExtent - 300) {
      final bloc = context.read<SearchBloc>();
      if (bloc.state.isLoadingMore ||
          bloc.state.hasReachedEnd ||
          bloc.state.loadMoreFailed) return;
      bloc.add(LoadMoreSearchResults());
    }
  }

  void _performSearch() {
    _clearSuggestions();
    final keyword = _controller.text.trim();
    if (widget.inputOnly) {
      Navigator.pop(context, keyword);
      return;
    }

    // If the input is a gallery URL, navigate directly to it
    final parsed = EhUrlParser.parseGalleryUrl(keyword);
    if (parsed != null) {
      Navigator.pushNamed(context, '/gallery', arguments: {
        'gid': parsed.$1,
        'token': parsed.$2,
      });
      return;
    }

    setState(() {
      // A submitted search starts fresh in both layouts, including the layout
      // currently detached while history/suggestions are visible. Within this
      // search, layout switches and returning from detail retain their offsets.
      _resultScrollStorage = PageStorageBucket();
      _showHistory = false;
      _suggestions = [];
      _historySuggestions = [];
    });
    _focusNode.unfocus();
    context.read<SearchBloc>().add(PerformSearch(
        SearchFilter(
          keyword: keyword.isNotEmpty ? keyword : null,
          categories: _selectedCategories,
          minRating: _minRating,
        ),
        saveHistory: widget.saveHistory));
  }

  @override
  void dispose() {
    _tagRepository?.removeListener(_translationChanged);
    _suggestionTimer?.cancel();
    _suggestionRevision.dispose();
    _hasText.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _gridScrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _translationChanged() {
    if (mounted &&
        _focusNode.hasFocus &&
        _controller.value.composing.isCollapsed) {
      _scheduleSuggestions();
    }
  }

  void _clearSuggestions() {
    _suggestionTimer?.cancel();
    _suggestedValue = null;
    if (_suggestions.isEmpty && _historySuggestions.isEmpty) return;
    _suggestions = [];
    _historySuggestions = [];
    _suggestionRevision.value++;
  }

  void _scheduleSuggestions() {
    _hasText.value = _controller.text.isNotEmpty;
    _clearSuggestions();
    final value = _controller.value;
    if (!_focusNode.hasFocus || !value.composing.isCollapsed) return;
    _suggestionTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || !_focusNode.hasFocus || _controller.value != value) {
        return;
      }
      _updateSuggestions(value);
    });
  }

  void _updateSuggestions(TextEditingValue value) {
    final history = _controller.value.composing.isCollapsed
        ? matchingSearchHistory(
            _controller.text, GetIt.I<SearchRepository>().getSearchHistory())
        : <String>[];
    var suggestions = <TagSuggestion>[];
    try {
      final repo = GetIt.I<TagTranslationRepository>();
      suggestions = tagSuggestions(
          value, (query) => repo.searchByTranslation(query),
          searchPhrases: (queries) => repo.searchPhrases(queries));
    } catch (_) {
      // History remains available while the tag dictionary is unavailable.
    }
    String comparable(String text) =>
        normalizeTagSearchQuery(text).trim().toLowerCase();
    final historyQueries = history.map(comparable).toSet();
    final filtered = historyQueries.isEmpty
        ? suggestions
        : suggestions
            .where((suggestion) =>
                !historyQueries.contains(comparable(suggestion.apply().text)))
            .toList();
    _suggestedValue = value;
    _historySuggestions = history;
    _suggestions = filtered;
    _suggestionRevision.value++;
  }

  void _applySuggestion(TagSuggestion suggestion) {
    if (_controller.value != _suggestedValue ||
        _controller.text != suggestion.source) return;
    _controller.value = suggestion.apply();
    _clearSuggestions();
    _focusNode.requestFocus();
  }

  void _applyHistorySuggestion(String query) {
    if (_controller.value != _suggestedValue) return;
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _clearSuggestions();
    _focusNode.requestFocus();
  }

  TextStyle _fittedHintStyle(BuildContext context, double availableWidth) {
    final theme = Theme.of(context);
    final style = (theme.useMaterial3
            ? theme.textTheme.bodyLarge!
            : theme.textTheme.titleMedium!)
        .merge(theme.inputDecorationTheme.hintStyle);
    final hintStyle = theme.inputDecorationTheme.hintStyle ?? const TextStyle();
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaleFactor: MediaQuery.textScaleFactorOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    );
    double widthAt(double fontSize) {
      painter.text = TextSpan(
          text: S.of(context).searchGalleries,
          style: style.copyWith(fontSize: fontSize));
      painter.layout();
      return painter.width;
    }

    try {
      var high = style.fontSize ?? 16;
      if (widthAt(high) <= availableWidth) {
        return hintStyle.copyWith(fontSize: high);
      }
      var low = 0.1;
      // Measure the actual font, spacing, locale and accessibility scale.
      // Only the placeholder shrinks; typed text keeps its normal size.
      for (var i = 0; i < 14; i++) {
        final middle = (low + high) / 2;
        if (widthAt(middle) <= availableWidth - 0.5) {
          low = middle;
        } else {
          high = middle;
        }
      }
      return hintStyle.copyWith(fontSize: low);
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isGrid =
        context.select((SettingsBloc bloc) => bloc.state.displayMode == 1);
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        leadingWidth: 48,
        titleSpacing: 8,
        title: ValueListenableBuilder<bool>(
            valueListenable: _hasText,
            builder: (context, hasText, _) => LayoutBuilder(
                builder: (context, constraints) => TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus:
                          widget.inputOnly || widget.initialKeyword == null,
                      decoration: InputDecoration(
                        hintText: s.searchGalleries,
                        hintStyle: _fittedHintStyle(context,
                            constraints.maxWidth - 16 - (hasText ? 48 : 0)),
                        hintMaxLines: 1,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 12),
                        border: InputBorder.none,
                        suffixIcon: hasText
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 20),
                                onPressed: () {
                                  _controller.clear();
                                  context.read<SearchBloc>().add(ClearSearch());
                                  setState(() {
                                    _showHistory = true;
                                    _suggestions = [];
                                    _historySuggestions = [];
                                  });
                                },
                              )
                            : null,
                      ),
                      onSubmitted: (_) => _performSearch(),
                    ))),
        actions: [
          if (!_showHistory)
            IconButton(
              key: const ValueKey('search-view-toggle'),
              tooltip: isGrid ? s.listView : s.gridView,
              icon: Icon(
                  isGrid ? Icons.view_list_rounded : Icons.grid_view_rounded),
              onPressed: () => context
                  .read<SettingsBloc>()
                  .add(UpdateDisplayMode(isGrid ? 0 : 1)),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.inputOnly)
            FloatingActionButton.small(
              heroTag: 'filter',
              onPressed: _showFilterDialog,
              child: const Icon(Icons.tune),
            ),
          if (!widget.inputOnly) const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'search',
            onPressed: _performSearch,
            child: const Icon(Icons.search),
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
          valueListenable: _suggestionRevision,
          builder: (context, _, __) => Column(
                children: [
                  // Active filters row
                  if (_selectedCategories.isNotEmpty || _minRating != null)
                    _buildActiveFilters(),
                  // Tag suggestions or Content
                  if (_historySuggestions.isNotEmpty || _suggestions.isNotEmpty)
                    _buildSuggestions()
                  else
                    Expanded(
                      child: BlocBuilder<SearchBloc, SearchState>(
                        builder: (context, state) {
                          if (_showHistory) {
                            return _buildSearchHistory(
                                _controller.text.trim().isEmpty
                                    ? state.searchHistory
                                    : matchingSearchHistory(
                                        _controller.text,
                                        GetIt.I<SearchRepository>()
                                            .getSearchHistory()));
                          }
                          Widget resultsView() {
                            if (state.status == SearchStatus.loading &&
                                state.results.isEmpty) {
                              return isGrid
                                  ? const ShimmerGalleryGrid()
                                  : const ShimmerGalleryList();
                            }
                            if (state.results.isEmpty &&
                                state.status == SearchStatus.loaded) {
                              return Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.search_off,
                                        size: 64,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline),
                                    const SizedBox(height: 16),
                                    Text(s.noResultsFound),
                                    if (state.filter.keyword != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Text(
                                          s.tryDifferentKeywords,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            }

                            if (state.results.isEmpty &&
                                state.status == SearchStatus.error) {
                              return Center(child: Text(s.searchIncomplete));
                            }
                            return PageStorage(
                              key: ObjectKey(_resultScrollStorage),
                              bucket: _resultScrollStorage,
                              child: RefreshIndicator(
                                onRefresh: () async {
                                  context.read<SearchBloc>().add(PerformSearch(
                                      state.filter,
                                      saveHistory: widget.saveHistory));
                                  // Wait for the bloc to finish loading
                                  await context
                                      .read<SearchBloc>()
                                      .stream
                                      .firstWhere((s) =>
                                          s.status != SearchStatus.loading);
                                },
                                child: isGrid
                                    ? AdaptiveGalleryGrid(
                                        key:
                                            const PageStorageKey('search-grid'),
                                        controller: _gridScrollController,
                                        itemCount: state.results.length +
                                            (state.isLoadingMore ? 1 : 0),
                                        itemBuilder: (context, index) =>
                                            _buildResult(state, index,
                                                isGrid: true),
                                      )
                                    : ListView.builder(
                                        key:
                                            const PageStorageKey('search-list'),
                                        controller: _scrollController,
                                        physics:
                                            const AlwaysScrollableScrollPhysics(),
                                        padding: const EdgeInsets.all(8),
                                        itemCount: state.results.length +
                                            (state.isLoadingMore ? 1 : 0),
                                        itemBuilder: (context, index) =>
                                            _buildResult(state, index,
                                                isGrid: false),
                                      ),
                              ),
                            );
                          }

                          return Column(children: [
                            ..._searchNotices(state),
                            Expanded(child: resultsView()),
                          ]);
                        },
                      ),
                    ),
                ],
              )),
    );
  }

  Widget _buildResult(SearchState state, int index, {required bool isGrid}) {
    if (index >= state.results.length) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final gallery = state.results[index];
    final card = isGrid
        ? GalleryGridItem(gallery: gallery, onTap: () => _openGallery(gallery))
        : GalleryCard(gallery: gallery, onTap: () => _openGallery(gallery));
    if (gallery.gid != state.matchedGid) return card;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(S.of(context).gidMatch,
            key: const ValueKey('gid-match-label'),
            style: TextStyle(color: Theme.of(context).colorScheme.primary)),
      ),
      card,
    ]);
  }

  List<Widget> _searchNotices(SearchState state) {
    final s = S.of(context);
    Widget notice(String text, {VoidCallback? retry, String? key}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(children: [
            Expanded(
                child:
                    Text(text, style: Theme.of(context).textTheme.bodySmall)),
            if (retry != null)
              TextButton(
                  key: key == null ? null : ValueKey<String>(key),
                  onPressed: retry,
                  child: Text(s.retry)),
          ]),
        );
    return [
      if (state.gidStatus == SearchStatus.loaded && state.matchedGid == null)
        notice(s.gidNotFound),
      if (state.ordinaryStatus == SearchStatus.error)
        notice(s.ordinarySearchFailed,
            key: 'retry-ordinary-search',
            retry: () => context
                .read<SearchBloc>()
                .add(const RetrySearchSource(SearchSource.ordinary))),
      if (state.gidStatus == SearchStatus.error)
        notice(s.gidSearchFailed,
            key: 'retry-gid-search',
            retry: () => context
                .read<SearchBloc>()
                .add(const RetrySearchSource(SearchSource.gid))),
      if (state.loadMoreFailed)
        notice(s.searchPageFailed,
            key: 'retry-search-page',
            retry: () =>
                context.read<SearchBloc>().add(LoadMoreSearchResults())),
    ];
  }

  Future<void> _openGallery(GalleryPreview gallery) async {
    await Navigator.pushNamed(context, '/gallery', arguments: {
      'gid': gallery.gid,
      'token': gallery.token,
    });
    if (mounted) {
      context.read<SearchBloc>().add(RefreshSearchFavoriteMarks());
    }
  }

  Widget _buildActiveFilters() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          ..._selectedCategories.map((cat) => Chip(
                label: Text(cat, style: const TextStyle(fontSize: 12)),
                deleteIcon: const Icon(Icons.close, size: 14),
                onDeleted: () {
                  setState(() => _selectedCategories.remove(cat));
                },
                visualDensity: VisualDensity.compact,
              )),
          if (_minRating != null)
            Chip(
              avatar: const Icon(Icons.star, size: 14),
              label: Text('$_minRating+', style: const TextStyle(fontSize: 12)),
              deleteIcon: const Icon(Icons.close, size: 14),
              onDeleted: () => setState(() => _minRating = null),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  void _showFilterDialog() {
    // Local copy for dialog state
    var tempCategories = List<String>.from(_selectedCategories);
    int? tempRating = _minRating;
    final s = S.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              maxChildSize: 0.85,
              minChildSize: 0.4,
              expand: false,
              builder: (_, scrollCtrl) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: ListView(
                    controller: scrollCtrl,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(s.searchFilters,
                              style: Theme.of(context).textTheme.titleLarge),
                          TextButton(
                            onPressed: () {
                              setSheetState(() {
                                tempCategories.clear();
                                tempRating = null;
                              });
                            },
                            child: Text(s.reset),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Categories
                      Text(s.categories,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: AppConstants.categories.map((cat) {
                          final selected = tempCategories.contains(cat);
                          final color = Color(
                            AppConstants.categoryColors[cat] ?? 0xFF607D8B,
                          );
                          return FilterChip(
                            label: Text(cat),
                            selected: selected,
                            selectedColor: color.withOpacity(0.25),
                            showCheckmark: false,
                            onSelected: (val) {
                              setSheetState(() {
                                if (val) {
                                  tempCategories.add(cat);
                                } else {
                                  tempCategories.remove(cat);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 20),
                      // Min rating
                      Text(s.minimumRating,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [null, 2, 3, 4, 5].map((r) {
                          return ChoiceChip(
                            label: Text(r == null ? s.any : '$r+'),
                            selected: tempRating == r,
                            onSelected: (_) {
                              setSheetState(() => tempRating = r);
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: () {
                          setState(() {
                            _selectedCategories = tempCategories;
                            _minRating = tempRating;
                          });
                          Navigator.pop(ctx);
                          _performSearch();
                        },
                        child: Text(s.applyFilters),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSuggestions() {
    return Expanded(
      child: ListView.builder(
        itemCount: _historySuggestions.length + _suggestions.length,
        itemBuilder: (context, index) {
          if (index < _historySuggestions.length) {
            final query = _historySuggestions[index];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 20),
              title: Text(query),
              subtitle: Text(S.of(context).recentSearches),
              onTap: () => _applyHistorySuggestion(query),
            );
          }
          final suggestion = _suggestions[index - _historySuggestions.length];
          final tag = suggestion.tag;
          return ListTile(
            dense: true,
            leading: Icon(Icons.label_outline,
                size: 20, color: Theme.of(context).colorScheme.outline),
            title: Text('${tag.namespace}:${tag.key}'),
            subtitle: Text(
              tag.translation,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
            onTap: () => _applySuggestion(suggestion),
          );
        },
      ),
    );
  }

  Widget _buildSearchHistory(List<String> history) {
    final s = S.of(context);
    if (history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(_controller.text.trim().isEmpty
                ? s.enterKeywordToSearch
                : s.noResultsFound),
          ],
        ),
      );
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                  child: Text(s.recentSearches,
                      style: Theme.of(context).textTheme.titleMedium)),
              TextButton(
                onPressed: () =>
                    context.read<SearchBloc>().add(ClearSearchHistory()),
                child: Text(s.clear),
              ),
            ],
          ),
        ),
        ...history.map((keyword) => ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: Text(keyword),
              trailing: const Icon(Icons.north_west, size: 16),
              onTap: () {
                _controller.text = keyword;
                setState(() {});
                _performSearch();
              },
              onLongPress: () {
                context
                    .read<SearchBloc>()
                    .add(RemoveSearchHistoryItem(keyword));
              },
            )),
      ],
    );
  }
}
