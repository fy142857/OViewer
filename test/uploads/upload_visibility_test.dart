import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:sqlite3/open.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/platform/upload_platform.dart';
import 'package:oviewer/features/uploads/upload_services.dart';

class VisibilityCookies extends app.CookieManager {
  int revision = 1;
  @override
  int get sessionRevision => revision;
  @override
  Future<bool> hasLoginCookies() async => true;
  @override
  Future<String?> getMemberId() async => '101';
  @override
  void configureDio(Dio dio) {}
}

class VisibilityPlatform extends UploadPlatform {
  @override
  Future<void> excludeFromBackup() async {}
  @override
  Future<void> cancelImport() async {}
  @override
  Future<void> prepareSession(String accountId, String epoch) async {}
  @override
  Future<Map<String, dynamic>> snapshot() async =>
      {'tasks': [], 'receipts': []};
}

String visibilityPage(
    {bool published = true,
    String category = '0',
    String? title,
    bool changedImage = false}) {
  final doc = html
      .parse(File('test/fixtures/uploads/uploaded.html').readAsStringSync());
  for (final option in doc.querySelectorAll('#category option')) {
    option.attributes.remove('selected');
    if (option.attributes['value'] == category) {
      option.attributes['selected'] = 'selected';
    }
  }
  for (final row in doc.querySelectorAll('td#d tr')) {
    final name = row.querySelector('td.k')?.text.trim();
    if (name?.startsWith('Date Posted') == true) {
      row.querySelector('td.v')?.text =
          published ? '2026-11-01 12:00' : 'Not published yet';
    }
    if (name?.startsWith('Visible') == true) {
      row.querySelector('td.v')?.text = published ? 'Yes' : 'Unpublished';
    }
  }
  if (title != null) {
    doc.querySelector('#gname_en')!.attributes['value'] = title;
  }
  if (changedImage) {
    doc.querySelector('#thumb_1')!.attributes['onclick'] =
        'view_image_init(12345,1,999999)';
  }
  return doc.outerHtml;
}

class VisibilityAdapter implements HttpClientAdapter {
  String page = visibilityPage();
  String? postPage;
  int posts = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) await requestStream.drain<void>();
    if (options.method == 'POST') {
      posts++;
      return ResponseBody.fromString(
          postPage ?? visibilityPage(category: '3'), 200);
    }
    return ResponseBody.fromString(page, 200);
  }

  @override
  void close({bool force = false}) {}
}

