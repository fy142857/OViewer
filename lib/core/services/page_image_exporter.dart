import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/reader_page_resource.dart';

class PageImageExporter {
  static const channel = MethodChannel('oviewer/page_image_export');

  /// Returns true when an unsupported source was converted to a static PNG.
  Future<bool> save(ReaderPageResource resource,
      {required int gid, required int page}) async {
    final bytes = await resource.snapshot();
    final root = await getTemporaryDirectory();
    final folder = await root.createTemp('oviewer-page-export-');
    try {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final name =
          'OViewer_${gid}_p${(page + 1).toString().padLeft(4, '0')}_$stamp';
      final format = imageFormat(bytes);
      if (format != null) {
        final status = await _write(folder, bytes, name, format.$1, format.$2);
        if (status == 'saved') return false;
        if (status != 'unsupported_format') {
          throw PlatformException(code: status);
        }
      }
      final codec = await ui.instantiateImageCodec(bytes);
      Uint8List png;
      try {
        final frame = await codec.getNextFrame();
        try {
          final data =
              await frame.image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) throw StateError('PNG conversion failed');
          png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      final status = await _write(folder, png, name, 'png', 'image/png');
      if (status != 'saved') throw PlatformException(code: status);
      return true;
    } finally {
      // Only delete this operation's generated export directory.
      if (folder.parent.absolute.path == root.absolute.path &&
          await folder.exists()) {
        await folder.delete(recursive: true);
      }
    }
  }

  Future<String> _write(Directory folder, Uint8List bytes, String name,
      String extension, String mime) async {
    final file = File('${folder.path}/$name.$extension');
    await file.writeAsBytes(bytes, flush: true);
    return await channel.invokeMethod<String>('saveImage', {
          'path': file.path,
          'name': '$name.$extension',
          'mime': mime,
        }) ??
        'save_failed';
  }

  static (String, String)? imageFormat(Uint8List b) {
    bool starts(List<int> magic) =>
        b.length >= magic.length &&
        List.generate(magic.length, (i) => b[i] == magic[i]).every((v) => v);
    if (starts([0xff, 0xd8, 0xff])) return ('jpg', 'image/jpeg');
    if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return ('png', 'image/png');
    if (starts([71, 73, 70, 56, 55, 97]) || starts([71, 73, 70, 56, 57, 97])) {
      return ('gif', 'image/gif');
    }
    if (b.length >= 12 &&
        starts([82, 73, 70, 70]) &&
        b[8] == 87 &&
        b[9] == 69 &&
        b[10] == 66 &&
        b[11] == 80) return ('webp', 'image/webp');
    return null;
  }
}
