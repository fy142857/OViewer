import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../blocs/download/download_bloc.dart';
import '../../blocs/download/download_event.dart';
import '../../blocs/download/download_state.dart';
import '../../core/l10n/s.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../models/download_task.dart';
import '../../widgets/loading_indicator.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  @override
  void initState() {
    super.initState();
    context.read<DownloadBloc>().add(LoadDownloads());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.downloads)),
      body: BlocBuilder<DownloadBloc, DownloadState>(
        builder: (context, state) {
          if (state.status == DownloadListStatus.loading &&
              state.tasks.isEmpty) {
            return const LoadingIndicator();
          }
          if (state.tasks.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_done,
                      size: 64, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(s.noDownloads, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 4),
                  Text(
                    s.downloadFromDetail,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: state.tasks.length,
            itemBuilder: (context, index) {
              final task = state.tasks[index];
              return _buildDownloadItem(context, task, state);
            },
          );
        },
      ),
    );
  }

  Widget _buildDownloadItem(
      BuildContext context, DownloadTask task, DownloadState state) {
    final theme = Theme.of(context);
    final isActive = state.activeDownloads.contains(task.gid);

    return Slidable(
      key: ValueKey(task.gid),
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        children: [
          SlidableAction(
            onPressed: (_) {
              context.read<DownloadBloc>().add(DeleteDownload(task.gid));
            },
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: S.of(context).delete,
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
              imageUrl: task.thumbUrl,
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
          task.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 4,
                backgroundColor: theme.colorScheme.surfaceVariant,
                color: _statusColor(task.status),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(_statusIcon(task.status),
                    size: 14, color: _statusColor(task.status)),
                const SizedBox(width: 4),
                Text(
                  _statusText(task),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _statusColor(task.status),
                  ),
                ),
                const Spacer(),
                Text(
                  '${task.downloadedPages}/${task.totalPages}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ],
        ),
        trailing: _buildActionButton(context, task, isActive),
        onTap: task.isComplete
            ? () {
                Navigator.pushNamed(context, '/reader', arguments: {
                      'gid': task.gid,
                      'token': task.token,
                    });
              }
            : null,
      ),
    );
  }

  Widget? _buildActionButton(
      BuildContext context, DownloadTask task, bool isActive) {
    switch (task.status) {
      case DownloadStatus.downloading:
        return IconButton(
          icon: const Icon(Icons.pause),
          onPressed: () =>
              context.read<DownloadBloc>().add(PauseDownload(task.gid)),
        );
      case DownloadStatus.paused:
      case DownloadStatus.failed:
        return IconButton(
          icon: const Icon(Icons.play_arrow),
          onPressed: () => context.read<DownloadBloc>().add(
                ResumeDownload(gid: task.gid, token: task.token),
              ),
        );
      case DownloadStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case DownloadStatus.pending:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
    }
  }

  IconData _statusIcon(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.downloading:
        return Icons.downloading;
      case DownloadStatus.paused:
        return Icons.pause_circle;
      case DownloadStatus.completed:
        return Icons.check_circle;
      case DownloadStatus.failed:
        return Icons.error;
      case DownloadStatus.pending:
        return Icons.hourglass_empty;
    }
  }

  Color _statusColor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.downloading:
        return Colors.blue;
      case DownloadStatus.paused:
        return Colors.orange;
      case DownloadStatus.completed:
        return Colors.green;
      case DownloadStatus.failed:
        return Colors.red;
      case DownloadStatus.pending:
        return Colors.grey;
    }
  }

  String _statusText(DownloadTask task) {
    final s = S.of(context);
    switch (task.status) {
      case DownloadStatus.downloading:
        return s.downloading((task.progress * 100).toInt());
      case DownloadStatus.paused:
        return s.paused;
      case DownloadStatus.completed:
        return s.completed;
      case DownloadStatus.failed:
        return s.failedTapRetry;
      case DownloadStatus.pending:
        return s.pending;
    }
  }
}
