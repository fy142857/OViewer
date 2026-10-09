import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oviewer/models/apk_update.dart';
import 'package:oviewer/repositories/update_repository.dart';

Map<String, dynamic> apkManifest() {
  final candidate = {
    'version': '1.8.0',
    'build_number': 70,
    'candidate_id': '1.8.0+70',
    'source_sha': 'source',
    'build_sha': 'build'
  };
  return {
    'schema': 1,
    'version': 'v1.8.0',
    'candidate': candidate,
    'android': {
      ...candidate,
      'schema': 1,
      'platform': 'android',
      'filename': 'OViewer.apk',
      'size': 4,
      'sha256': 'a' * 64,
      'signing_cert_sha256': 'b' * 64
    }
  };
}

Map<String, dynamic> apkRelease() => {
      'tag_name': 'v1.8.0',
      'draft': false,
      'prerelease': false,
      'html_url': 'https://github.com/fy142857/OViewer/releases/tag/v1.8.0',
      'body':
          '## [1.8.0]\n### 新增\n- 新功能\n### 修复\n- 隐藏修复\n### 变更\n- 调整\n### 构建来源\n不显示',
      'assets': [
        for (final name in ['OViewer.apk', 'release-manifest.json'])
          {
            'name': name,
            'size': 4,
            'browser_download_url':
                'https://github.com/fy142857/OViewer/releases/download/v1.8.0/$name'
          }
      ],
    };

void main() {
  test(
      'only current Added/Changed sections survive provenance and older versions',
      () {
    final notes = updateReleaseNotes('''# 更新日志
## [Unreleased]
### 新增
future
## [1.8.0] - today
### 新增
new
#### 子标题
detail
### 修复
fix
### 变更
change
### 候选变更摘要
internal
## [1.7.0]
### 新增
old''', '1.8.0');
    expect(notes, contains('new'));
    expect(notes, contains('detail'));
    expect(notes, contains('change'));
    for (final hidden in ['future', 'fix', 'internal', 'old']) {
      expect(notes, isNot(contains(hidden)));
    }
    expect(
        updateReleaseNotes(
            '### Added\nnew\n### Changed\nchange\n### Fixed\nfix', '1.8.0'),
        'Added\nnew\n\nChanged\nchange');
  });

  test('Android resolves exact assets and consistent manifest', () async {
    final calls = <Uri>[];
    final repo = UpdateRepository(
        readVersion: () async => '1.7.0',
        readBuildNumber: () async => 67,
        clientFactory: () => MockClient((r) async {
              calls.add(r.url);
              return http.Response(
                  jsonEncode(r.url == UpdateRepository.endpoint
                      ? apkRelease()
                      : apkManifest()),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    final result = await repo.check(android: true).result;
    expect(result.apk!.buildNumber, 70);
    expect(result.apk!.size, 4);
    expect(result.apk!.notes, isNot(contains('隐藏修复')));
    expect(calls.length, 2);
    expect(repo.updateAvailable, isTrue);
  });

  for (final invalid in [
    'missing',
    'duplicate',
    'url',
    'size',
    'version',
    'candidate',
    'hash',
    'build'
  ]) {
    test('invalid $invalid preserves update indication and release link',
        () async {
      final release = apkRelease();
      final manifest = apkManifest();
      final android = manifest['android'] as Map<String, dynamic>;
      final assets = release['assets'] as List;
      switch (invalid) {
        case 'missing':
          release.remove('assets');
          break;
        case 'duplicate':
          assets.add(assets.first);
          break;
        case 'url':
          assets.first['browser_download_url'] = 'https://example.com/a.apk';
          break;
        case 'size':
          android['size'] = 5;
          break;
        case 'version':
          manifest['version'] = 'v1.9.0';
          break;
        case 'candidate':
          android['build_sha'] = 'other';
          break;
        case 'hash':
          android['sha256'] = 'bad';
          break;
      }
      final repo = UpdateRepository(
          readVersion: () async => '1.7.0',
          readBuildNumber: () async => invalid == 'build' ? 71 : 67,
          clientFactory: () => MockClient((r) async => http.Response(
              jsonEncode(
                  r.url == UpdateRepository.endpoint ? release : manifest),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'})));
      final result = await repo.check(android: true).result;
      expect(result.status, UpdateStatus.available);
      expect(result.apk, isNull);
      expect(
          result.apkFailure, invalid == 'build' ? 'newer_build' : 'metadata');
      expect(result.releaseUrl, isNotNull);
      expect(repo.updateAvailable, isTrue);
    });
  }

  test('iOS only requests release, even without assets', () async {
    var calls = 0;
    final repo = UpdateRepository(
        readVersion: () async => '1.7.0',
        readBuildNumber: () async => throw StateError('Not used on iOS'),
        clientFactory: () => MockClient((r) async {
              calls++;
              return http.Response(
                  jsonEncode(apkRelease()..remove('assets')), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    expect((await repo.check().result).status, UpdateStatus.available);
    expect(calls, 1);
  });
}
