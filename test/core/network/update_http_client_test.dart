import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oviewer/core/network/update_http_client.dart';

void main() {
  for (final destination in [
    'http://github.com/a',
    'https://evil.example/a',
    'https://github.com@evil.example/a'
  ]) {
    test('rejects redirect $destination before sending', () async {
      var calls = 0;
      final client = UpdateHttpClient(inner: MockClient((r) async {
        calls++;
        return http.Response('', 302, headers: {'location': destination});
      }));
      await expectLater(client.get(Uri.parse('https://github.com/start')),
          throwsFormatException);
      expect(calls, 1);
      client.close();
    });
  }
  test('follows GitHub CDN redirect without cookies or authorization',
      () async {
    var calls = 0;
    final client = UpdateHttpClient(inner: MockClient((r) async {
      calls++;
      expect(r.headers.containsKey('cookie'), isFalse);
      expect(r.headers.containsKey('authorization'), isFalse);
      expect(r.followRedirects, isFalse);
      return calls == 1
          ? http.Response('', 302, headers: {
              'location':
                  'https://release-assets.githubusercontent.com/asset?token=public'
            })
          : http.Response('apk', 200);
    }));
    final response = await client.get(Uri.parse('https://github.com/start'),
        headers: {'Cookie': 'private', 'Authorization': 'private'});
    expect(response.body, 'apk');
    expect(calls, 2);
    client.close();
  });
}
