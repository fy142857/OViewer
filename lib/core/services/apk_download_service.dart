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

class PartialApk extends SavedApk {
  const PartialApk(super.update, super.file, this.received, this.validator);
  final int received;
  final String? validator;
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
  final _stops = <int, String>{};
  final _live = <int>{};
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  void cancel() => _stop('cancelled');
  void interrupt() => _stop('interrupted');
  void _stop(String reason) {
    if (_live.contains(_generation)) _stops[_generation] = reason;
    _generation++;
    _client?.close();
    _client = null;
  }

  void _active(int generation) {
    if (generation != _generation) {
      throw ApkUpdateException(_stops[generation] ?? 'cancelled');
    }
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

  static const _partialFiles = ['package.part', 'resume.json', 'resume.tmp'];
  static const _completeFiles = [
    'package.apk',
    'metadata.json',
    'metadata.part'
  ];
  Future<void> discard() => _serial(() async {
        await _remove(await _folder(), [..._partialFiles, ..._completeFiles]);
      });

  Future<Map<String, dynamic>> _json(File file) async {
    if (!await file.exists() || await file.length() > 1024 * 1024) {
      throw const FormatException('Missing or oversized update metadata');
    }
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<PartialApk?> _partial(Directory folder) async {
    try {
      final record = await _json(File(p.join(folder.path, 'resume.json')));
      if (record['schema'] != 1) throw const FormatException();
      final update =
          ApkUpdate.fromJson(record['update'] as Map<String, dynamic>);
      final file = File(p.join(folder.path, 'package.part'));
      final length = await file.length();
      if (length > update.size) throw const FormatException();
      final validator = record['validator'] as String?;
      if (validator != null &&
          (validator.contains('\r') || validator.contains('\n'))) {
        throw const FormatException();
      }
      return PartialApk(update, file, length, validator);
    } on Exception {
      await _remove(folder, _partialFiles);
      return null;
    } on TypeError {
      await _remove(folder, _partialFiles);
      return null;
    }
  }

  Future<void> _savePartial(
      Directory folder, ApkUpdate update, String? validator) async {
    final temp = File(p.join(folder.path, 'resume.tmp'));
    await temp.writeAsString(
        jsonEncode(
            {'schema': 1, 'update': update.toJson(), 'validator': validator}),
        flush: true);
    await temp.rename(p.join(folder.path, 'resume.json'));
  }

  Future<PartialApk?> restorePartial() =>
      _serial(() async => _partial(await _folder()));

  /// First-frame maintenance retains valid partials but never resumes a transfer.
  Future<void> maintain(int installedBuild) => _serial(() async {
        final folder = await _directory();
        if (!await folder.exists()) return;
        await _remove(folder, ['metadata.part', 'resume.tmp']);
        final partial = await _partial(folder);
        if (partial != null && partial.update.buildNumber <= installedBuild) {
          await _remove(folder, _partialFiles);
        }
        try {
          final update = ApkUpdate.fromJson(
              await _json(File(p.join(folder.path, 'metadata.json'))));
          if (update.buildNumber <= installedBuild)
            await _remove(folder, _completeFiles);
        } on Exception {
          await _remove(folder, _completeFiles);
        } on TypeError {
          await _remove(folder, _completeFiles);
        }
      });

  Future<SavedApk?> restore() => _serial(() async {
        final folder = await _folder();
        try {
          final update = ApkUpdate.fromJson(
              await _json(File(p.join(folder.path, 'metadata.json'))));
          final file = File(p.join(folder.path, 'package.apk'));
          await verify(file, update);
          await _remove(folder, _partialFiles);
          return SavedApk(update, file);
        } on Exception {
          await _remove(folder, _completeFiles);
          await _partial(folder);
          return null;
        } on TypeError {
          await _remove(folder, _completeFiles);
          await _partial(folder);
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
    _live.add(generation);
    return _serial(() async {
      http.Client? client;
      Directory? folder;
      RandomAccessFile? output;
      try {
        _active(generation);
        folder = await _folder();
        _active(generation);
        var partial = await _partial(folder);
        if (partial != null &&
            (partial.update.sha256 != update.sha256 ||
                partial.update.buildNumber != update.buildNumber ||
                partial.update.downloadUrl != update.downloadUrl ||
                partial.update.size != update.size ||
                partial.update.certificate != update.certificate)) {
          await _remove(folder, _partialFiles);
          partial = null;
        }
        await _remove(folder, _completeFiles);
        final part = File(p.join(folder.path, 'package.part'));
        if (partial == null) await part.writeAsBytes([], flush: true);
        var received = partial?.received ?? 0;
        await _savePartial(folder, update, partial?.validator);
        progress(received);
        // An interrupted finalization may have all bytes already on disk.
        if (received == update.size) {
          try {
            await verify(part, update);
          } on ApkUpdateException {
            received = 0;
            await part.writeAsBytes([], flush: true);
          }
        }
        if (received < update.size) {
          await NetworkProxy.waitUntilReady().timeout(stallTimeout);
          _active(generation);
          client = _clientFactory();
          _client = client;
          // At most one full restart if a server rejects an existing range.
          for (var attempt = 0; attempt < 2; attempt++) {
            final request = http.Request('GET', update.downloadUrl)
              ..headers['Accept-Encoding'] = 'identity';
            if (received > 0) {
              request.headers['Range'] = 'bytes=$received-';
              if (partial?.validator != null)
                request.headers['If-Range'] = partial!.validator!;
            }
            final response = await client.send(request).timeout(stallTimeout);
            _active(generation);
            if (response.statusCode == 416 && received > 0 && attempt == 0) {
              await response.stream.listen((_) {}).cancel();
              received = 0;
              partial = null;
              await part.writeAsBytes([], flush: true);
              await _savePartial(folder, update, null);
              progress(0);
              continue;
            }
            var expectedEnd = update.size;
            if (response.statusCode == 206) {
              final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
                  .firstMatch(response.headers['content-range'] ?? '');
              if (range == null ||
                  int.parse(range[1]!) != received ||
                  int.parse(range[3]!) != update.size ||
                  int.parse(range[2]!) < received ||
                  int.parse(range[2]!) >= update.size) {
                throw const ApkUpdateException('range');
              }
              expectedEnd = int.parse(range[2]!) + 1;
            } else if (response.statusCode == 200) {
              received = 0; // The server ignored Range or If-Range changed.
              progress(0);
            } else {
              throw const ApkUpdateException('network');
            }
            if ((response.headers['content-encoding'] ?? 'identity') !=
                    'identity' ||
                (response.contentLength != null &&
                    response.contentLength != expectedEnd - received)) {
              throw const ApkUpdateException('range');
            }
            final etag = response.headers['etag'];
            final validator =
                etag != null && etag.startsWith('"') && etag.endsWith('"')
                    ? etag
                    : response.headers['last-modified'];
            // Ensure truncation is durable before recording a new validator.
            if (received == 0) await part.writeAsBytes([], flush: true);
            await _savePartial(folder, update, validator);
            output = await part.open(
                mode: received == 0 ? FileMode.write : FileMode.append);
            await for (final chunk in response.stream.timeout(stallTimeout)) {
              _active(generation);
              received += chunk.length;
              if (received > expectedEnd)
                throw const ApkUpdateException('integrity');
              await output.writeFrom(chunk);
              _active(generation);
              progress(received);
            }
            await output.flush();
            await output.close();
            output = null;
            if (received < update.size)
              throw const ApkUpdateException('network');
            break;
          }
        }
        _active(generation);
        verifying();
        await verify(part, update);
        _active(generation);
        // Leave resume.json until both the full metadata and APK exist. A crash
        // before the rename still leaves a resumable (possibly complete) part.
        final metadata = File(p.join(folder.path, 'metadata.part'));
        await metadata.writeAsString(jsonEncode(update.toJson()), flush: true);
        await metadata.rename(p.join(folder.path, 'metadata.json'));
        final file = await part.rename(p.join(folder.path, 'package.apk'));
        _active(generation);
        await _remove(folder, ['resume.json', 'resume.tmp']);
        return file;
      } catch (error) {
        try {
          await output?.close();
        } on FileSystemException {/* report below */}
        output = null;
        final reason = _stops[generation];
        final code = reason ??
            (error is ApkUpdateException
                ? error.code
                : error is TimeoutException
                    ? 'timeout'
                    : error is FileSystemException
                        ? (const [28, 112].contains(error.osError?.errorCode)
                            ? 'space'
                            : 'storage')
                        : 'network');
        if (folder != null &&
            !const ['network', 'timeout', 'interrupted', 'space']
                .contains(code)) {
          await _remove(folder, [..._partialFiles, ..._completeFiles]);
        }
        throw ApkUpdateException(code);
      } finally {
        client?.close();
        if (identical(_client, client)) _client = null;
        _stops.remove(generation);
        _live.remove(generation);
      }
    });
  }
}
