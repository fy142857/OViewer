import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../blocs/history/history_bloc.dart';
import '../../blocs/history/history_event.dart';
import '../../blocs/history/history_state.dart';
import '../../core/l10n/s.dart';
import '../../core/network/eh_image_cache_manager.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    final history = context.read<HistoryBloc>();
    if (history.state.status == HistoryStatus.initial) {
      history.add(LoadHistory());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.history),
        actions: [
          BlocBuilder<HistoryBloc, HistoryState>(
            builder: (context, state) {
              if (state.entries.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: s.clearAll,
                onPressed: () => _showClearDialog(context),
              );
            },
          ),
        ],
      ),
      body: BlocBuilder<HistoryBloc, HistoryState>(
        builder: (context, state) => RefreshIndicator(
          onRefresh: () {
            final completer = Completer<void>();
            context.read<HistoryBloc>().add(LoadHistory(completer: completer));
            return completer.future;
          },
          child: _buildHistoryList(context, state),
        ),
      ),
    );
  }

  Widget _buildHistoryList(BuildContext context, HistoryState state) {
    final theme = Theme.of(context);
    final s = S.of(context);
    if (state.entries.isEmpty) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history,
                        size: 64, color: theme.colorScheme.outline),
                    const SizedBox(height: 16),
                    Text(s.noReadingHistory, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 4),
                    Text(
                      s.galleriesWillAppear,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ))
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
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
            onTap: () => Navigator.pushNamed(
              context,
              '/gallery',
              arguments: {
                'gid': entry.gid,
                'token': entry.token,
              },
            ),
          ),
        );
      },
    );
  }

  void _showClearDialog(BuildContext context) {
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

  String _timeAgo(DateTime dateTime) {
    final s = S.of(context);
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return s.justNow;
    if (diff.inMinutes < 60) return s.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return s.hoursAgo(diff.inHours);
    if (diff.inDays < 7) return s.daysAgo(diff.inDays);
    return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
  }
}
