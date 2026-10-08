import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/auth/auth_state.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/favorites/favorites_bloc.dart';
import '../blocs/favorites/favorites_state.dart';
import '../blocs/favorites/favorites_event.dart';
import '../models/gallery_preview.dart';
import '../core/l10n/s.dart';
import 'adaptive_gallery_grid.dart';
import 'gallery_grid_item.dart';
import 'gallery_card.dart';
import 'shimmer_loading.dart';
import 'error_widget.dart';

class FavoritesContent extends StatefulWidget {
  final bool active, allowGrid, allowRemoval;
  final String storageKey;
  const FavoritesContent(
      {super.key,
      this.active = true,
      this.allowGrid = false,
      this.allowRemoval = false,
      required this.storageKey});
  @override
  State<FavoritesContent> createState() => _FavoritesContentState();
}

class _FavoritesContentState extends State<FavoritesContent> {
  late FavoritesBloc _bloc;
  @override
  void initState() {
    super.initState();
    _bloc = context.read<FavoritesBloc>();
    if (widget.active) _bloc.attachView();
  }

  @override
  void didUpdateWidget(FavoritesContent old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) {
      if (widget.active) {
        _bloc.attachView();
      } else {
        _bloc.detachView();
      }
    }
  }

  @override
  void dispose() {
    if (widget.active) _bloc.detachView();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final auth = context.watch<AuthBloc>().state;
    if (auth.status == AuthStatus.unknown) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!auth.isLoggedIn) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.favorite_border, size: 64),
        const SizedBox(height: 16),
        Text(s.loginToFavorite),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/login'),
            icon: const Icon(Icons.login),
            label: Text(s.login)),
      ]));
    }
    final grid = widget.allowGrid &&
        context.watch<SettingsBloc>().state.displayMode == 1;
    return BlocConsumer<FavoritesBloc, FavoritesState>(
        listenWhen: (a, b) =>
            a.errorMessage != b.errorMessage && b.errorMessage != null,
        listener: (context, state) {
          if (!widget.active || ModalRoute.of(context)?.isCurrent == false) {
            return;
          }
          if (state.errorMessage == 'favoriteFilterSaveFailed' ||
              state.errorMessage == 'favoriteActionFailed') {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(state.errorMessage == 'favoriteFilterSaveFailed'
                    ? s.favoriteFilterSaveFailed
                    : s.favoriteActionFailed)));
          }
        },
        builder: (context, state) {
          if ((state.status == FavoritesStatus.initial ||
                  state.status == FavoritesStatus.loading) &&
              state.favorites.isEmpty) {
            return grid
                ? const ShimmerGalleryGrid()
                : const ShimmerGalleryList();
          }
          if (state.status == FavoritesStatus.error &&
              state.favorites.isEmpty) {
            return AppErrorWidget(
                message: s.failedToLoad,
                onRetry: () => _bloc.add(const LoadFavorites()));
          }
          Widget footer() => state.isLoadingMore
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()))
              : state.loadMoreFailed || state.status == FavoritesStatus.error
                  ? Center(
                      child: TextButton(
                          onPressed: () => _bloc.add(state.loadMoreFailed
                              ? LoadMoreFavorites()
                              : const LoadFavorites()),
                          child: Text(s.retry)))
                  : const SizedBox.shrink();
          final key = PageStorageKey(
              '${widget.storageKey}-${state.scopeRevision}-${grid ? 'grid' : 'list'}');
          Widget body;
          if (state.favorites.isEmpty) {
            body = ListView(
                key: key,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 80),
                children: [
                  SizedBox(
                      height: MediaQuery.of(context).size.height * .5,
                      child: Center(
                          child: Text(state.category < 0
                              ? s.noCloudFavorites
                              : s.noFavoritesInCategory))),
                  footer(),
                ]);
          } else if (grid) {
            body = Column(children: [
              Expanded(
                  child: AdaptiveGalleryGrid(
                      key: key,
                      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
                      itemCount: state.favorites.length,
                      itemBuilder: (_, index) => GalleryGridItem(
                          gallery: state.favorites[index],
                          onTap: () => _open(state.favorites[index])))),
              footer()
            ]);
          } else {
            body = ListView.builder(
                key: key,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
                itemCount: state.favorites.length + 1,
                itemBuilder: (_, index) {
                  if (index == state.favorites.length) return footer();
                  final gallery = state.favorites[index];
                  final card = GalleryCard(
                      gallery: gallery, onTap: () => _open(gallery));
                  if (!widget.allowRemoval) return card;
                  return Slidable(
                      key: ValueKey(gallery.gid),
                      endActionPane:
                          ActionPane(motion: const BehindMotion(), children: [
                        SlidableAction(
                            onPressed: (_) => _bloc.add(RemoveFavorite(
                                gid: gallery.gid, token: gallery.token)),
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            icon: Icons.delete,
                            label: s.remove)
                      ]),
                      child: card);
                });
          }
          return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (widget.active &&
                    notification.metrics.axis == Axis.vertical &&
                    (notification is ScrollUpdateNotification ||
                        notification is OverscrollNotification) &&
                    notification.metrics.extentAfter < 300 &&
                    !state.loadMoreFailed) _bloc.add(LoadMoreFavorites());
                return false;
              },
              child: RefreshIndicator(
                  onRefresh: () {
                    final done = Completer<void>();
                    _bloc.add(RefreshFavorites(completer: done));
                    return done.future;
                  },
                  child: body));
        });
  }

  void _open(GalleryPreview gallery) => Navigator.pushNamed(context, '/gallery',
      arguments: {'gid': gallery.gid, 'token': gallery.token});
}
