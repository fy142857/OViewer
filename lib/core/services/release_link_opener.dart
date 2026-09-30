import 'package:flutter/services.dart';

class ReleaseLinkOpener {
  static const channel = MethodChannel('oviewer/release_link');

  static bool isReleaseUrl(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      RegExp(r'^/fy142857/OViewer/releases/tag/[^/]+$').hasMatch(uri.path);

  Future<bool> open(Uri uri) async {
    if (!isReleaseUrl(uri)) return false;
    try {
      return await channel.invokeMethod<bool>('open', uri.toString()) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
