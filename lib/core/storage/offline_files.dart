import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/offline_book.dart';
import '../services/page_image_exporter.dart';

class OfflineFileInfo {
  final String relativePath;
  final String format;
  final int bytes;
  final String digest;
  const OfflineFileInfo(
      this.relativePath, this.format, this.bytes, this.digest);
}

/// Only complete, decoded and flushed files are exposed to the repository.
class OfflineFiles {
  final Future<Directory> Function() _root;
  final Future<void> Function(Uint8List) _decode;
  int _sequence = 0;
  Future<Directory>? _directory;
  OfflineFiles(
      {Future<Directory> Function()? root,
      Future<void> Function(Uint8List)? decode})
      : _root = root ??
            (() async => Directory(p.join(
                (await getApplicationDocumentsDirectory()).path, 'offline'))),
        _decode = decode ?? validateImage;

  static Future<void> validateImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<Directory> get root =>
      _directory ??= _openRoot().catchError((Object e, StackTrace st) {
        _directory = null;
        Error.throwWithStackTrace(e, st);
      });
  Future<Directory> _openRoot() async {
    final dir = await _root();
    await dir.create(recursive: true);
    if (Platform.isIOS) {
      await const MethodChannel('oviewer/offline_files')
          .invokeMethod<void>('excludeFromBackup');
    }
    return dir;
  }

  Future<File> file(String relativePath) async {
    final directory = await root;
    final path = p.normalize(p.absolute(p.join(directory.path, relativePath)));
    if (p.isAbsolute(relativePath) ||
        !p.isWithin(p.absolute(directory.path), path)) {
      throw const OfflineFailure('invalid_path');
    }
    // Our tree never contains symlinks. Refuse an existing link or link parent.
    var cursor = path;
    while (p.isWithin(p.absolute(directory.path), cursor)) {
      if (await FileSystemEntity.type(cursor, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const OfflineFailure('invalid_path');
      }
      cursor = p.dirname(cursor);
    }
    return File(path);
  }

  Future<OfflineFileInfo> write(
      String bookId, int page, Stream<List<int>> source,
      {required bool Function() current, int? expectedBytes}) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(bookId) || page < 0) {
      throw const OfflineFailure('invalid_path');
    }
    final stem =
        '$bookId/$page-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final partial = await file('$stem.part');
    await partial.parent.create(recursive: true);
    File? completed;
    void check() {
      if (!current()) throw const OfflineFailure('cancelled');
    }

    try {
      check();
      var length = 0;
      final sink = await partial.open(mode: FileMode.write);
      try {
        await for (final chunk in source.timeout(const Duration(seconds: 30))) {
          check();
          await sink.writeFrom(chunk);
          length += chunk.length;
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      check();
      if (length == 0 || (expectedBytes != null && length != expectedBytes)) {
        throw const OfflineFailure('incomplete_file');
      }
      final bytes = await partial.readAsBytes();
      final format = PageImageExporter.imageFormat(bytes)?.$1;
      if (format == null) throw const OfflineFailure('invalid_image');
      try {
        await _decode(bytes);
      } catch (_) {
        throw const OfflineFailure('invalid_image');
      }
      check();
      final relative = '$stem.$format';
      completed = await partial.rename((await file(relative)).path);
      check();
      return OfflineFileInfo(
          relative, format, length, sha256.convert(bytes).toString());
    } catch (_) {
      if (completed != null && await completed.exists())
        await completed.delete();
      rethrow;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<bool> verify(String relative, int size, String digest) async {
    try {
      final target = await file(relative);
      return await target.exists() &&
          await target.length() == size &&
          (await sha256.bind(target.openRead()).first).toString() == digest;
    } on FileSystemException {
      return false;
    }
  }

  Future<Uint8List> read(String relative, int size, String digest) async {
    final target = await file(relative);
    try {
      final bytes = await target.readAsBytes();
      if (bytes.length != size || sha256.convert(bytes).toString() != digest) {
        throw const OfflineFailure('damaged_file');
      }
      return bytes;
    } on FileSystemException {
      throw const OfflineFailure('missing_file');
    }
  }

  Future<void> remove(String relative) async {
    final target = await file(relative);
    if (await target.exists()) await target.delete();
  }

  Future<void> removeBook(String id) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
      throw const OfflineFailure('invalid_path');
    final probe = await file('$id/probe');
    if (await probe.parent.exists()) await probe.parent.delete(recursive: true);
  }

  Future<void> cleanPartials() async {
    await for (final entity
        in (await root).list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.part'))
        await entity.delete();
    }
  }

  Future<int> size() async {
    var count = 0;
    await for (final entity
        in (await root).list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          count += await entity.length();
        } on FileSystemException {
          if (await entity.exists()) rethrow;
        }
      }
    }
    return count;
  }
}
