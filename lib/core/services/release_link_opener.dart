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
    return _invoke('open', uri.toString());
  }

  Future<bool> openRepository() => _invoke('openRepository');

  Future<bool> _invoke(String method, [String? url]) async {
    try {
      return await channel.invokeMethod<bool>(method, url) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
