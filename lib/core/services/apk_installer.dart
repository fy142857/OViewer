import 'package:flutter/services.dart';
import '../../models/apk_update.dart';

class ApkInstaller {
  ApkInstaller({String Function()? language})
      : _language = language ?? (() => 'zh');
  final String Function() _language;
  static const channel = MethodChannel('oviewer/apk_update');

  Map<String, dynamic> _args(String path, ApkUpdate update) => {
        'path': path,
        'version': update.version,
        'buildNumber': update.buildNumber,
        'certificate': update.certificate,
      };
  Future<void> inspect(String path, ApkUpdate update) =>
      channel.invokeMethod<void>('inspect', _args(path, update));
  Future<bool> canInstall() async =>
      await channel.invokeMethod<bool>('canInstall') ?? false;
  Future<bool> openSettings() async =>
      await channel
          .invokeMethod<bool>('openSettings', {'language': _language()}) ??
      false;
  Future<void> install(String path, ApkUpdate update) =>
      channel.invokeMethod<void>('install', _args(path, update));
}
