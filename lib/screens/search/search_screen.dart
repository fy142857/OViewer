import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../blocs/search/search_bloc.dart';
import '../../blocs/search/search_event.dart';
import '../../blocs/search/search_state.dart';
import '../../core/constants/app_constants.dart';
import '../../core/l10n/s.dart';
import '../../core/utils/eh_url_parser.dart';
import '../../models/search_filter.dart';
import '../../repositories/search_repository.dart';
import '../../repositories/tag_translation_repository.dart';
import '../../widgets/gallery_card.dart';
import '../../widgets/shimmer_loading.dart';

class SearchScreen extends StatelessWidget {
  final String? initialKeyword;
  final bool saveHistory;

  const SearchScreen({super.key, this.initialKeyword, this.saveHistory = true});

  @override
  Widget build(BuildContext context) {
    // Nested searches keep their own results, filters and pagination until pop.
    return BlocProvider(
      create: (_) => SearchBloc(GetIt.I<SearchRepository>()),
      child: _SearchView(
        initialKeyword: initialKeyword,
        saveHistory: saveHistory,
      ),
    );
  }
}

class _SearchView extends StatefulWidget {
  final String? initialKeyword;
  final bool saveHistory;

  const _SearchView({this.initialKeyword, required this.saveHistory});

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  List<String> _selectedCategories = [];
  int? _minRating;
  bool _showHistory = true;
  List<TagSearchResult> _suggestions = [];

  @override
  void initState() {
    super.initState();
    if (widget.initialKeyword != null) {
      _controller.text = widget.initialKeyword!;
      _showHistory = false;
      _performSearch();
    }
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && !_showHistory) {
        setState(() => _showHistory = true);
        context.read<SearchBloc>().add(LoadSearchHistory());
      }
    });
    context.read<SearchBloc>().add(LoadSearchHistory());
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      final bloc = context.read<SearchBloc>();
      if (bloc.state.isLoadingMore || bloc.state.hasReachedEnd) return;
      bloc.add(LoadMoreSearchResults());
    }
  }

  void _performSearch() {
    final keyword = _controller.text.trim();

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
      _showHistory = false;
      _suggestions = [];
    });
    _focusNode.unfocus();
    context.read<SearchBloc>().add(PerformSearch(SearchFilter(
      keyword: keyword.isNotEmpty ? keyword : null,
      categories: _selectedCategories,
      minRating: _minRating,
    ), saveHistory: widget.saveHistory));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _updateSuggestions() {
    final text = _controller.text;
    // Extract the last token (after last space) for suggestion
    final lastToken = text.contains(' ')
        ? text.substring(text.lastIndexOf(' ') + 1)
        : text;
    if (lastToken.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    try {
      final repo = GetIt.I<TagTranslationRepository>();
      setState(() => _suggestions = repo.searchByTranslation(lastToken));
    } catch (_) {
      setState(() => _suggestions = []);
    }
  }

  void _applySuggestion(TagSearchResult result) {
    final text = _controller.text;
    final tag = '${result.namespace}:"${result.key}\$"';
    // Replace the last token with the selected tag
    final lastSpaceIndex = text.lastIndexOf(' ');
    final prefix =
        lastSpaceIndex >= 0 ? text.substring(0, lastSpaceIndex + 1) : '';
    _controller.text = '$prefix$tag ';
    setState(() => _suggestions = []);
    // Refocus to scroll TextField to the end
    _focusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: widget.initialKeyword == null,
          decoration: InputDecoration(
            hintText: s.searchGalleries,
            border: InputBorder.none,
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _controller.clear();
                      context.read<SearchBloc>().add(ClearSearch());
                      setState(() {
                        _showHistory = true;
                        _suggestions = [];
                      });
                    },
                  )
                : null,
          ),
          onChanged: (_) {
            _updateSuggestions();
          },
          onSubmitted: (_) => _performSearch(),
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'filter',
            onPressed: _showFilterDialog,
            child: const Icon(Icons.tune),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'search',
            onPressed: _performSearch,
            child: const Icon(Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          // Active filters row
          if (_selectedCategories.isNotEmpty || _minRating != null)
            _buildActiveFilters(),
          // Tag suggestions or Content
          if (_suggestions.isNotEmpty)
            _buildSuggestions()
          else
            Expanded(
            child: BlocBuilder<SearchBloc, SearchState>(
              builder: (context, state) {
                if (_showHistory) {
                  return _buildSearchHistory(state.searchHistory);
                }
                if (state.status == SearchStatus.loading &&
                    state.results.isEmpty) {
                  return const ShimmerGalleryList();
                }
                if (state.results.isEmpty &&
                    state.status == SearchStatus.loaded) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 16),
                        Text(s.noResultsFound),
                        if (state.filter.keyword != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              s.tryDifferentKeywords,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    context
                        .read<SearchBloc>()
                        .add(PerformSearch(state.filter));
                    // Wait for the bloc to finish loading
                    await context
                        .read<SearchBloc>()
                        .stream
                        .firstWhere((s) =>
                            s.status != SearchStatus.loading);
                  },
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: state.results.length +
                        (state.isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= state.results.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child:
                              Center(child: CircularProgressIndicator()),
                        );
                      }
                      final gallery = state.results[index];
                      return GalleryCard(
                        gallery: gallery,
                        onTap: () async {
                          await Navigator.pushNamed(
                            context,
                            '/gallery',
                            arguments: {
                              'gid': gallery.gid,
                              'token': gallery.token,
                            },
                          );
                          if (mounted) {
                            context
                                .read<SearchBloc>()
                                .add(RefreshSearchFavoriteMarks());
                          }
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
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
              label: Text('$_minRating+',
                  style: const TextStyle(fontSize: 12)),
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
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          Text(s.searchFilters,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge),
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
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children:
                            AppConstants.categories.map((cat) {
                          final selected =
                              tempCategories.contains(cat);
                          final color = Color(
                            AppConstants.categoryColors[cat] ??
                                0xFF607D8B,
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
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [null, 2, 3, 4, 5].map((r) {
                          return ChoiceChip(
                            label: Text(
                                r == null ? s.any : '$r+'),
                            selected: tempRating == r,
                            onSelected: (_) {
                              setSheetState(
                                  () => tempRating = r);
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
        itemCount: _suggestions.length,
        itemBuilder: (context, index) {
          final suggestion = _suggestions[index];
          return ListTile(
            dense: true,
            leading: Icon(Icons.label_outline,
                size: 20, color: Theme.of(context).colorScheme.outline),
            title: Text('${suggestion.namespace}:${suggestion.key}'),
            subtitle: Text(
              suggestion.translation,
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
                size: 64,
                color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(s.enterKeywordToSearch),
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
              Text(s.recentSearches,
                  style: Theme.of(context).textTheme.titleMedium),
              TextButton(
                onPressed: () => context
                    .read<SearchBloc>()
                    .add(ClearSearchHistory()),
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
