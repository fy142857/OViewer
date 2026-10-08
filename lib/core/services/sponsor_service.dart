import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum SponsorPlatform { wechat, alipay }

extension SponsorAsset on SponsorPlatform {
  String get extension => this == SponsorPlatform.wechat ? 'png' : 'jpg';
  String get asset => 'assets/sponsors/$name.$extension';
  String get mime =>
      this == SponsorPlatform.wechat ? 'image/png' : 'image/jpeg';
}

class SponsorService {
  static const channel = MethodChannel('oviewer/sponsor');
  final AssetBundle bundle;
  final Future<Directory> Function() temporaryDirectory;

  SponsorService(
      {AssetBundle? bundle, Future<Directory> Function()? temporaryDirectory})
      : bundle = bundle ?? rootBundle,
        temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  Future<bool> prepareNotifications() async {
    try {
      return await channel.invokeMethod<bool>('prepareNotifications') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveCode(SponsorPlatform platform,
      {String? notificationBody}) async {
    final data = await bundle.load(platform.asset);
    final root = await temporaryDirectory();
    final folder = await root.createTemp('oviewer-sponsor-');
    try {
      final name =
          'OViewer_sponsor_${platform.name}_${DateTime.now().microsecondsSinceEpoch}.${platform.extension}';
      final file = File('${folder.path}/$name');
      await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true);
      final status = await channel.invokeMethod<String>('saveImage', {
        'path': file.path,
        if (notificationBody != null) 'notificationBody': notificationBody,
        'name': name,
        'mime': platform.mime,
      });
      if (status != 'saved')
        throw PlatformException(code: status ?? 'save_failed');
    } finally {
      if (folder.parent.absolute.path == root.absolute.path &&
          await folder.exists()) {
        await folder.delete(recursive: true);
      }
    }
  }

  Future<bool> openApp(SponsorPlatform platform) async =>
      await channel.invokeMethod<bool>('openApp', platform.name) ?? false;
}
