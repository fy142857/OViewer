import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;

const authenticationCookieNames = {
  'ipb_member_id',
  'ipb_pass_hash',
  'ipb_session_id',
  'igneous',
  'sk',
};

bool isAccountCookieHost(String host) => RegExp(
      r'^(?:[a-z0-9-]+\.)*(?:e-hentai|exhentai)\.org$',
    ).hasMatch(host.toLowerCase().replaceFirst(RegExp(r'^\.'), ''));

/// Delete authentication only. Keep uconfig, challenges, and unrelated sites.
class NativeAuthCookies {
  static Future<void> clear() async {
    final manager = web.CookieManager.instance();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final cookies = await web.IOSCookieManager.instance().getAllCookies();
      for (final cookie in cookies) {
        final domain = cookie.domain;
        if (domain == null ||
            !isAccountCookieHost(domain) ||
            !authenticationCookieNames.contains(cookie.name)) continue;
        await manager.deleteCookie(
            url: Uri.https(
                domain.replaceFirst(RegExp(r'^\.'), ''), cookie.path ?? '/'),
            domain: domain,
            path: cookie.path ?? '/',
            name: cookie.name);
      }
      final remaining = await web.IOSCookieManager.instance().getAllCookies();
      if (remaining.any((c) =>
          c.domain != null &&
          isAccountCookieHost(c.domain!) &&
          authenticationCookieNames.contains(c.name))) {
        throw StateError('Browser authentication cleanup incomplete');
      }
      return;
    }

    // Android's native getCookie API omits domain/path attributes. Expire both
    // host-only and shared-domain variants at the site's authentication scopes.
    const hosts = ['e-hentai.org', 'exhentai.org', 'forums.e-hentai.org'];
    const paths = ['/', '/index.php', '/mytags', '/uconfig.php'];
    for (final host in hosts) {
      final parent =
          host.endsWith('e-hentai.org') ? 'e-hentai.org' : 'exhentai.org';
      for (final path in paths) {
        final url = Uri.https(host, path);
        final names = (await manager.getCookies(url: url))
            .where((c) => authenticationCookieNames.contains(c.name))
            .map((c) => c.name)
            .toSet();
        for (final name in names) {
          for (final domain in <String?>{
            null,
            host,
            '.$host',
            parent,
            '.$parent'
          }) {
            for (final cookiePath in {'/', path}) {
              await manager.deleteCookie(
                  url: url, name: name, domain: domain, path: cookiePath);
            }
          }
        }
      }
    }
    for (final host in hosts) {
      for (final path in paths) {
        if ((await manager.getCookies(url: Uri.https(host, path)))
            .any((c) => authenticationCookieNames.contains(c.name))) {
          throw StateError('Browser authentication cleanup incomplete');
        }
      }
    }
  }
}

class LogoutCleanupException implements Exception {
  const LogoutCleanupException();
  @override
  String toString() => 'Authentication cleanup could not be completed';
}
