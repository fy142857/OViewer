import 'dart:typed_data';

/// Local-only export handle. Completed cache files are preferred; bytes are
/// retained only when persistence failed, and released with the image stream.
class ReaderPageResource {
  final Future<Uint8List?> Function() readCache;
  Uint8List? _fallback;

  ReaderPageResource(this.readCache, {Uint8List? fallback})
      : _fallback = fallback;

  Future<Uint8List> snapshot() async {
    final fallback = _fallback;
    Uint8List? cached;
    try {
      cached = await readCache().timeout(const Duration(seconds: 10));
    } catch (_) {}
    final bytes = cached ?? fallback;
    if (bytes == null) throw StateError('page_resource_unavailable');
    return Uint8List.fromList(bytes);
  }

  void releaseMemory() => _fallback = null;
}