class VisibilityBulkRepository extends UploadRepository {
  final ManagedUploadGallery target;
  VisibilityBulkRepository(super.client, this.target);
  @override
  Future<UploadManagerSnapshot> manager(String accountId) async =>
      UploadManagerSnapshot(
          form:
              UploadForm(action: uploadOrigin.resolve('manage'), fields: const {
            'publiccat': UploadField(
                name: 'publiccat',
                type: 'select',
                options: [
                  UploadOption('3', 'Manga'),
                  UploadOption('0', 'Private')
                ]),
            'categorize': UploadField(
                name: 'categorize',
                type: 'submit',
                values: ['Change category']),
          }),
          api: const UploadApiSession(101, 'fixture-key'),
          galleries: [target],
          folders: const [],
          sort: 'd',
          direction: 'a');
}

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  late Directory root;
  late UploadStore store;
  late VisibilityCookies cookies;
  late VisibilityAdapter adapter;
  late UploadRepository repository;
  late UploadServices services;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('upload-visibility-');
    store = UploadStore(UploadDatabase(NativeDatabase.memory()), root);
    cookies = VisibilityCookies();
    adapter = VisibilityAdapter();
    repository = UploadRepository(UploadHttpClient(cookies, adapter: adapter));
    services = UploadServices(cookies,
        repository: repository, platform: VisibilityPlatform(), store: store);
    await services.store;
  });
  tearDown(() async {
    await services.dispose();
    await root.delete(recursive: true);
  });
  Future<UploadDraft> draft() => store.save(UploadDraft(
          id: 'private',
          accountId: '101',
          serverUri: uploadOrigin.resolve('managegallery?ulgid=12345'),
          fields: const {
            'category': ['3'],
            'tos': ['on']
          },
          serverFields: const {
            'category': ['0']
          },
          assets: const []));

  test(
      'published private gallery cannot become public without fresh bound consent',
      () async {
    final value = await draft();
    await expectLater(services.saveRemote(value),
        throwsA(isA<UploadVisibilityConfirmationRequired>()));
    expect(adapter.posts, 0);
    expect(await services.pendingWrite(value), isNull);
  });

  test(
      'published public gallery cannot be saved as private even with current controls',
      () async {
    adapter.page = visibilityPage(category: '3');
    final value = await store.save((await draft()).copyWith(fields: const {
      'category': ['0'],
      'tos': ['on']
    }, serverFields: const {
      'category': ['3']
    }));
    await expectLater(
        services.prepareVisibilityChange(value),
        throwsA(isA<UploadFailure>().having((e) => e.code,
            'privacy restriction', 'public_to_private_forbidden')));
    await expectLater(
        services.saveRemote(value),
        throwsA(isA<UploadFailure>().having((e) => e.code,
            'privacy restriction', 'public_to_private_forbidden')));
    expect(adapter.posts, 0);
    expect(await services.pendingWrite(value), isNull);
  });

  test(
      'a returned editor that ignored an editable title stays durably unresolved',
      () async {
    adapter.page = visibilityPage(category: '3');
    final value = await store.save((await draft()).copyWith(fields: const {
      'category': ['3'],
      'gname_en': ['A changed title'],
      'tos': ['on']
    }, serverFields: const {
      'category': ['3']
    }));
    await expectLater(
        services.saveRemote(value),
        throwsA(isA<UploadFailure>().having((e) => e.kind, 'unknown outcome',
            UploadFailureKind.resultUncertain)));
    expect(adapter.posts, 1);
    expect(await services.pendingWrite(value), isNotNull);
    await expectLater(
        services.saveRemote(value), throwsA(isA<UploadFailure>()));
    expect(adapter.posts, 1);
  });

  test('public-to-private bulk category change sends no write', () async {
    adapter.page = visibilityPage(category: '3');
    final target = ManagedUploadGallery(
        title: 'Public',
        date: '',
        category: 'Manga',
        fileCount: 8,
        section: 'p',
        selectionName: 'modify_published[]',
        selectionValue: '12345',
        actions: {'Manage': uploadOrigin.resolve('managegallery?ulgid=12345')});
    final bulk = VisibilityBulkRepository(
        UploadHttpClient(cookies, adapter: adapter), target);
    try {
      final result = await bulk.bulkModify('101', [target], categoryValue: '0');
      expect(result.items.single.status, UploadBulkStatus.skipped);
      expect(adapter.posts, 0);
    } finally {
      bulk.client.dispose();
    }
  });

  test(
      'textarea line-ending normalization is accepted when all other edits match',
      () async {
    adapter.page = visibilityPage(category: '3');
    final result = html.parse(visibilityPage(category: '3'));
    result.querySelector('textarea[name="ulcomment"]')!.text =
        'Line one\nLine two';
    adapter.postPage = result.outerHtml;
    final value = await store.save((await draft()).copyWith(fields: const {
      'category': ['3'],
      'ulcomment': ['Line one\r\nLine two'],
      'tos': ['on']
    }, serverFields: const {
      'category': ['3']
    }));
    await services.saveRemote(value);
    expect(await services.pendingWrite(value), isNull);
  });
  test('consent binds actual before-state and all proposed edits', () async {
    final value = await draft();
    final proof = (await services.prepareVisibilityChange(value))!;
    expect(proof.targetCategory, '3');
    expect(proof.editor.form.fields['category']!.value, '0');
    await expectLater(
        services.saveRemoteWithVisibility(
            value.copyWith(fields: const {
              'category': ['3'],
              'tos': ['on'],
              'ulcomment': ['changed after approval']
            }),
            proof),
        throwsA(isA<UploadFailure>()));
    expect(adapter.posts, 0);
  });
  test('new images or changed title invalidate the reviewed disclosure',
      () async {
    final value = await draft();
    final proof = (await services.prepareVisibilityChange(value))!;
    adapter.page = visibilityPage(changedImage: true);
    await expectLater(services.saveRemoteWithVisibility(value, proof),
        throwsA(isA<UploadFailure>()));
    expect(adapter.posts, 0);
    adapter.page = visibilityPage(title: 'Changed title');
    await expectLater(services.saveRemoteWithVisibility(value, proof),
        throwsA(isA<UploadFailure>()));
    expect(adapter.posts, 0);
  });
  test('same reviewed proof permits exactly the confirmed save', () async {
    final value = await draft();
    final proof = (await services.prepareVisibilityChange(value))!;
    final saved = await services.saveRemoteWithVisibility(value, proof);
    expect(adapter.posts, 1);
    expect(saved.draft.fields['category'], ['3']);
    expect(await services.pendingWrite(saved.draft), isNull);
  });
  test(
      'unpublished private-category draft does not request public release consent',
      () async {
    adapter.page = visibilityPage(published: false);
    final value = await draft();
    expect(await services.prepareVisibilityChange(value), isNull);
    await services.saveRemote(value);
    expect(adapter.posts, 1);
  });
  test('consent from a previous login cannot authorize a later session',
      () async {
    final value = await draft();
    final proof = (await services.prepareVisibilityChange(value))!;
    cookies.revision++;
    await expectLater(services.saveRemoteWithVisibility(value, proof),
        throwsA(isA<UploadFailure>()));
    expect(adapter.posts, 0);
  });
  test(
      'repeated category parameters cannot hide a public target behind private zero',
      () async {
    final value = await draft();
    await expectLater(
        services.saveRemote(value.copyWith(fields: const {
          'category': ['0', '3'],
          'tos': ['on']
        })),
        throwsArgumentError);
    expect(adapter.posts, 0);
  });

  test(
      'reviewed bulk proof reaches the write but an unrecognized reply stays uncertain',
      () async {
    final target = ManagedUploadGallery(
        title: 'Private',
        date: '2026-11-01',
        category: 'Private',
        fileCount: 8,
        section: 'p',
        actions: {'Manage': uploadOrigin.resolve('managegallery?ulgid=12345')},
        selectionName: 'modify_published[]',
        selectionValue: '12345');
    await services.dispose();
    store = UploadStore(UploadDatabase(NativeDatabase.memory()), root);
    final bulkRepo = VisibilityBulkRepository(
        UploadHttpClient(cookies, adapter: adapter), target);
    services = UploadServices(cookies,
        repository: bulkRepo, platform: VisibilityPlatform(), store: store);
    final proofs =
        await services.prepareBulkVisibilityChange('101', [target], '3');
    expect(proofs, hasLength(1));
    final result = await services.bulkModifyWithVisibility('101', [target],
        categoryValue: '3', consents: proofs);
    expect(adapter.posts, 1);
    // The test server intentionally returns an editor, not the required
    // updated manager. Authorization must not be mistaken for success.
    expect(result.items.single.status, UploadBulkStatus.uncertain);
  });

  test('standalone repository and bulk path fail closed without a privacy hook',
      () async {
    final standalone =
        UploadRepository(UploadHttpClient(cookies, adapter: adapter));
    await expectLater(
        standalone.save(
            '101', uploadOrigin.resolve('managegallery?ulgid=12345'), const {
          'category': ['3'],
          'tos': ['on']
        }),
        throwsA(isA<UploadVisibilityConfirmationRequired>()));
    final target = ManagedUploadGallery(
        title: 'Private',
        date: '2026-11-01',
        category: 'Private',
        fileCount: 8,
        section: 'p',
        actions: {'Manage': uploadOrigin.resolve('managegallery?ulgid=12345')},
        selectionName: 'modify_published[]',
        selectionValue: '12345');
    final bulk = VisibilityBulkRepository(standalone.client, target);
    final result = await bulk.bulkModify('101', [target], categoryValue: '3');
    expect(result.items.single.status, UploadBulkStatus.failed);
    expect(adapter.posts, 0);
    standalone.client.dispose();
  });
}
