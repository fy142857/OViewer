import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/services/apk_download_service.dart';
import 'package:oviewer/models/apk_update.dart';

ApkUpdate packageFor(List<int> bytes) => ApkUpdate(
    version: '1.8.0',
    buildNumber: 70,
    releaseUrl:
        Uri.parse('https://github.com/fy142857/OViewer/releases/tag/v1.8.0'),
    downloadUrl: Uri.parse(
        'https://github.com/fy142857/OViewer/releases/download/v1.8.0/OViewer.apk'),
    size: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    certificate: 'b' * 64,
    notes: '新增\n- 测试');

class StreamClient extends http.BaseClient {
  StreamClient(this.reply);
  final Future<http.StreamedResponse> Function() reply;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => reply();
  @override
  void close() {
    closed = true;
  }
}

class FailedDirectory extends Mock implements Directory {}

void main() {
  late Directory folder;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('apk-update-test-');
  });
  tearDown(() async {
    await folder.delete(recursive: true);
  });
  final bytes = utf8.encode('an apk binary\u0000\u00ff');

  for (final code in [28, 112, 13]) {
    test('filesystem failure $code reports actionable storage error', () async {
      final broken = FailedDirectory();
      when(() => broken.create(recursive: true)).thenThrow(
          FileSystemException('failed', 'updates', OSError('failed', code)));
      final service = ApkDownloadService(directory: () async => broken);
      await expectLater(
          service.download(packageFor(bytes),
              progress: (_) {}, verifying: () {}),
          throwsA(isA<ApkUpdateException>().having(
              (e) => e.code, 'code', code == 13 ? 'storage' : 'space')));
    });
  }

  test(
      'post-frame maintenance removes obsolete package and interrupted partials',
      () async {
    final service = ApkDownloadService(
        directory: () async => folder,
        clientFactory: () =>
            MockClient((_) async => http.Response.bytes(bytes, 200)));
    final file = await service.download(packageFor(bytes),
        progress: (_) {}, verifying: () {});
    await service.maintain(69);
    expect(await file.exists(), isTrue);
    await File('${folder.path}/package.part').writeAsBytes([0]);
    await service.maintain(70);
    expect(await folder.list().isEmpty, isTrue);
  });

  test('disconnect closes the client and removes incomplete files', () async {
    final client = StreamClient(() async => http.StreamedResponse(
        Stream<List<int>>.error(http.ClientException('connection lost')), 200));
    final service = ApkDownloadService(
        directory: () async => folder, clientFactory: () => client);
    await expectLater(
        service.download(packageFor(bytes), progress: (_) {}, verifying: () {}),
        throwsA(isA<ApkUpdateException>()
            .having((e) => e.code, 'code', 'network')));
    expect(client.closed, isTrue);
    expect(await folder.list().isEmpty, isTrue);
  });

  test('streams binary bytes, reports progress and restores verified package',
      () async {
    final update = packageFor(bytes);
    final service = ApkDownloadService(
        directory: () async => folder,
        clientFactory: () =>
            MockClient((_) async => http.Response.bytes(bytes, 200)));
    final progress = <int>[];
    var verified = false;
    final file =
        await service.download(update, progress: progress.add, verifying: () {
      verified = true;
    });
    expect(await file.readAsBytes(), bytes);
    expect(progress.last, bytes.length);
    expect(verified, isTrue);
    final restored = await service.restore();
    expect(restored!.update.sha256, update.sha256);
    expect(await File('${folder.path}/package.part').exists(), isFalse);
    await file.writeAsBytes([1]);
    expect(await service.restore(), isNull);
  });

  for (final payload in [
    <int>[1],
    <int>[1, 2, 3, 4]
  ]) {
    test('rejects incomplete, oversized or corrupt bytes $payload', () async {
      final service = ApkDownloadService(
          directory: () async => folder,
          clientFactory: () =>
              MockClient((_) async => http.Response.bytes(payload, 200)));
      await expectLater(
          service.download(packageFor([1, 2, 3]),
              progress: (_) {}, verifying: () {}),
          throwsA(isA<ApkUpdateException>()
              .having((e) => e.code, 'code', 'integrity')));
      expect(await folder.list().isEmpty, isTrue);
    });
  }

  test('same size but incorrect hash is rejected', () async {
    final service = ApkDownloadService(
        directory: () async => folder,
        clientFactory: () =>
            MockClient((_) async => http.Response.bytes([4, 5, 6], 200)));
    await expectLater(
        service.download(packageFor([1, 2, 3]),
            progress: (_) {}, verifying: () {}),
        throwsA(isA<ApkUpdateException>()));
    expect(await folder.list().isEmpty, isTrue);
  });

  test('cancelled late response cannot erase or complete a queued retry',
      () async {
    final pending = Completer<http.StreamedResponse>();
    final sent = Completer<void>();
    var count = 0;
    final service = ApkDownloadService(
        directory: () async => folder,
        clientFactory: () {
          if (++count == 1)
            return StreamClient(() {
              sent.complete();
              return pending.future;
            });
          return MockClient((_) async => http.Response.bytes(bytes, 200));
        });
    final first =
        service.download(packageFor(bytes), progress: (_) {}, verifying: () {});
    final failed = expectLater(
        first,
        throwsA(isA<ApkUpdateException>()
            .having((e) => e.code, 'code', 'cancelled')));
    await sent.future;
    service.cancel();
    final retry =
        service.download(packageFor(bytes), progress: (_) {}, verifying: () {});
    pending.complete(http.StreamedResponse(Stream.value(bytes), 200));
    await failed;
    expect(await (await retry).readAsBytes(), bytes);
    expect(await service.restore(), isNotNull);
  });

  test('startup recovery deletes partials but leaves unrelated files',
      () async {
    await File('${folder.path}/package.part').writeAsBytes(bytes);
    await File('${folder.path}/metadata.part').writeAsString('{}');
    final other = File('${folder.path}/unrelated');
    await other.writeAsString('keep');
    final service = ApkDownloadService(directory: () async => folder);
    expect(await service.restore(), isNull);
    expect(await folder.list().length, 1);
    expect(await other.exists(), isTrue);
  });

  test('stalled download fails and removes partials', () async {
    final stream = StreamController<List<int>>();
    final service = ApkDownloadService(
        directory: () async => folder,
        stallTimeout: const Duration(milliseconds: 20),
        clientFactory: () => StreamClient(
            () async => http.StreamedResponse(stream.stream, 200)));
    await expectLater(
        service.download(packageFor(bytes), progress: (_) {}, verifying: () {}),
        throwsA(isA<ApkUpdateException>()
            .having((e) => e.code, 'code', 'timeout')));
    await stream.close();
    expect(await folder.list().isEmpty, isTrue);
  });
}
