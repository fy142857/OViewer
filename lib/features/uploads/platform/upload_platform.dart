import 'package:flutter/services.dart';

class UploadPlatform {
  static const files = MethodChannel('oviewer/upload_files');
  static const transfers = MethodChannel('oviewer/upload_transport');
  static const links = MethodChannel('oviewer/upload_links');
  static const conversion = MethodChannel('oviewer/upload_conversion');

  Future<Map<String, dynamic>> convert(String relativePath) async =>
      Map<String, dynamic>.from(await conversion
              .invokeMapMethod<String, dynamic>(
                  'convert', {'relativePath': relativePath}) ??
          (throw StateError('No conversion result')));

  Future<Map<String, dynamic>> pick(
          {required bool photos, required String language}) async =>
      Map<String, dynamic>.from(await files.invokeMapMethod<String, dynamic>(
              photos ? 'pickPhotos' : 'pickFiles', {'language': language}) ??
          (throw StateError('No file selection result')));
  Future<int> availableBytes() async =>
      await files.invokeMethod<int>('availableBytes') ??
      (throw StateError('Upload storage unavailable'));
  Future<void> excludeFromBackup() =>
      files.invokeMethod<void>('excludeFromBackup');
  Future<void> cancelImport() => files.invokeMethod<void>('cancelImport');
  Future<void> prepareSession(String accountId, String epoch) =>
      transfers.invokeMethod<void>(
          'prepareSession', {'accountId': accountId, 'epoch': epoch});
  Future<void> invalidateSession(String epoch) =>
      transfers.invokeMethod<void>('invalidateSession', {'epoch': epoch});
  Future<Map<String, dynamic>> snapshot() async => Map<String, dynamic>.from(
      await transfers.invokeMapMethod<String, dynamic>('snapshot') ??
          (throw StateError('No transfer state')));
  Future<void> enqueue(Map<String, Object?> plan) =>
      transfers.invokeMethod<void>('enqueue', plan);
  Future<void> pause(String taskId) =>
      transfers.invokeMethod<void>('pause', {'taskId': taskId});
  Future<void> resume(String taskId) =>
      transfers.invokeMethod<void>('resume', {'taskId': taskId});
  Future<void> cancel(String taskId) =>
      transfers.invokeMethod<void>('cancel', {'taskId': taskId});
  Future<void> acknowledge(String receiptId, String outcome) =>
      transfers.invokeMethod<void>(
          'acknowledge', {'receiptId': receiptId, 'outcome': outcome});
  Future<void> openExternal(Uri uri) async {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !{
          'upld.e-hentai.org',
          'e-hentai.org',
          'exhentai.org',
          'ehwiki.org',
          'forums.e-hentai.org',
          'developer.android.com',
          'developer.apple.com'
        }.contains(uri.host)) {
      throw ArgumentError('Unsupported upload help destination');
    }
    if (uri.host == 'upld.e-hentai.org' &&
        uri.path == '/managegallery' &&
        !{null, '', 'new'}.contains(uri.queryParameters['act'])) {
      throw ArgumentError('Open the manager to review this action first');
    }
    if (await links.invokeMethod<bool>('open', uri.toString()) != true) {
      throw StateError('Could not open upload page');
    }
  }
}
