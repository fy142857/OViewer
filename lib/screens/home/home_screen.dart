import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logger/logger.dart';
import 'package:get_it/get_it.dart';
import '../../blocs/auth/auth_bloc.dart';
import '../../blocs/auth/auth_state.dart';
import '../../blocs/gallery_list/gallery_list_bloc.dart';
import '../../blocs/gallery_list/gallery_list_event.dart';
import '../../blocs/gallery_list/gallery_list_state.dart';
import '../../blocs/history/history_bloc.dart';
import '../../blocs/history/history_event.dart';
import '../../blocs/history/history_state.dart';
import '../../blocs/settings/settings_bloc.dart';
import '../../blocs/settings/settings_event.dart';
import '../../blocs/settings/settings_state.dart';
import '../../core/l10n/s.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../repositories/gallery_repository.dart';
import '../../widgets/gallery_card.dart';
import '../../widgets/gallery_grid_item.dart';
import '../../widgets/adaptive_gallery_grid.dart';
import '../../widgets/shimmer_loading.dart';
import '../../widgets/error_widget.dart';
import 'package:cached_network_image/cached_network_image.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  static final _log = Logger();
  late TabController _tabController;
  late Map<GalleryTab, GalleryListBloc> _galleryBlocs;
  int _currentIndex = 0;
  PageStorageBucket _scrollStorage = PageStorageBucket();

  final _tabs = const [
    GalleryTab.latest,
    GalleryTab.popular,
    GalleryTab.watched,
    GalleryTab.favorites,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _galleryBlocs = _createGalleryBlocs();
    _activateCurrentTab();
  }

  Map<GalleryTab, GalleryListBloc> _createGalleryBlocs() => {
        for (final tab in _tabs)
          if (tab != GalleryTab.watched)
            tab: GalleryListBloc(GetIt.I<GalleryRepository>(), initialTab: tab),
      };

  void _onTabChanged() {
    // TabBar taps and TabBarView swipes both change the selected index.
    // Animation notifications for that same index must not reload the page.
    if (_currentIndex == _tabController.index) return;
    setState(() => _currentIndex = _tabController.index);
    _activateCurrentTab();
  }

  void _activateCurrentTab() {
    final tab = _tabs[_currentIndex];
    if (tab == GalleryTab.watched) {
      context.read<HistoryBloc>().add(LoadHistory());
      return;
    }
    if (tab == GalleryTab.favorites &&
        !context.read<AuthBloc>().state.isLoggedIn) return;
    final bloc = _galleryBlocs[tab]!;
    if (bloc.state.status == GalleryListStatus.initial) {
      bloc.add(const FetchGalleries());
    }
  }

  void _resetGalleryTabs() {
    // Old requests stay attached to their old blocs and cannot populate the
    // new site's pages. Lists and their scroll positions are reset together.
    final previous = _galleryBlocs;
    setState(() {
      _galleryBlocs = _createGalleryBlocs();
      _scrollStorage = PageStorageBucket();
    });
    for (final bloc in previous.values) {
      unawaited(bloc.close());
    }
    _activateCurrentTab();
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final bloc in _galleryBlocs.values) {
      unawaited(bloc.close());
    }
    super.dispose();
  }

  /// Called by [NotificationListener] when any scroll event bubbles up.
  bool _handleScrollNotification(
      BuildContext context, ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! OverscrollNotification) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.pixels >= metrics.maxScrollExtent - 300) {
      final bloc = context.read<GalleryListBloc>();
      if (bloc.state.currentTab != _tabs[_currentIndex] ||
          bloc.state.status != GalleryListStatus.loaded) return false;
      if (bloc.state.isLoadingMore || bloc.state.hasReachedEnd) return false;
      _log.d('[Scroll] near bottom: pixels=${metrics.pixels.toInt()} '
          'max=${metrics.maxScrollExtent.toInt()}');
      bloc.add(LoadMoreGalleries());
    }
    return false; // don't consume — let RefreshIndicator still work
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(
        title: BlocBuilder<SettingsBloc, SettingsState>(
          buildWhen: (p, c) => p.useExHentai != c.useExHentai,
          builder: (_, settings) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Flexible(
                  child: Text('OViewer',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (settings.useExHentai) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'EX',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          Builder(
            builder: (context) {
              final isHistory = _tabs[_currentIndex] == GalleryTab.watched;
              if (isHistory) {
                // History tab: show clear-all button instead of view toggle
                return BlocBuilder<HistoryBloc, HistoryState>(
                  builder: (context, historyState) {
                    if (historyState.entries.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return IconButton(
                      icon: const Icon(Icons.delete_sweep),
                      tooltip: s.clearAll,
                      onPressed: () => _showClearHistoryDialog(context),
                    );
                  },
                );
              }
              // Other tabs: show view toggle
              return BlocBuilder<SettingsBloc, SettingsState>(
                buildWhen: (prev, curr) => prev.displayMode != curr.displayMode,
                builder: (context, settings) {
                  return IconButton(
                    icon: Icon(
                      settings.displayMode == 0
                          ? Icons.grid_view_rounded
                          : Icons.view_list_rounded,
                    ),
                    tooltip:
                        settings.displayMode == 0 ? s.gridView : s.listView,
                    onPressed: () {
                      context.read<SettingsBloc>().add(
                            UpdateDisplayMode(
                                settings.displayMode == 0 ? 1 : 0),
                          );
                    },
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.pushNamed(context, '/search'),
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.pushNamed(context, '/login'),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: s.tabLatest),
            Tab(text: s.tabPopular),
            Tab(text: s.tabHistory),
            Tab(text: s.tabFavorites),
          ],
        ),
      ),
      body: MultiBlocListener(
        listeners: [
          BlocListener<SettingsBloc, SettingsState>(
            listenWhen: (prev, curr) =>
                prev.useExHentai != curr.useExHentai ||
                !listEquals(prev.hiddenTags, curr.hiddenTags),
            listener: (context, _) {
              // Drop stale images and list entries from the previous site before
              // fetching the current tab from the newly selected site.
              PaintingBinding.instance.imageCache
                ..clear()
                ..clearLiveImages();
              _resetGalleryTabs();
            },
          ),
          BlocListener<AuthBloc, AuthState>(
            listenWhen: (prev, curr) => prev.isLoggedIn != curr.isLoggedIn,
            listener: (context, _) => _resetGalleryTabs(),
          ),
        ],
        child: PageStorage(
          bucket: _scrollStorage,
          child: TabBarView(
            key: const ValueKey('home-tab-pages'),
            controller: _tabController,
            children: [for (final tab in _tabs) _buildTabPage(tab)],
          ),
        ),
      ),
      drawer: _buildDrawer(),
    );
  }

  Widget _buildTabPage(GalleryTab tab) {
    if (tab == GalleryTab.watched) {
      return KeyedSubtree(
          key: const ValueKey('home-history-tab'),
          child: _buildHistoryContent(context));
    }
    final bloc = _galleryBlocs[tab]!;
    return BlocProvider.value(
      key: ObjectKey(bloc),
      value: bloc,
      child: BlocBuilder<GalleryListBloc, GalleryListState>(
        builder: (context, state) {
          if (tab == GalleryTab.favorites) {
            return BlocBuilder<AuthBloc, AuthState>(
              builder: (context, authState) {
                final s = S.of(context);
                if (authState.status == AuthStatus.unknown) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!authState.isLoggedIn) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.favorite_border,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 16),
                        Text(s.loginToFavorite,
                            style: Theme.of(context).textTheme.bodyLarge),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                            onPressed: () =>
                                Navigator.pushNamed(context, '/login'),
                            icon: const Icon(Icons.login),
                            label: Text(s.login)),
                      ],
                    ),
                  );
                }
                return _buildGalleryContent(context, state);
              },
            );
          }
          return _buildGalleryContent(context, state);
        },
      ),
    );
  }

  Widget _buildGalleryContent(BuildContext context, GalleryListState state) {
    final s = S.of(context);
    if (state.status == GalleryListStatus.initial) {
      return const SizedBox.expand();
    }
    // Loading state with shimmer
    if (state.status == GalleryListStatus.loading && state.galleries.isEmpty) {
      return BlocBuilder<SettingsBloc, SettingsState>(
        buildWhen: (p, c) => p.displayMode != c.displayMode,
        builder: (_, settings) {
          return settings.displayMode == 0
              ? const ShimmerGalleryList()
              : const ShimmerGalleryGrid();
        },
      );
    }

    // Error state
    if (state.status == GalleryListStatus.error && state.galleries.isEmpty) {
      return AppErrorWidget(
        message: state.errorMessage ?? s.failedToLoad,
        onRetry: () =>
            context.read<GalleryListBloc>().add(const FetchGalleries()),
      );
    }

    // Gallery list/grid (including empty state inside RefreshIndicator)
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) =>
          _handleScrollNotification(context, notification),
      child: RefreshIndicator(
        onRefresh: () {
          final completer = Completer<void>();
          context
              .read<GalleryListBloc>()
              .add(RefreshGalleries(completer: completer));
          return completer.future;
        },
        child: state.galleries.isEmpty
            ? ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_outlined,
                              size: 64,
                              color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 16),
                          Text(
                            s.noGalleriesFound,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : BlocBuilder<SettingsBloc, SettingsState>(
                buildWhen: (p, c) => p.displayMode != c.displayMode,
                builder: (_, settings) {
                  if (settings.displayMode == 1) {
                    return _buildGridView(context, state);
                  }
                  return _buildListView(context, state);
                },
              ),
      ),
    );
  }

  Widget _buildHistoryContent(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
    return BlocBuilder<HistoryBloc, HistoryState>(
      builder: (context, state) {
        if (state.status == HistoryStatus.initial ||
            state.status == HistoryStatus.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.entries.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history, size: 64, color: theme.colorScheme.outline),
                const SizedBox(height: 16),
                Text(s.noHistoryRecords, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  s.historyHint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          key: const PageStorageKey('home-history-list'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: state.entries.length,
          itemBuilder: (context, index) {
            final entry = state.entries[index];
            final hasProgress = entry.totalPages > 0;
            final progressPercent =
                hasProgress ? (entry.lastReadPage + 1) / entry.totalPages : 0.0;
            final progressText = hasProgress
                ? '${entry.lastReadPage + 1} / ${entry.totalPages}'
                : '';

            return ListTile(
              key: ValueKey(entry.gid),
              onLongPress: () => _showHistoryEntryMenu(entry.gid),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 50,
                  height: 68,
                  child: CachedNetworkImage(
                    imageUrl: entry.thumbUrl,
                    fit: BoxFit.cover,
                    cacheManager: EhImageCacheManager.instance,
                    errorWidget: (_, __, ___) => Container(
                      color: theme.colorScheme.surfaceVariant,
                      child: const Icon(Icons.broken_image, size: 20),
                    ),
                  ),
                ),
              ),
              title: Text(
                entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (progressText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progressPercent,
                              minHeight: 3,
                              backgroundColor: theme.colorScheme.surfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          progressText,
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    _timeAgo(entry.lastReadAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              onTap: () => _navigateToGallery(entry.gid, entry.token),
            );
          },
        );
      },
    );
  }

  Future<void> _showHistoryEntryMenu(int gid) async {
    final s = S.of(context);
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.delete,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.cancel),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (remove == true) {
      context.read<HistoryBloc>().add(DeleteHistoryEntry(gid));
    }
  }

  String _timeAgo(DateTime dateTime) {
    final s = S.of(context);
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return s.justNow;
    if (diff.inMinutes < 60) return s.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return s.hoursAgo(diff.inHours);
    if (diff.inDays < 7) return s.daysAgo(diff.inDays);
    return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
  }

  void _showClearHistoryDialog(BuildContext context) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.clearHistory),
        content: Text(s.clearHistoryConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () {
              context.read<HistoryBloc>().add(ClearAllHistory());
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(s.clearAllButton),
          ),
        ],
      ),
    );
  }

  Widget _buildListView(BuildContext context, GalleryListState state) {
    return ListView.builder(
      key: PageStorageKey('home-${state.currentTab.name}-list'),
      padding: const EdgeInsets.all(8),
      itemCount: state.galleries.length + (state.hasReachedEnd ? 0 : 1),
      itemBuilder: (context, index) {
        if (index >= state.galleries.length) {
          return _buildLoadMoreIndicator(context, state);
        }
        final gallery = state.galleries[index];
        return GalleryCard(
          gallery: gallery,
          onTap: () => _navigateToGallery(gallery.gid, gallery.token),
        );
      },
    );
  }

  Widget _buildGridView(BuildContext context, GalleryListState state) {
    return AdaptiveGalleryGrid(
      key: PageStorageKey('home-${state.currentTab.name}-grid'),
      itemCount: state.galleries.length + (state.hasReachedEnd ? 0 : 1),
      itemBuilder: (context, index) {
        if (index >= state.galleries.length) {
          return _buildLoadMoreIndicator(context, state);
        }
        final gallery = state.galleries[index];
        return GalleryGridItem(
          gallery: gallery,
          onTap: () => _navigateToGallery(gallery.gid, gallery.token),
        );
      },
    );
  }

  Widget _buildLoadMoreIndicator(BuildContext context, GalleryListState state) {
    final s = S.of(context);
    // Show tap-to-retry on error
    if (state.errorMessage != null && !state.isLoadingMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: GestureDetector(
            onTap: () =>
                context.read<GalleryListBloc>().add(LoadMoreGalleries()),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 4),
                Text(
                  s.loadFailedTapRetry,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  void _navigateToGallery(int gid, String token) async {
    await Navigator.pushNamed(context, '/gallery', arguments: {
      'gid': gid,
      'token': token,
    });
    if (mounted) {
      for (final bloc in _galleryBlocs.values) {
        bloc.add(RefreshFavoriteMarks());
      }
      // Refresh history so the History tab stays up-to-date
      context.read<HistoryBloc>().add(LoadHistory());
    }
  }

  Widget _buildDrawer() {
    final s = S.of(context);
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'OViewer',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'E-Hentai Manga Reader',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimaryContainer
                            .withOpacity(0.7),
                      ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.home),
            title: Text(s.home),
            selected: true,
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.favorite),
            title: Text(s.favorites),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/favorites');
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(s.history),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/history');
            },
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(s.downloads),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/downloads');
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings),
            title: Text(s.settings),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/settings');
            },
          ),
        ],
      ),
    );
  }
}
