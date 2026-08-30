import 'dart:io';

/// Shared proxy policy for every native HTTP client.
///
/// Dio and flutter_cache_manager use different HTTP stacks. Keeping the
/// selected proxy here ensures gallery HTML, API calls and thumbnails take the
/// same network route.
class NetworkProxy {
  NetworkProxy._();

  static String? _proxyUrl;

  static bool get isEnabled => _proxyUrl != null && _proxyUrl!.isNotEmpty;

  static void setProxy(String? proxyUrl) {
    _proxyUrl = proxyUrl?.trim();
  }

  static HttpClient createHttpClient() {
    final client = HttpClient();
    client.findProxy = (uri) => _proxyDirective();
    if (_proxyUrl != null && _proxyUrl!.isNotEmpty) {
      // Some local interception proxies use their own certificate authority.
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }
    return client;
  }

  static String _proxyDirective() {
    final proxyUrl = _proxyUrl;
    if (proxyUrl == null || proxyUrl.isEmpty) return 'DIRECT';

    if (proxyUrl.startsWith('socks5://')) {
      return 'PROXY ${proxyUrl.replaceFirst('socks5://', '')}';
    }
    if (proxyUrl.startsWith('http://') || proxyUrl.startsWith('https://')) {
      return 'PROXY ${proxyUrl.replaceFirst(RegExp(r'https?://'), '')}';
    }
    return 'PROXY $proxyUrl';
  }
}
