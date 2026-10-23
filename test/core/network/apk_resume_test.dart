import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oviewer/core/services/apk_download_service.dart';
import 'apk_download_service_test.dart' show packageFor, StreamClient;

void main() {
  late Directory folder;
  final bytes = [1, 2, 3, 4, 5, 6];
  setUp(() async =>
      folder = await Directory.systemTemp.createTemp('apk-resume-'));
  tearDown(() async => folder.delete(recursive: true));
  ApkDownloadService service(http.Client client) => ApkDownloadService(
      directory: () async => folder, clientFactory: () => client);
  Future<void> interrupted() async {
    Stream<List<int>> body() async* {
      yield bytes.take(3).toList();
      throw http.ClientException('disconnected');
    }

    final first = service(StreamClient(() async => http.StreamedResponse(
        body(), 200,
        contentLength: 6, headers: {'etag': '"asset-v1"'})));
    await expectLater(
        first.download(packageFor(bytes), progress: (_) {}, verifying: () {}),
        throwsA(isA<ApkUpdateException>()
            .having((e) => e.code, 'code', 'network')));
    expect((await first.restorePartial())!.received, 3);
  }

  test(
      'fresh process retains part at startup, resumes exact range and verifies full hash',
      () async {
    await interrupted();
    var requests = 0;
    final next = service(MockClient((r) async {
      requests++;
      expect(r.headers['Range'], 'bytes=3-');
      expect(r.headers['If-Range'], '"asset-v1"');
      expect(r.headers['Accept-Encoding'], 'identity');
      return http.Response.bytes(bytes.skip(3).toList(), 206,
          headers: {'content-range': 'bytes 3-5/6', 'etag': '"asset-v1"'});
    }));
    await next.maintain(69);
    expect(await next.restore(), isNull);
    expect((await next.restorePartial())!.received, 3);
    final progress = <int>[];
    final apk = await next.download(packageFor(bytes),
        progress: progress.add, verifying: () {});
    expect(await apk.readAsBytes(), bytes);
    expect(progress.first, 3);
    expect(progress.last, 6);
    expect(requests, 1);
    expect(await next.restorePartial(), isNull);
    expect(await next.restore(), isNotNull);
    await next.maintain(70);
    expect(await folder.list().isEmpty, isTrue);
  });

  test('200 after Range truncates the old bytes instead of appending',
      () async {
    await interrupted();
    final next =
        service(MockClient((r) async => http.Response.bytes(bytes, 200)));
    expect(
        await (await next.download(packageFor(bytes),
                progress: (_) {}, verifying: () {}))
            .readAsBytes(),
        bytes);
  });

  test('416 falls back to one full request without Range', () async {
    await interrupted();
    var n = 0;
    final next = service(MockClient((r) async {
      if (++n == 1) {
        expect(r.headers['Range'], 'bytes=3-');
        return http.Response('', 416);
      }
      expect(r.headers.containsKey('Range'), isFalse);
      return http.Response.bytes(bytes, 200);
    }));
    await next.download(packageFor(bytes), progress: (_) {}, verifying: () {});
    expect(n, 2);
  });

  for (final range in [
    'bytes 0-2/6',
    'bytes 3-5/7',
    'bytes 3-8/6',
    'bytes 5-3/6',
    'bad'
  ]) {
    test('invalid Content-Range $range never produces an installable package',
        () async {
      await interrupted();
      final next = service(MockClient((_) async => http.Response.bytes(
          [4, 5, 6], 206,
          headers: {'content-range': range})));
      await expectLater(
          next.download(packageFor(bytes), progress: (_) {}, verifying: () {}),
          throwsA(isA<ApkUpdateException>()
              .having((e) => e.code, 'code', 'range')));
      expect(await next.restore(), isNull);
      expect(await next.restorePartial(), isNull);
    });
  }

  test('changed target never combines bytes from different releases', () async {
    await interrupted();
    final changed = [6, 5, 4, 3, 2, 1];
    final next = service(MockClient((r) async {
      expect(r.headers.containsKey('Range'), isFalse);
      return http.Response.bytes(changed, 200);
    }));
    expect(
        await (await next.download(packageFor(changed),
                progress: (_) {}, verifying: () {}))
            .readAsBytes(),
        changed);
  });

  test('explicit cancel deletes partial and its metadata', () async {
    await interrupted();
    final next = service(MockClient((_) async => http.Response('', 500)));
    next.cancel();
    await next.discard();
    expect(await folder.list().isEmpty, isTrue);
  });

  test(
      'complete partial after process death is finalized locally without another request',
      () async {
    await interrupted();
    await File('${folder.path}/package.part').writeAsBytes(bytes, flush: true);
    final next =
        service(MockClient((_) async => throw StateError('must not request')));
    expect(
        await (await next.download(packageFor(bytes),
                progress: (_) {}, verifying: () {}))
            .readAsBytes(),
        bytes);
  });

  test('system cache eviction restarts safely', () async {
    await interrupted();
    await File('${folder.path}/package.part').delete();
    final next = service(MockClient((r) async {
      expect(r.headers.containsKey('Range'), isFalse);
      return http.Response.bytes(bytes, 200);
    }));
    await next.download(packageFor(bytes), progress: (_) {}, verifying: () {});
  });
}
