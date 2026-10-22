import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../blocs/download/download_bloc.dart';
import '../../blocs/download/download_event.dart';
import '../../blocs/download/download_state.dart';
import '../../core/l10n/s.dart';
import '../../core/network/offline_image_provider.dart';
import '../../models/gallery_source.dart';
import '../../models/offline_book.dart';

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

  Future<void> _delete(OfflineBook book) async {
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(s.delete),
                content: Text(s.offlineDeleteConfirm),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(s.cancel)),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(s.delete)),
                ]));
    if (confirmed == true && mounted)
      context.read<DownloadBloc>().add(DeleteDownload(book.id));
  }

  Future<void> _source(OfflineBook book) async {
    final s = S.of(context);
    final source = await showDialog<GallerySource>(
        context: context,
        builder: (ctx) =>
            SimpleDialog(title: Text(s.offlineChooseSource), children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(s.offlineSourceHint)),
              for (final source in GallerySource.values)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, source),
                    child: Text(source.label))
            ]));
    if (source == null || !mounted) return;
    try {
      await context
          .read<DownloadBloc>()
          .coordinator
          .confirmLegacy(book.id, source);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(s.offlineError(
                error is OfflineFailure ? error.code : 'storage'))));
    }
  }

  void _read(OfflineBook book) =>
      Navigator.pushNamed(context, '/reader', arguments: {
        'gid': book.record.gid,
        'token': book.record.token,
        'source': book.source,
        'offlineId': book.id,
      });
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
        appBar: AppBar(title: Text(s.downloads)),
        body: BlocConsumer<DownloadBloc, DownloadState>(
          listenWhen: (a, b) =>
              b.errorMessage != null && a.errorMessage != b.errorMessage,
          listener: (context, state) => ScaffoldMessenger.of(context)
              .showSnackBar(
                  SnackBar(content: Text(s.offlineError(state.errorMessage!)))),
          builder: (context, state) {
            if (state.status == DownloadListStatus.initial ||
                state.status == DownloadListStatus.loading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state.tasks.isEmpty)
              return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(state.status == DownloadListStatus.error
                    ? s.offlineError('storage')
                    : s.noDownloads),
                if (state.status == DownloadListStatus.error)
                  TextButton(
                      onPressed: () =>
                          context.read<DownloadBloc>().add(LoadDownloads()),
                      child: Text(s.retry)),
              ]));
            return ListView.builder(
                itemCount: state.tasks.length,
                itemBuilder: (context, index) {
                  final book = state.tasks[index];
                  final resuming = state.resumingIds.contains(book.id);
                  final completed = book.pages.where(
                      (p) => p.status == 'completed' && p.relativePath != null);
                  final active = const [
                    OfflineStatus.queued,
                    OfflineStatus.preparing,
                    OfflineStatus.downloading
                  ].contains(book.status);
                  return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: book.source != null &&
                                book.completedPages > 0 &&
                                book.status != OfflineStatus.deleting
                            ? () => _read(book)
                            : null,
                        child: Stack(children: [
                          Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 12, 60, 12),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          SizedBox(
                                              width: 52,
                                              height: 72,
                                              child: completed.isEmpty
                                                  ? const Icon(Icons.menu_book)
                                                  : Image(
                                                      image: OfflineImageProvider(
                                                          context
                                                              .read<
                                                                  DownloadBloc>()
                                                              .coordinator
                                                              .repository
                                                              .files,
                                                          completed.first),
                                                      fit: BoxFit.cover,
                                                      errorBuilder: (_, __,
                                                              ___) =>
                                                          const Icon(Icons
                                                              .broken_image))),
                                          const SizedBox(width: 12),
                                          Expanded(
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                Text(book.record.title,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis),
                                                Text(
                                                    '${book.source?.shortName ?? s.offlineSourceRequired} · ${resuming ? s.offlineResuming : s.offlineStatus(book.record.status)}'),
                                                Text(
                                                    '${book.completedPages}/${book.record.totalPages} · ${(book.bytes / 1048576).toStringAsFixed(1)} MB'),
                                              ])),
                                        ]),
                                    if (book.status !=
                                        OfflineStatus.completed) ...[
                                      const SizedBox(height: 8),
                                      LinearProgressIndicator(
                                          value: book.record.totalPages <= 0
                                              ? 0
                                              : book.completedPages /
                                                  book.record.totalPages),
                                    ],
                                    if (book.record.reason != null)
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(top: 6),
                                          child: Text(s.offlineError(
                                              book.record.reason!))),
                                    Wrap(
                                        alignment: WrapAlignment.end,
                                        spacing: 8,
                                        children: [
                                          if (book.source == null)
                                            TextButton(
                                                onPressed: () => _source(book),
                                                child: Text(
                                                    s.offlineChooseSource)),
                                          if (active || resuming)
                                            TextButton(
                                                onPressed: () => context
                                                    .read<DownloadBloc>()
                                                    .add(
                                                        PauseDownload(book.id)),
                                                child: Text(s.offlinePause)),
                                          if (resuming)
                                            TextButton(
                                                onPressed: null,
                                                child: Text(s.offlineResuming)),
                                          if (book.source != null &&
                                              !resuming &&
                                              !active &&
                                              !const [
                                                OfflineStatus.completed,
                                                OfflineStatus.deleting
                                              ].contains(book.status))
                                            TextButton(
                                                onPressed: () => context
                                                    .read<DownloadBloc>()
                                                    .add(ResumeDownload(
                                                        book.id)),
                                                child: Text(s.offlineResume)),
                                        ]),
                                  ])),
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: IconButton(
                              tooltip: s.delete,
                              onPressed: () => _delete(book),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                        ]),
                      ));
                });
          },
        ));
  }
}
