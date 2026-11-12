import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/features/uploads/files/upload_asset.dart';
import 'package:oviewer/features/uploads/files/upload_multipart.dart';

void main() {
  late Directory root;
  late Uint8List source;
  late UploadBatch batch;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('upload-body-');
    source = Uint8List.fromList(List.generate(180000, (i) => i % 251));
    await File('${root.path}/source.zip').writeAsBytes(source);
    batch = UploadBatch(
        relativePath: 'source.zip',
        size: source.length,
        sha256: sha256.convert(source).toString(),
        assets: const []);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('preserves field values and exact archive bytes with a bounded boundary',
      () async {
    final id = List.filled(100, 'a').join();
    final body = await prepareUploadBody(
        root: root,
        batch: batch,
        fields: {
          'gname_en': ['你好'],
          'checkbox[]': ['a', 'b']
        },
        id: id);
    final boundary = body.contentType.split('boundary=').last;
    expect(boundary.length, lessThanOrEqualTo(70));
    final bytes = await File('${root.path}/${body.path}').readAsBytes();
    final text = latin1.decode(bytes);
    const marker = 'Content-Type: application/zip\r\n\r\n';
    final start = text.indexOf(marker) + marker.length;
    expect(bytes.sublist(start, start + source.length), source);
    expect(bytes.length, body.length);
    expect(sha256.convert(bytes).toString(), body.sha256);
    expect(text.endsWith('\r\n--$boundary--\r\n'), isTrue);
    expect(text, contains('name="files[]"; filename="$id.zip"'));
    expect(await File('${root.path}/source.zip').readAsBytes(), source);
  });

  test('groups prepared bodies under an exclusively named safe directory',
      () async {
    final body = await prepareUploadBody(
        root: root,
        batch: batch,
        fields: const {},
        id: 'item',
        groupId: 'task-group');
    expect(body.path, 'prepared/task-group/item.multipart');
    expect(await File('${root.path}/${body.path}').exists(), isTrue);
    await expectLater(
        prepareUploadBody(
            root: root,
            batch: batch,
            fields: const {},
            id: 'item',
            groupId: '../escape'),
        throwsArgumentError);
  });

  test(
      'hashes copied bytes even if changed source is restored before finalization',
      () async {
    var probes = 0;
    await expectLater(
        prepareUploadBody(
            root: root,
            batch: batch,
            fields: const {},
            id: 'changed',
            availableBytes: () async {
              probes++;
              if (probes == 1) {
                final changed = Uint8List.fromList(source)..[0] = 255;
                await File('${root.path}/source.zip').writeAsBytes(changed);
              } else if (probes == 2) {
                await File('${root.path}/source.zip').writeAsBytes(source);
              }
              return 1000000000;
            }),
        throwsA(isA<UploadFileException>()
            .having((e) => e.code, 'code', 'file_changed')));
    expect(await File('${root.path}/prepared/changed.multipart').exists(),
        isFalse);
    expect(await File('${root.path}/prepared/changed.multipart.part').exists(),
        isFalse);
    expect(await File('${root.path}/source.zip').readAsBytes(), source);
  });

  test(
      'cancel and storage failure clear incomplete body without deleting input',
      () async {
    var probes = 0;
    await expectLater(
        prepareUploadBody(
            root: root,
            batch: batch,
            fields: const {},
            id: 'space',
            availableBytes: () async => ++probes > 1 ? 0 : 1000000000),
        throwsA(isA<UploadFileException>()
            .having((e) => e.code, 'code', 'insufficient_space')));
    expect(await File('${root.path}/prepared/space.multipart.part').exists(),
        isFalse);
    await expectLater(
        prepareUploadBody(
            root: root,
            batch: batch,
            fields: const {},
            id: 'cancel',
            isCancelled: () => true),
        throwsA(isA<UploadCancelled>()));
    expect(await File('${root.path}/source.zip').exists(), isTrue);
  });

  test('rejects conflicting outputs and excessive fields before writing',
      () async {
    await Directory('${root.path}/prepared').create();
    await File('${root.path}/prepared/existing.multipart')
        .writeAsString('keep');
    await expectLater(
        prepareUploadBody(
            root: root, batch: batch, fields: const {}, id: 'existing'),
        throwsA(isA<UploadFileException>()
            .having((e) => e.code, 'code', 'duplicate_body')));
    expect(
        await File('${root.path}/prepared/existing.multipart').readAsString(),
        'keep');
    await expectLater(
        prepareUploadBody(
            root: root,
            batch: batch,
            fields: {
              'x': [List.filled(2 * 1024 * 1024 + 1, 'a').join()]
            },
            id: 'large'),
        throwsA(isA<UploadFileException>()
            .having((e) => e.code, 'code', 'invalid_form')));
    expect(await File('${root.path}/prepared/large.multipart.part').exists(),
        isFalse);
  });
}
