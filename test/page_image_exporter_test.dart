import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/services/page_image_exporter.dart';
import 'package:oviewer/models/reader_page_resource.dart';

Uint8List animatedGif() => Uint8List.fromList([
      71,
      73,
      70,
      56,
      57,
      97,
      1,
      0,
      1,
      0,
      128,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
      33,
      255,
      11,
      78,
      69,
      84,
      83,
      67,
      65,
      80,
      69,
      50,
      46,
      48,
      3,
      1,
      0,
      0,
      0,
      33,
      249,
      4,
      0,
      10,
      0,
      0,
      0,
      44,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      68,
      1,
      0,
      33,
      249,
      4,
      0,
      10,
      0,
      0,
      0,
      44,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      76,
      1,
      0,
      59
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oviewer-export-test-');
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(PageImageExporter.channel, null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), null);
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    await root.delete(recursive: true);
  });

  test(
      'preserves animated file bytes, names the selected page and cleans snapshots',
      () async {
    final gif = animatedGif();
    final codec = await ui.instantiateImageCodec(gif);
    expect(codec.frameCount, 2);
    codec.dispose();
    String? path;
    messenger.setMockMethodCallHandler(PageImageExporter.channel, (call) async {
      expect(call.method, 'saveImage');
      path = call.arguments['path'] as String;
      expect(call.arguments['name'], startsWith('OViewer_42_p0003_'));
      expect(call.arguments['mime'], 'image/gif');
      expect(await File(path!).readAsBytes(), gif);
      return 'saved';
    });
    expect(
        await PageImageExporter()
            .save(ReaderPageResource(() async => gif), gid: 42, page: 2),
        false);
    expect(await File(path!).exists(), false);
  });

  for (final format in ['png', 'jpeg', 'webp']) {
    test('saves $format without re-encoding', () async {
      final fixtures = jsonDecode(
          await File('test/fixtures/page_image_formats.json').readAsString());
      final bytes = base64Decode(fixtures[format] as String);
      messenger.setMockMethodCallHandler(PageImageExporter.channel,
          (call) async {
        expect(call.arguments['mime'], 'image/$format');
        expect(
            await File(call.arguments['path'] as String).readAsBytes(), bytes);
        return 'saved';
      });
      expect(
          await PageImageExporter()
              .save(ReaderPageResource(() async => bytes), gid: 3, page: 0),
          false);
      expect(await root.list().toList(), isEmpty);
    });
  }

  test(
      'unsupported animation falls back to first-frame PNG without redownloading',
      () async {
    final gif = animatedGif();
    var reads = 0;
    var calls = 0;
    messenger.setMockMethodCallHandler(PageImageExporter.channel, (call) async {
      calls++;
      if (calls == 1) return 'unsupported_format';
      expect(call.arguments['mime'], 'image/png');
      final png = await File(call.arguments['path'] as String).readAsBytes();
      final codec = await ui.instantiateImageCodec(png);
      expect(codec.frameCount, 1);
      codec.dispose();
      return 'saved';
    });
    final converted =
        await PageImageExporter().save(ReaderPageResource(() async {
      reads++;
      return gif;
    }), gid: 1, page: 0);
    expect(converted, true);
    expect(reads, 1);
    expect(calls, 2);
    expect(await root.list().toList(), isEmpty);
  });

  for (final error in ['permission_denied', 'save_failed']) {
    test('$error does not convert or leave a snapshot', () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(PageImageExporter.channel, (_) async {
        calls++;
        return error;
      });
      await expectLater(
          PageImageExporter().save(
              ReaderPageResource(() async => animatedGif()),
              gid: 1,
              page: 0),
          throwsA(
              isA<PlatformException>().having((e) => e.code, 'code', error)));
      expect(calls, 1);
      expect(await root.list().toList(), isEmpty);
    });
  }

  test('snapshot remains valid if reader exits while cache lookup is pending',
      () async {
    final pending = Completer<Uint8List?>();
    final gif = animatedGif();
    final resource = ReaderPageResource(() => pending.future, fallback: gif);
    final snapshot = resource.snapshot();
    resource.releaseMemory();
    pending.complete(null);
    expect(await snapshot, gif);
  });

  test('resource keeps fallback bytes only until released', () async {
    final gif = animatedGif();
    final resource = ReaderPageResource(() async => null, fallback: gif);
    expect(await resource.snapshot(), gif);
    resource.releaseMemory();
    await expectLater(resource.snapshot(), throwsStateError);
  });
}
