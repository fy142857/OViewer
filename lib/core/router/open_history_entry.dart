import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../l10n/s.dart';
import '../storage/database.dart';
import '../../models/gallery_source.dart';
import '../../repositories/offline_repository.dart';
import '../services/reader_entry_diagnostics.dart';

/// Both the home history tab and the standalone history page use this resolver.
Future<void> openHistoryEntry(BuildContext context, HistoryEntry entry) async {
  final source = GallerySource.parse(entry.source);
  var route = '/gallery';
  final diagnostics = ReaderEntryDiagnostics();
  try {
    if (GetIt.I.isRegistered<OfflineRepository>()) {
      final repository = GetIt.I<OfflineRepository>();
      await repository.initialize();
      if ((await repository.matching(entry.gid, entry.token, source: source))
          .isNotEmpty) route = '/reader';
    }
    if (!context.mounted || route != '/reader') diagnostics.dispose();
    if (context.mounted)
      await Navigator.pushNamed(context, route, arguments: {
        'gid': entry.gid,
        'token': entry.token,
        'source': source,
        if (route == '/reader') 'entryDiagnostics': diagnostics,
      });
  } catch (_) {
    diagnostics.dispose();
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).offlineError('storage'))));
  }
}
