import 'dart:async';
import 'dart:io' show FileSystemEntityType;
import 'package:flutter/foundation.dart';
import 'package:file/file.dart' show File;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// Repository interfaces expose this type, but 3.3.x does not export it.
// ignore: implementation_imports
import 'package:flutter_cache_manager/src/storage/cache_object.dart';
// Config exposes this interface without re-exporting it.
// ignore: implementation_imports
import 'package:flutter_cache_manager/src/storage/file_system/file_system.dart';
import 'package:path/path.dart' as p;

/// One serialized metadata/eviction queue for the existing image cache only.
/// Active consumers pin their keys until they have read the completed bytes.
class ImageCacheQuota extends CacheInfoRepository {
  final CacheInfoRepository delegate;
  final FileSystem files;
  final ValueNotifier<int> changes = ValueNotifier(0);
  final Map<String, int> _pins = {};
  Future<bool>? _opening;
  Future<void> _tail = Future.value();
  Future<void>? _maintenance;
  bool _dirty = false;
  bool _deferred = false;
  bool _disposed = false;
  int _paused = 0;
  int limitBytes;
  bool cleanupFailed = false;

  ImageCacheQuota(this.delegate, this.files, {required this.limitBytes});

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) async {
      await open();
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> drain() async {
    // CacheManager starts its metadata write just before returning a file.
    await Future<void>.value();
    await _tail;
  }

  void pin(String key) => _pins[key] = (_pins[key] ?? 0) + 1;
  Future<void> unpin(String key, {bool check = false}) async {
    final count = (_pins[key] ?? 1) - 1;
    if (count == 0) {
      _pins.remove(key);
    } else {
      _pins[key] = count;
    }
    await drain();
    if (check || _deferred || _dirty || _maintenance != null) {
      await maintainQuietly();
    }
  }

  void pause() => _paused++;
  Future<void> resume() async {
    _paused--;
    await maintainQuietly();
  }

  Future<void> setLimit(int bytes) async {
    if (bytes <= 0) throw ArgumentError.value(bytes, 'bytes');
    limitBytes = bytes;
    await enforce();
  }

  Future<void> maintainQuietly() async {
    try {
      await enforce();
    } catch (_) {/* Exposed in settings; never break decoding. */}
  }

  Future<void> enforce() {
    if (_disposed) return Future.value();
    _dirty = true;
    return _maintenance ??= _maintain().whenComplete(() => _maintenance = null);
  }

  Future<void> _maintain() async {
    try {
      while (_dirty) {
        _dirty = false;
        await _serial(_trim);
      }
      cleanupFailed = false;
    } catch (_) {
      cleanupFailed = true;
      _deferred = true;
      rethrow;
    } finally {
      if (!_disposed) changes.value++;
    }
  }

  Future<void> _trim() async {
    if (_paused > 0) {
      _deferred = true;
      return;
    }
    final root = (await files.createFile('__quota_probe__')).parent;
    final entries = await delegate.getAllObjects();
    final byPath = <String, CacheObject>{};
    var processed = 0;
    for (final entry in entries) {
      if (++processed % 64 == 0) await Future<void>.delayed(Duration.zero);
      final path = p.normalize(
          p.absolute((await files.createFile(entry.relativePath)).path));
      if (!p.isWithin(p.absolute(root.path), path)) {
        throw const FormatException('Image cache path outside its directory');
      }
      byPath[path] = entry;
    }
    final candidates =
        <({String path, int bytes, DateTime touched, CacheObject? entry})>[];
    var total = 0;
    if (await root.exists()) {
      await for (final file in root.list(recursive: true, followLinks: false)) {
        if (++processed % 64 == 0) await Future<void>.delayed(Duration.zero);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        final path = p.normalize(p.absolute(file.path));
        final entry = byPath[path];
        total += stat.size;
        candidates.add((
          path: path,
          bytes: stat.size,
          touched: entry?.touched ?? stat.modified,
          entry: entry
        ));
      }
    }
    candidates.sort((a, b) => a.touched.compareTo(b.touched));
    Object? failure;
    StackTrace? failureStack;
    for (final candidate in candidates) {
      if (++processed % 64 == 0) await Future<void>.delayed(Duration.zero);
      if (total <= limitBytes) break;
      final entry = candidate.entry;
      // Unregistered files may still be downloading. Revisit on last unpin.
      if (entry == null ? _pins.isNotEmpty : _pins.containsKey(entry.key)) {
        continue;
      }
      try {
        final file = root.fileSystem.file(candidate.path);
        if (await file.exists()) await deleteCachedFile(file);
        if (entry?.id != null) await delegate.delete(entry!.id!);
        total -= candidate.bytes;
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    _deferred = total > limitBytes;
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  @visibleForTesting
  Future<void> deleteCachedFile(File file) async => file.delete();

  Future<void> touch(String key) => _serial(() async {
        final item = await delegate.get(key);
        if (item != null) await delegate.update(item);
      });

  @override
  Future<bool> open() => _opening ??= delegate.open();
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<CacheObject?> get(String key) => _serial(() => delegate.get(key));
  @override
  Future<List<CacheObject>> getAllObjects() => _serial(delegate.getAllObjects);
  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) async {
    final result = await _serial(() async {
      final existing = await delegate.get(cacheObject.key);
      await (existing == null
          ? delegate.insert(CacheObject(cacheObject.url,
              key: cacheObject.key,
              relativePath: cacheObject.relativePath,
              validTill: cacheObject.validTill,
              eTag: cacheObject.eTag,
              length: cacheObject.length))
          : delegate.update(cacheObject.copyWith(id: existing.id)));
      return delegate.get(cacheObject.key);
    });
    _dirty = true;
    unawaited(maintainQuietly());
    return result;
  }

  @override
  Future<CacheObject> insert(CacheObject cacheObject,
          {bool setTouchedToNow = true}) =>
      _serial(
          () => delegate.insert(cacheObject, setTouchedToNow: setTouchedToNow));
  @override
  Future<int> update(CacheObject cacheObject, {bool setTouchedToNow = true}) =>
      _serial(
          () => delegate.update(cacheObject, setTouchedToNow: setTouchedToNow));
  @override
  Future<int> delete(int id) => _serial(() => delegate.delete(id));
  @override
  Future<int> deleteAll(Iterable<int> ids) =>
      _serial(() => delegate.deleteAll(ids));
  // Replace the library's unawaited count/age deletion with the protected quota.
  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async => [];
  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async => [];
  @override
  Future<void> deleteDataFile() => _serial(delegate.deleteDataFile);
  @override
  Future<bool> close() async {
    await _maintenance;
    await _tail;
    _disposed = true;
    changes.dispose();
    return delegate.close();
  }
}
