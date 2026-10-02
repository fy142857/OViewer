import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Kept outside the image cache quota. A failed write leaves the previous file.
class TagTranslationCache {
  final Future<Directory> Function() directory;
  TagTranslationCache({Future<Directory> Function()? directory})
      : directory = directory ?? getApplicationSupportDirectory;

  Future<File> _file() async =>
      File('${(await directory()).path}/tag-translations.json');
  Future<String?> read() async {
    final file = await _file();
    return await file.exists() ? file.readAsString() : null;
  }

  Future<void> write(String json) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(json, flush: true);
    // Verify the completed write before the atomic replacement/legacy removal.
    if (await temporary.readAsString() != json)
      throw const FileSystemException('Incomplete tag cache write');
    await temporary.rename(file.path);
  }
}
