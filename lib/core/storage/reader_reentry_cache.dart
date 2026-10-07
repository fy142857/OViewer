import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import '../../models/gallery_image.dart';
import '../../models/reader_index_page.dart';
import '../parser/gallery_detail_parser.dart';

typedef ReaderGalleryKey = (String, int, String);

/// Completed resources only. No request, codec, or widget survives its reader.
class ReaderReentryCache with WidgetsBindingObserver {
  static final shared = ReaderReentryCache();
  final int maxGalleries;
  final int maxPages;
  final int maxFrames;
  final int maxBytes;
  final DateTime Function() now;
  final changes = ValueNotifier<int>(0);
  final _galleries = <ReaderGalleryKey, ReaderSnapshot>{};
  final _frames = <(ReaderGalleryKey, int), ReaderRetainedFrame>{};
  int generation = 0;
  int memoryBytes = 0;
  int _serial = 0;
  bool _observing = false;

  ReaderReentryCache(
      {this.maxGalleries = 20,
      this.maxPages = 1000,
      this.maxFrames = 6,
      this.maxBytes = 64 * 1024 * 1024,
      DateTime Function()? now})
      : now = now ?? DateTime.now;

  void observeMemory() {
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  ReaderSnapshot? get(ReaderGalleryKey key) {
    final value = _galleries.remove(key);
    if (value == null) return null;
    _galleries[key] = value;
    for (final page in value.pages.keys.toList()) {
      if (!value.pages[page]!.expires.isAfter(now())) invalidatePage(key, page);
    }
    return value.pages.isEmpty ? null : value;
  }

  ReaderSnapshot prepare(ReaderGalleryKey key, ReaderIndexPage metadata,
      Map<int, ThumbnailInfo> thumbnails, int currentPage) {
    var value = _galleries.remove(key);
    if (value != null && value.metadata.totalPages != metadata.totalPages) {
      _dropFrames(key);
      value = null;
    }
    value ??= ReaderSnapshot(metadata, ++_serial);
    value.metadata = metadata;
    value.currentPage = currentPage;
    for (final entry in thumbnails.entries) {
      final old = value.thumbnails[entry.key];
      if (old != null && old.pageToken != entry.value.pageToken) {
        value.pages.remove(entry.key);
        _removeFrame((key, entry.key));
        value.revisions[entry.key] = ++_serial;
      }
      value.thumbnails[entry.key] = entry.value;
    }
    _galleries[key] = value;
    while (_galleries.length > maxGalleries) {
      final oldest = _galleries.keys.first;
      _galleries.remove(oldest);
      _dropFrames(oldest);
    }
    return value;
  }

  ReaderCacheTicket? ticket(ReaderGalleryKey key, int page) {
    final value = _galleries[key];
    if (value == null) return null;
    return ReaderCacheTicket(
        key, page, generation, value.serial, value.revisions[page] ?? 0);
  }

  bool accepts(ReaderCacheTicket t) {
    final value = _galleries[t.gallery];
    return t.generation == generation &&
        value?.serial == t.serial &&
        (value?.revisions[t.page] ?? 0) == t.revision;
  }

  ReaderRetainedFrame? frame(ReaderCacheTicket t) {
    if (!accepts(t)) return null;
    final page = _galleries[t.gallery]!.pages[t.page];
    if (page != null && !page.expires.isAfter(now())) {
      _removeFrame((t.gallery, t.page));
      return null;
    }
    final key = (t.gallery, t.page);
    final value = _frames.remove(key);
    if (value != null) _frames[key] = value;
    return value;
  }

  void complete(ReaderCacheTicket t, GalleryImage image, String cacheKey,
      ui.Image? frame, Uint8List bytes,
      {required bool durable, DateTime? expires}) {
    if (!accepts(t)) return;
    final snapshot = _galleries[t.gallery]!;
    snapshot.pages.remove(t.page);
    snapshot.pages[t.page] = ReaderCachedPage(image, cacheKey, durable,
        expires ?? now().add(const Duration(days: 7)));
    final key = (t.gallery, t.page);
    _removeFrame(key);
    final size =
        frame == null ? 0 : frame.width * frame.height * 4 + bytes.length;
    if (frame != null && size <= maxBytes && maxFrames > 0) {
      _frames[key] = ReaderRetainedFrame(frame.clone(), bytes, size);
      memoryBytes += size;
      while (_frames.length > maxFrames || memoryBytes > maxBytes) {
        final oldest = _frames.keys.firstWhere(
            (k) => k.$2 != _galleries[k.$1]?.currentPage,
            orElse: () => _frames.keys.first);
        _removeFrame(oldest);
      }
    }
    while (_galleries.values.fold<int>(0, (n, s) => n + s.pages.length) >
        maxPages) {
      final gallery =
          _galleries.entries.firstWhere((e) => e.value.pages.isNotEmpty);
      final page = gallery.value.pages.keys.first;
      gallery.value.pages.remove(page);
      _removeFrame((gallery.key, page));
      gallery.value.revisions[page] = ++_serial;
    }
    _notify();
  }

  void focus(ReaderGalleryKey key, int page) {
    final snapshot = get(key);
    if (snapshot == null) return;
    snapshot.currentPage = page;
    final value = snapshot.pages.remove(page);
    if (value != null) snapshot.pages[page] = value;
    final t = ticket(key, page);
    if (t != null) frame(t);
  }

  void invalidatePage(ReaderGalleryKey key, int page) {
    final snapshot = _galleries[key];
    snapshot?.pages.remove(page);
    snapshot?.revisions[page] = ++_serial;
    _removeFrame((key, page));
    _notify();
  }

  void removeGallery(int gid) {
    for (final key in _galleries.keys.where((k) => k.$2 == gid).toList()) {
      _galleries.remove(key);
      _dropFrames(key);
    }
    _notify();
  }

  void _dropFrames(ReaderGalleryKey key) {
    for (final k in _frames.keys.where((k) => k.$1 == key).toList()) {
      _removeFrame(k);
    }
  }

  void _removeFrame((ReaderGalleryKey, int) key) {
    final frame = _frames.remove(key);
    if (frame == null) return;
    memoryBytes -= frame.bytes;
    frame.image.dispose();
  }

  @override
  void didHaveMemoryPressure() => releaseFrames();

  void releaseFrames() {
    for (final key in _frames.keys.toList()) {
      _removeFrame(key);
    }
    _notify();
  }

  void clear() {
    generation++;
    _galleries.clear();
    releaseFrames();
  }

  void _notify() {
    changes.value++;
  }
}

class ReaderSnapshot {
  ReaderIndexPage metadata;
  final int serial;
  int currentPage = 0;
  final thumbnails = <int, ThumbnailInfo>{};
  final pages = <int, ReaderCachedPage>{};
  final revisions = <int, int>{};
  ReaderSnapshot(this.metadata, this.serial);
}

class ReaderCachedPage {
  final GalleryImage image;
  final String cacheKey;
  final bool durable;
  final DateTime expires;
  const ReaderCachedPage(this.image, this.cacheKey, this.durable, this.expires);
}

class ReaderCacheTicket {
  final ReaderGalleryKey gallery;
  final int page;
  final int generation;
  final int serial;
  final int revision;
  const ReaderCacheTicket(
      this.gallery, this.page, this.generation, this.serial, this.revision);
}

class ReaderRetainedFrame {
  final ui.Image image;
  final Uint8List encoded;
  final int bytes;
  const ReaderRetainedFrame(this.image, this.encoded, this.bytes);
}
