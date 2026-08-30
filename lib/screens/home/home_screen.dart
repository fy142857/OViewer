import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:logger/logger.dart';
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
import '../../widgets/gallery_card.dart';
import '../../widgets/gallery_grid_item.dart';
import '../../widgets/shimmer_loading.dart';
import '../../widgets/error_widget.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  static final _log = Logger();
  late TabController _tabController;

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
    context.read<GalleryListBloc>().add(const FetchGalleries());
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) return;
    final tab = _tabs[_tabController.index];
    // Always update currentTab in GalleryListBloc so the builder knows which
    // tab is active.  For the history tab we also load local records.
    context.read<GalleryListBloc>().add(SwitchGalleryTab(tab));
    if (tab == GalleryTab.watched) {
      context.read<HistoryBloc>().add(LoadHistory());
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Called by [NotificationListener] when any scroll event bubbles up.
  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification &&
        notification is! OverscrollNotification) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.pixels >= metrics.maxScrollExtent - 300) {
      final bloc = context.read<GalleryListBloc>();
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
                const Text('OViewer'),
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
          BlocBuilder<GalleryListBloc, GalleryListState>(
            buildWhen: (p, c) => p.currentTab != c.currentTab,
            builder: (context, galleryState) {
              final isHistory = galleryState.currentTab == GalleryTab.watched;
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
      body: BlocListener<SettingsBloc, SettingsState>(
          listenWhen: (prev, curr) => prev.useExHentai != curr.useExHentai,
          listener: (context, _) {
            // Drop stale images and list entries from the previous site before
            // fetching the current tab from the newly selected site.
            PaintingBinding.instance.imageCache
              ..clear()
              ..clearLiveImages();
            context
                .read<GalleryListBloc>()
                .add(const FetchGalleries(clearExisting: true));
          },
          child: BlocBuilder<GalleryListBloc, GalleryListState>(
            builder: (context, state) {
              // History tab: show local browsing history
              if (state.currentTab == GalleryTab.watched) {
                return _buildHistoryContent(context);
              }

              // Login guard for Favorites tab (reactive to auth changes)
              if (state.currentTab == GalleryTab.favorites) {
                return BlocBuilder<AuthBloc, AuthState>(
                  builder: (context, authState) {
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
                              label: Text(s.login),
                            ),
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
          )),
      drawer: _buildDrawer(),
    );
  }

  Widget _buildGalleryContent(BuildContext context, GalleryListState state) {
    final s = S.of(context);
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
      onNotification: _handleScrollNotification,
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
                    return _buildGridView(state);
                  }
                  return _buildListView(state);
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
        if (state.status == HistoryStatus.loading) {
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

            return Slidable(
              key: ValueKey(entry.gid),
              endActionPane: ActionPane(
                motion: const BehindMotion(),
                children: [
                  SlidableAction(
                    onPressed: (_) {
                      context
                          .read<HistoryBloc>()
                          .add(DeleteHistoryEntry(entry.gid));
                    },
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    icon: Icons.delete,
                    label: s.delete,
                  ),
                ],
              ),
              child: ListTile(
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
                                backgroundColor:
                                    theme.colorScheme.surfaceVariant,
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
              ),
            );
          },
        );
      },
    );
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

  Widget _buildListView(GalleryListState state) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: state.galleries.length + (state.hasReachedEnd ? 0 : 1),
      itemBuilder: (context, index) {
        if (index >= state.galleries.length) {
          return _buildLoadMoreIndicator(state);
        }
        final gallery = state.galleries[index];
        return GalleryCard(
          gallery: gallery,
          onTap: () => _navigateToGallery(gallery.gid, gallery.token),
        );
      },
    );
  }

  Widget _buildGridView(GalleryListState state) {
    return MasonryGridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      padding: const EdgeInsets.all(8),
      itemCount: state.galleries.length + (state.hasReachedEnd ? 0 : 1),
      itemBuilder: (context, index) {
        if (index >= state.galleries.length) {
          return _buildLoadMoreIndicator(state);
        }
        final gallery = state.galleries[index];
        return SizedBox(
          height: 260,
          child: GalleryGridItem(
            gallery: gallery,
            onTap: () => _navigateToGallery(gallery.gid, gallery.token),
          ),
        );
      },
    );
  }

  Widget _buildLoadMoreIndicator(GalleryListState state) {
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
      context.read<GalleryListBloc>().add(RefreshFavoriteMarks());
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
