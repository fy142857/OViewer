import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../../core/l10n/s.dart';
import '../../models/gallery_source.dart';
import '../../models/offline_book.dart';
import '../../repositories/offline_repository.dart';
import '../../repositories/history_repository.dart';
import 'reader_screen.dart';

/// Resolves the local source before constructing any network reader state.
class ReaderEntryScreen extends StatefulWidget {
  final int gid;
  final String token;
  final int? initialPage;
  final GallerySource? source;
  final String? offlineId;
  const ReaderEntryScreen(
      {super.key,
      required this.gid,
      required this.token,
      this.initialPage,
      this.source,
      this.offlineId});
  @override
  State<ReaderEntryScreen> createState() => _ReaderEntryScreenState();
}

class _ReaderEntryScreenState extends State<ReaderEntryScreen> {
  List<OfflineBook>? _choices;
  OfflineBook? _selected;
  bool _ready = false;
  bool _error = false;
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      if (!GetIt.I.isRegistered<OfflineRepository>()) {
        if (mounted) setState(() => _ready = true);
        return;
      }
      final repository = GetIt.I<OfflineRepository>();
      await repository.initialize();
      if (widget.offlineId != null) {
        final book = await repository.get(widget.offlineId!);
        if (book == null ||
            book.record.totalPages <= 0 ||
            book.status == OfflineStatus.deleting) {
          throw const OfflineFailure('missing_file');
        }
        await _select(book);
        return;
      }
      final matches = await repository.matching(widget.gid, widget.token,
          source: widget.source);
      if (matches.length > 1) {
        if (mounted) setState(() => _choices = matches);
      } else {
        await _select(matches.isEmpty ? null : matches.single);
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  Future<void> _select(OfflineBook? book) async {
    if (book != null && GetIt.I.isRegistered<HistoryRepository>()) {
      await GetIt.I<HistoryRepository>().recordOfflineVisit(book);
    }
    if (mounted)
      setState(() {
        _selected = book;
        _ready = true;
      });
  }

  @override
  Widget build(BuildContext context) {
    if (_ready)
      return ReaderScreen(
          gid: widget.gid,
          token: widget.token,
          initialPage: widget.initialPage,
          offlineBook: _selected);
    final s = S.of(context);
    return Scaffold(
        appBar: AppBar(title: Text(s.offlineRead)),
        body: _error
            ? Center(
                child: TextButton(
                    onPressed: () {
                      setState(() => _error = false);
                      _resolve();
                    },
                    child: Text(s.retry)))
            : _choices == null
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    Text(s.offlineChooseSource),
                    for (final book in _choices!)
                      ListTile(
                          title: Text(book.source!.label),
                          subtitle: Text(book.record.title),
                          onTap: () => _select(book))
                  ]));
  }
}
