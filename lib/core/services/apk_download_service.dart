import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/apk_update.dart';
import '../network/network_proxy_io.dart';
import '../network/update_http_client.dart';

class ApkUpdateException implements Exception {
  const ApkUpdateException(this.code);
  final String code;
}

class SavedApk {
  const SavedApk(this.update, this.file);
  final ApkUpdate update;
  final File file;
}

/// Files and cleanup are serialized so a cancelled task cannot erase its retry.
class ApkDownloadService {
  ApkDownloadService(
      {Future<Directory> Function()? directory,
      http.Client Function()? clientFactory,
      this.stallTimeout = const Duration(seconds: 30)})
      : _directory = directory ??
            (() async => Directory(
                p.join((await getTemporaryDirectory()).path, 'updates'))),
        _clientFactory = clientFactory ?? (() => UpdateHttpClient());
  final Future<Directory> Function() _directory;
  final http.Client Function() _clientFactory;
  final Duration stallTimeout;
  http.Client? _client;
  int _generation = 0;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  void cancel() {
    _generation++;
    _client?.close();
    _client = null;
  }

  void _active(int generation) {
    if (generation != _generation) throw const ApkUpdateException('cancelled');
  }

  Future<Directory> _folder() async {
    final folder = await _directory();
    await folder.create(recursive: true);
    return folder;
  }

  // Only owned, fixed filenames; never recursively delete user directories.
  Future<void> _remove(Directory folder, Iterable<String> names) async {
    for (final name in names) {
      final file = File(p.join(folder.path, name));
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> discard() => _serial(() async {
        await _remove(await _folder(),
            ['package.part', 'metadata.part', 'package.apk', 'metadata.json']);
      });

  /// Lightweight first-frame maintenance, never starts a download or installer.
  Future<void> maintain(int installedBuild) => _serial(() async {
        final folder = await _directory();
        if (!await folder.exists()) return;
        await _remove(folder, ['package.part', 'metadata.part']);
        final metadata = File(p.join(folder.path, 'metadata.json'));
        try {
          if (!await metadata.exists() ||
              await metadata.length() > 1024 * 1024) {
            await _remove(folder, ['package.apk', 'metadata.json']);
            return;
          }
          final update = ApkUpdate.fromJson(
              jsonDecode(await metadata.readAsString())
                  as Map<String, dynamic>);
          if (update.buildNumber <= installedBuild) {
            await _remove(folder, ['package.apk', 'metadata.json']);
          }
        } on FormatException {
          await _remove(folder, ['package.apk', 'metadata.json']);
        } on TypeError {
          await _remove(folder, ['package.apk', 'metadata.json']);
        }
      });

  Future<SavedApk?> restore() => _serial(() async {
        final folder = await _folder();
        await _remove(folder, ['package.part', 'metadata.part']);
        try {
          final metadata = File(p.join(folder.path, 'metadata.json'));
          if (!await metadata.exists()) {
            await _remove(folder, ['package.apk']);
            return null;
          }
          if (await metadata.length() > 1024 * 1024)
            throw const FormatException();
          final update = ApkUpdate.fromJson(
              jsonDecode(await metadata.readAsString())
                  as Map<String, dynamic>);
          final file = File(p.join(folder.path, 'package.apk'));
          await verify(file, update);
          return SavedApk(update, file);
        } on FileSystemException {
          await _remove(folder, ['package.apk', 'metadata.json']);
          return null;
        } on FormatException {
          await _remove(folder, ['package.apk', 'metadata.json']);
          return null;
        } on ApkUpdateException {
          await _remove(folder, ['package.apk', 'metadata.json']);
          return null;
        } on TypeError {
          await _remove(folder, ['package.apk', 'metadata.json']);
          return null;
        }
      });

  Future<void> verify(File file, ApkUpdate update) async {
    if (!await file.exists() ||
        await file.length() != update.size ||
        (await sha256.bind(file.openRead()).first).toString() !=
            update.sha256) {
      throw const ApkUpdateException('integrity');
    }
  }

  Future<File> download(ApkUpdate update,
      {required void Function(int) progress,
      required void Function() verifying}) {
    final generation = ++_generation;
    return _serial(() async {
      http.Client? client;
      Directory? folder;
      RandomAccessFile? output;
      try {
        _active(generation);
        folder = await _folder();
        _active(generation);
        await _remove(folder,
            ['package.part', 'metadata.part', 'package.apk', 'metadata.json']);
        await NetworkProxy.waitUntilReady().timeout(stallTimeout);
        _active(generation);
        client = _clientFactory();
        _client = client;
        final response = await client
            .send(http.Request('GET', update.downloadUrl))
            .timeout(stallTimeout);
        _active(generation);
        if (response.statusCode != 200)
          throw const ApkUpdateException('network');
        if (response.contentLength != null &&
            response.contentLength != update.size) {
          throw const ApkUpdateException('integrity');
        }
        final part = File(p.join(folder.path, 'package.part'));
        output = await part.open(mode: FileMode.write);
        var received = 0;
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          _active(generation);
          received += chunk.length;
          if (received > update.size)
            throw const ApkUpdateException('integrity');
          await output.writeFrom(chunk);
          _active(generation);
          progress(received);
        }
        await output.flush();
        await output.close();
        output = null;
        _active(generation);
        verifying();
        await verify(part, update);
        _active(generation);
        final file = await part.rename(p.join(folder.path, 'package.apk'));
        final metadata = File(p.join(folder.path, 'metadata.part'));
        await metadata.writeAsString(jsonEncode(update.toJson()), flush: true);
        _active(generation);
        await metadata.rename(p.join(folder.path, 'metadata.json'));
        _active(generation);
        return file;
      } catch (error) {
        await output?.close();
        output = null;
        if (folder != null) {
          await _remove(folder, [
            'package.part',
            'metadata.part',
            'package.apk',
            'metadata.json'
          ]);
        }
        _active(generation);
        if (error is ApkUpdateException) rethrow;
        if (error is TimeoutException)
          throw const ApkUpdateException('timeout');
        if (error is FileSystemException) {
          throw ApkUpdateException(
              const [28, 112].contains(error.osError?.errorCode)
                  ? 'space'
                  : 'storage');
        }
        throw const ApkUpdateException('network');
      } finally {
        client?.close();
        if (identical(_client, client)) _client = null;
      }
    });
  }
}
