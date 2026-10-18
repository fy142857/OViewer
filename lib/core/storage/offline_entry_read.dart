import 'dart:async';
import 'dart:typed_data';
import 'database.dart';
import 'offline_files.dart';
import '../services/reader_entry_diagnostics.dart';

/// A single-use verified read, overlapped with entry metadata and window setup.
/// No decoded image or bytes are retained beyond this entry's normal resource.
class OfflineEntryRead {
  final OfflineFiles files;
  final OfflinePage page;
  Future<Uint8List>? _pending;
  OfflineEntryRead(this.files, this.page,
      {ReaderEntryDiagnostics? diagnostics}) {
    diagnostics?.mark('prefetch_start');
    final pending = files.read(page.relativePath!, page.bytes, page.sha256!);
    _pending = pending;
    // Observe an abandoned read's error without hiding it from its consumer.
    unawaited(pending.then<void>((_) => diagnostics?.mark('prefetch_verified'),
        onError: (Object _, StackTrace __) {}));
  }

  bool matches(OfflinePage other) =>
      page.bookId == other.bookId &&
      page.pageIndex == other.pageIndex &&
      page.relativePath == other.relativePath &&
      page.sha256 == other.sha256 &&
      page.bytes == other.bytes;

  Future<Uint8List> take(OfflinePage actual) {
    final pending = matches(actual) ? _pending : null;
    _pending = null;
    return pending ??
        files.read(actual.relativePath!, actual.bytes, actual.sha256!);
  }

  void dispose() => _pending = null;
}
