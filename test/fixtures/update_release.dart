import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oviewer/repositories/update_repository.dart';

Map<String, dynamic> release({String tag = 'v1.2.0'}) => {
      'tag_name': tag,
      'html_url': 'https://github.com/fy142857/OViewer/releases/tag/$tag',
      'draft': false,
      'prerelease': false,
      'assets': [
        for (final name in [
          'OViewer.apk',
          'OViewer.ipa',
          'release-manifest.json'
        ])
          {
            'name': name,
            'size': 4,
            'browser_download_url':
                'https://github.com/fy142857/OViewer/releases/download/$tag/$name'
          },
      ],
    };

Map<String, dynamic> releaseManifest(
    {String version = '1.2.0', int build = 32}) {
  final candidate = {
    'version': version,
    'build_number': build,
    'candidate_id': '$version+$build',
    'source_sha': 'source',
    'build_sha': 'build',
  };
  return {
    'schema': 1,
    'version': 'v$version',
    'candidate': candidate,
    for (final platform in ['android', 'ios'])
      platform: {
        ...candidate,
        'schema': 1,
        'platform': platform,
        'filename': platform == 'android' ? 'OViewer.apk' : 'OViewer.ipa',
        'size': 4,
        'sha256': 'a' * 64,
        if (platform == 'android') 'signing_cert_sha256': 'b' * 64,
      },
  };
}

http.Response jsonResponse(Object data) => http.Response(jsonEncode(data), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class TrackingClient extends MockClient {
  TrackingClient(super.handler);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

/// Widget checks count release lookups separately from manifest requests.
class ReleaseClient extends TrackingClient {
  ReleaseClient(Future<http.Response> Function(http.Request) handler)
      : super((request) => request.url == UpdateRepository.endpoint
            ? handler(request)
            : Future.value(jsonResponse(releaseManifest())));
}
