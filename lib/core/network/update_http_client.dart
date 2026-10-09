import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'network_proxy_io.dart';

/// Public GitHub traffic only. Redirects are checked before sending a request.
class UpdateHttpClient extends http.BaseClient {
  UpdateHttpClient({http.Client? inner})
      : _inner = inner ?? IOClient(NetworkProxy.createUpdateHttpClient());
  final http.Client _inner;

  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      const {
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(uri.host);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var uri = request.url;
    for (var hops = 0; hops <= 5; hops++) {
      if (!allowed(uri)) throw const FormatException('Invalid update URL');
      final next = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['User-Agent'] = 'OViewer-update';
      final response = await _inner.send(next);
      if (!const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      // Do not buffer a redirect body or forward credentials to its destination.
      await response.stream.listen((_) {}).cancel();
      if (location == null) throw const FormatException('Missing redirect');
      uri = uri.resolve(location);
    }
    throw const FormatException('Too many redirects');
  }

  @override
  void close() => _inner.close();
}
