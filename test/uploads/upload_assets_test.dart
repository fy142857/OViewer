import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/features/uploads/files/upload_asset.dart';
import 'package:oviewer/features/uploads/files/upload_asset_preparer.dart';
import 'package:oviewer/features/uploads/files/upload_file_io.dart';
import 'package:oviewer/features/uploads/files/upload_zip.dart';

// The fixture images and ZIPs were generated independently using Pillow and
// Python's zipfile, not using the production encoder/decoder under test.
const _fixtures = 'test/uploads/fixtures/assets';

Matcher fileError(String code) =>
    isA<UploadFileException>().having((e) => e.code, 'code', code);

void main() {
  late Directory root;
  const preparer = UploadAssetPreparer();
  const extractor = UploadZipExtractor();
  const writer = UploadBatchWriter();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oviewer-upload-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> copy(String name, [String? target]) async {
    await File('$_fixtures/$name').copy('${root.path}/${target ?? name}');
  }

  Future<PreparedUploadAsset> inspect(String name, {String? displayName}) =>
      preparer.inspect(
          root: root, relativePath: name, displayName: displayName ?? name);

  for (final entry in {
    'png': UploadImageFormat.png,
    'jpg': UploadImageFormat.jpeg,
    'gif': UploadImageFormat.gif,
    'webp': UploadImageFormat.webp,
  }.entries) {
    test('sniffs ${entry.key} content independently of source extension',
        () async {
      await copy('sample.${entry.key}', 'source.binary');
      final asset = await inspect('source.binary');
      expect(asset.isValid, isTrue);
      expect(asset.format, entry.value);
      expect([asset.width, asset.height], [120, 140]);
      final original =
          await File('$_fixtures/sample.${entry.key}').readAsBytes();
      expect(asset.size, original.length);
      expect(asset.sha256, sha256.convert(original).toString());
      expect(await File('${root.path}/source.binary').readAsBytes(), original);
    });
  }

  test('rejects missing, out-of-root and truncated files', () async {
    await expectLater(inspect('missing'), throwsA(fileError('file_missing')));
    for (final path in [
      '../sample.png',
      '/sample.png',
      r'C:\sample.png',
      r'..\sample.png',
      'imports//sample.png'
    ]) {
      await expectLater(inspect(path), throwsA(fileError('unsafe_path')));
    }
    final bytes = await File('$_fixtures/sample.png').readAsBytes();
    await File('${root.path}/cut.png').writeAsBytes(bytes.take(33).toList());
    final asset = await inspect('cut.png');
    expect(asset.isValid, isFalse);
    expect(asset.issues.single.code, 'corrupt_image');
  });

  test('ambiguous extra minimum stays a warning and does not reject 100x100',
      () async {
    final png = await File('$_fixtures/sample.png').readAsBytes();
    final fields = ByteData.sublistView(png);
    fields.setUint32(16, 100);
    fields.setUint32(20, 100);
    fields.setUint32(29, (UploadCrc32()..add(png.sublist(12, 29))).value);
    await File('${root.path}/small.png').writeAsBytes(png);
    final asset = await inspect('small.png');
    expect(asset.isValid, isTrue);
    expect(asset.issues.single.code, 'minimum_dimensions_server_check');
    expect(asset.issues.single.severity, UploadIssueSeverity.warning);
    fields.setUint32(16, 99);
    fields.setUint32(29, (UploadCrc32()..add(png.sublist(12, 29))).value);
    await File('${root.path}/small.png').writeAsBytes(png);
    expect((await inspect('small.png')).isValid, isFalse);
  });

  test('safe frozen names retain mapping and are not renamed on later reorder',
      () async {
    await copy('sample.png');
    final asset = await inspect('sample.png', displayName: '第1册/02 页面.png');
    final frozen = preparer.freezeNames([asset, asset]);
    expect(frozen.map((a) => a.uploadName), ['0001_02.png', '0002_02.png']);
    expect(frozen.first.displayName, '第1册/02 页面.png');
    final reordered = preparer.freezeNames(frozen.reversed.toList());
    expect(reordered.map((a) => a.uploadName), ['0002_02.png', '0001_02.png']);
    expect(() => preparer.freezeNames([asset.withUploadName('../bad.png')]),
        throwsA(fileError('invalid_frozen_name')));
    expect(() => preparer.freezeNames([frozen.first, frozen.first]),
        throwsA(fileError('invalid_frozen_name')));
  });

  test(
      'natural and lexical sort remain deterministic, duplicates are only warned',
      () async {
    await copy('sample.png');
    final a = await inspect('sample.png', displayName: 'page10.png');
    final b = await inspect('sample.png', displayName: 'page2.png');
    final c = await inspect('sample.png', displayName: 'page02.png');
    expect(preparer.sorted([a, b, c]), [b, c, a]);
    expect(preparer.sorted([a, b, c], natural: false), [c, a, b]);
    expect(preparer.validateGallery([a, b, c]).map((i) => i.code),
        ['duplicate_image', 'duplicate_image']);
    expect(preparer.sorted([a, b, c]).length, 3);
    expect(
        compareNaturalUploadNames(
            'p999999999999999999999999.png', 'p1000000000000000000000000.png'),
        lessThan(0));
  });

  test(
      'gallery totals include existing remote files and leave originals intact',
      () async {
    await copy('sample.png');
    final a = await inspect('sample.png');
    expect(
        preparer.validateGallery([a], existingImages: 2000).map((i) => i.code),
        contains('gallery_too_many_images'));
    expect(
        preparer.validateGallery([a],
            existingBytes: 10000000000).map((i) => i.code),
        contains('gallery_too_large'));
    expect(
        preparer.validateGallery([a],
            existingImages: 1999, existingBytes: 10000000000 - a.size),
        isEmpty);
  });

  for (final fixture in ['stored.zip', 'deflated.zip', 'zip64.zip']) {
    test('extracts independently generated $fixture with verified content',
        () async {
      await copy(fixture);
      final imported = await extractor.extract(
          root: root, archiveRelativePath: fixture, destinationId: 'import1');
      expect(imported.assets.length, 1);
      expect(imported.assets.single.isValid, isTrue);
      expect(
          await File('${root.path}/${imported.assets.single.relativePath}')
              .readAsBytes(),
          await File('$_fixtures/sample.png').readAsBytes());
      if (fixture == 'deflated.zip') {
        expect(imported.assets.single.displayName, '第1册/002.png');
        expect(imported.excluded.single.displayName, 'readme.txt');
      } else {
        expect(imported.excluded, isEmpty);
      }
    });
  }

  for (final item in {
    'traversal.zip': 'unsafe_path',
    'absolute.zip': 'unsafe_path',
    'symlink.zip': 'archive_special_file',
    'encrypted.zip': 'encrypted_archive',
    'unsupported.zip': 'unsupported_zip_method',
    'nested.zip': 'nested_archive',
    'bad_crc.zip': 'archive_checksum',
    'dishonest_size.zip': 'archive_expanded_too_large',
  }.entries) {
    test('rejects ${item.key} and leaves no partial import', () async {
      await copy(item.key);
      await expectLater(
          extractor.extract(
              root: root, archiveRelativePath: item.key, destinationId: 'bad'),
          throwsA(fileError(item.value)));
      expect(await Directory('${root.path}/imports/bad').exists(), isFalse);
      expect(await File('${root.path}/${item.key}').exists(), isTrue);
    });
  }

  test(
      'extract cancellation and disk exhaustion never leave a complete-looking import',
      () async {
    await copy('stored.zip');
    await expectLater(
        extractor.extract(
            root: root,
            archiveRelativePath: 'stored.zip',
            destinationId: 'cancel',
            isCancelled: () => true),
        throwsA(isA<UploadCancelled>()));
    var calls = 0;
    await expectLater(
        extractor.extract(
            root: root,
            archiveRelativePath: 'stored.zip',
            destinationId: 'disk',
            availableBytes: () async => ++calls == 1 ? 99999999 : 0),
        throwsA(fileError('insufficient_space')));
    expect(await Directory('${root.path}/imports/disk').exists(), isFalse);
  });

  test('CRC implementation matches standard reference vector', () {
    expect((UploadCrc32()..add(utf8.encode('123456789'))).value, 0xcbf43926);
  });

  test(
      'batch size includes ZIP overhead, freezes names, and retains exact original bytes',
      () async {
    await copy('sample.png');
    final asset = await inspect('sample.png');
    final oneZipSize = asset.size + 22 + 76 + 2 * '0001_sample.png'.length;
    final batches = await writer.prepare(
        root: root,
        assets: [asset, asset],
        batchId: 'prepared',
        maxBatchBytes: oneZipSize);
    expect(batches.length, 2);
    expect(batches.every((b) => b.size == oneZipSize), isTrue);
    expect(batches.map((b) => b.assets.single.uploadName),
        ['0001_sample.png', '0002_sample.png']);
    for (var i = 0; i < batches.length; i++) {
      final decoded = await extractor.extract(
          root: root,
          archiveRelativePath: batches[i].relativePath,
          destinationId: 'roundtrip$i');
      expect(decoded.assets.single.sha256, asset.sha256);
    }
    expect(await File('${root.path}/sample.png').exists(), isTrue);
  });

  test('batch preparation detects changed input and cleans its own output only',
      () async {
    await copy('sample.png');
    final asset = await inspect('sample.png');
    final bytes = await File('${root.path}/sample.png').readAsBytes();
    bytes[40] ^= 1;
    await File('${root.path}/sample.png').writeAsBytes(bytes);
    await expectLater(
        writer.prepare(root: root, assets: [asset], batchId: 'changed'),
        throwsA(fileError('file_changed')));
    expect(await Directory('${root.path}/batches/changed').exists(), isFalse);
    expect(await File('${root.path}/sample.png').readAsBytes(), bytes);
  });

  test(
      'batch preparation cannot overwrite existing output and does not ignore cancellation',
      () async {
    await copy('sample.png');
    final asset = await inspect('sample.png');
    await writer.prepare(root: root, assets: [asset], batchId: 'kept');
    await expectLater(
        writer.prepare(root: root, assets: [asset], batchId: 'kept'),
        throwsA(fileError('destination_exists')));
    await expectLater(
        writer.prepare(
            root: root,
            assets: [asset],
            batchId: 'cancelled',
            isCancelled: () => true),
        throwsA(isA<UploadCancelled>()));
    expect(await File('${root.path}/batches/kept/0000.zip').exists(), isTrue);
    expect(
        writer.estimatePreparationBytes([asset]), greaterThan(3 * asset.size));
  });
}
