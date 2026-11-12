import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';

String fixture(String name) =>
    File('test/fixtures/uploads/$name.html').readAsStringSync();
const protocol = UploadProtocol();
final galleryUri = uploadOrigin.resolve('managegallery?ulgid=12345');

class Session extends app.CookieManager {
  int revision = 1;
  String? account = '101';
  @override
  int get sessionRevision => revision;
  @override
  Future<String?> getMemberId() async => account;
  @override
  void configureDio(Dio dio) {}
}

class Request {
  final Uri uri;
  final Map<String, List<String>> fields;
  Request(this.uri, this.fields);
}

class FixtureClient extends UploadHttpClient {
  final Session session;
  FutureOr<String> Function(Uri) read;
  FutureOr<String> Function(Request)? write;
  FutureOr<Map<String, dynamic>> Function(String, Map<String, Object>)? apiRead;
  final posts = <Request>[];
  final gets = <Uri>[];
  FixtureClient(this.session, this.read) : super(session);
  @override
  Future<UploadResponse> get(Uri uri, {CancelToken? cancelToken}) async {
    gets.add(uri);
    return UploadResponse(uri, await read(uri));
  }

  @override
  Future<UploadResponse> postForm(
      UploadForm form, Map<String, List<String>> edits,
      {CancelToken? cancelToken}) async {
    final request = Request(form.action, form.submission(edits));
    posts.add(request);
    return UploadResponse(form.action, await write!(request));
  }

  @override
  Future<Map<String, dynamic>> readApi(
          UploadApiSession api, String method, Map<String, Object> arguments,
          {CancelToken? cancelToken, Uri? referer}) async =>
      await apiRead!(method, arguments);
}

String renamedFolder(String name) {
  final doc = html.parse(fixture('populated-folders'));
  doc.querySelector('input[name="fn1"]')!.attributes['value'] = name;
  return doc.outerHtml;
}

String movedManager() {
  final doc = html.parse(fixture('populated-manager'));
  doc.getElementById('frow_u_1')!.id = 'frow_u_0';
  doc.getElementById('ft_u_1')!.id = 'ft_u_0';
  return doc.outerHtml;
}

void main() {
  late Session session;
  late FixtureClient client;
  late UploadRepository repository;
  setUp(() {
    session = Session();
    client = FixtureClient(
        session,
        (uri) => switch (uri.path) {
              '/managefolders' => fixture('populated-folders'),
              '/manage' => fixture('populated-manager'),
              '/managegallery' => fixture('uploaded'),
              _ => throw StateError('Unexpected read'),
            });
    repository = UploadRepository(client);
  });
  tearDown(() => client.dispose());

  test('management identity never selects a delete link that appears first',
      () {
    final gallery = ManagedUploadGallery(
        title: 'Example',
        date: '',
        category: 'Non-H',
        fileCount: 8,
        section: 'u',
        actions: {
          'Delete':
              uploadOrigin.resolve('managegallery?ulgid=12345&act=delete'),
          'Publish':
              uploadOrigin.resolve('managegallery?ulgid=12345&act=publish'),
          'Manage': galleryUri,
        });
    expect(gallery.managementUri, galleryUri);
  });

  test(
      'publication states use observed headings and never guess unknown sections public',
      () {
    final observed = protocol.manager(fixture('populated-manager'));
    expect(observed.sectionLabels['u'], 'Unpublished Galleries');
    expect(observed.galleries.single.publication,
        ManagedUploadPublication.unpublished);
    ManagedUploadGallery row(String section, String? label, String category) =>
        ManagedUploadGallery(
            title: 'Example',
            date: '',
            category: category,
            fileCount: 1,
            section: section,
            sectionLabel: label,
            actions: {'Manage': galleryUri});
    expect(
        row('p', null, 'Non-H').publication, ManagedUploadPublication.unknown);
    expect(row('r', 'Removed Galleries', 'Non-H').publication,
        ManagedUploadPublication.unknown);
    expect(row('p', 'Published Galleries', 'Non-H').publication,
        ManagedUploadPublication.published);
    expect(row('u', 'Unpublished Galleries', '(Private / Unlisted)').isPrivate,
        isTrue);
    expect(
        row('u', 'Unpublished Galleries', '(Private / Unlisted)').publication,
        ManagedUploadPublication.unpublished);
  });

  test(
      'application write guard runs outside the request and can block native conflicts',
      () async {
    final baseline = await repository.folders('101');
    Uri? guarded;
    repository.beforeWrite = (uri) async {
      guarded = uri;
      throw const UploadFailure(UploadFailureKind.restricted);
    };
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()));
    expect(guarded, uploadOrigin.resolve('managefolders'));
    expect(client.posts, isEmpty);
    repository.beforeWrite = (_) async {
      session.revision++;
    };
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    expect(client.posts, isEmpty);
  });

  test(
      'observed populated manager and folders retain selection and folder identities',
      () {
    final manager = protocol.manager(fixture('populated-manager'));
    final folder =
        protocol.folders(fixture('populated-folders')).folders.single;
    expect(manager.folders.single.state, 'u');
    expect(manager.folders.single.galleryCount, 1);
    expect(manager.folders.single.label, 'Fixture upload verification');
    expect(manager.galleries.single.folderId, 1);
    expect(manager.galleries.single.canSelect, isTrue);
    expect(manager.galleries.single.selectionName, 'modify_unpublish[]');
    expect(manager.form.fields['folderize']!.value, 'Go');
    expect(folder.nameField.maxLength, 50);
    expect(folder.positionField.name, 'fs1');
    expect(folder.canDelete, isTrue);
  });

  test(
      'folder identity is bound by a separate owner manager read and the current cookie account',
      () async {
    final result = await repository.folders('101');
    expect(result.accountId, '101');
    expect(result.sessionRevision, session.revision);
    expect(client.gets.map((uri) => uri.path), ['/managefolders', '/manage']);
    client.gets.clear();
    session.account = '202';
    await expectLater(
        repository.folders('101'),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    expect(client.gets, isEmpty);
  });

  test(
      'folder display rejects a different manager owner even when local cookie identity did not change',
      () async {
    client.read = (uri) => uri.path == '/manage'
        ? fixture('manage')
            .replaceFirst(RegExp(r'var apiuid\s*=\s*101'), 'var apiuid = 202')
        : fixture('populated-folders');
    await expectLater(
        repository.folders('101'),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    expect(client.posts, isEmpty);
  });

  test(
      'folder parsing alone and a previous login snapshot cannot authorize a write',
      () async {
    final parsed = protocol.folders(fixture('populated-folders'));
    await expectLater(
        repository.saveFolders('101', parsed, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()));
    expect(client.gets, isEmpty);
    final bound = await repository.folders('101');
    session.revision++;
    client.gets.clear();
    await expectLater(
        repository.saveFolders('101', bound, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    expect(client.gets, isEmpty);
    expect(client.posts, isEmpty);
  });

  test('folder owner is checked again after the app write guard before a POST',
      () async {
    final baseline = await repository.folders('101');
    var changed = false;
    repository.beforeWrite = (_) async {
      changed = true;
    };
    client.read = (uri) => uri.path == '/manage'
        ? fixture('manage').replaceFirst(RegExp(r'var apiuid\s*=\s*101'),
            'var apiuid = ${changed ? 202 : 101}')
        : fixture('populated-folders');
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    expect(changed, isTrue);
    expect(client.posts, isEmpty);
  });

  test(
      'folder POST with a changed owner on readback remains uncertain and is not repeated',
      () async {
    final baseline = await repository.folders('101');
    var posted = false;
    client.write = (_) {
      posted = true;
      return renamedFolder('New');
    };
    client.read = (uri) => uri.path == '/manage'
        ? fixture('manage').replaceFirst(RegExp(r'var apiuid\s*=\s*101'),
            'var apiuid = ${posted ? 202 : 101}')
        : fixture('populated-folders');
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(client.posts, hasLength(1));
  });

  test(
      'folder creation confirms new form content and returns a bound snapshot without API fields',
      () async {
    client.read =
        (uri) => uri.path == '/manage' ? fixture('manage') : fixture('folders');
    final baseline = await repository.folders('101');
    client.write = (_) => renamedFolder('New empty folder');
    final result = await repository.saveFolders('101', baseline,
        newName: 'New empty folder');
    expect(result.folders.single.name, 'New empty folder');
    expect(result.accountId, '101');
    expect(result.sessionRevision, session.revision);
    expect(client.posts.single.fields['fname'], ['New empty folder']);
    expect(client.posts.single.fields.keys, isNot(contains('apikey')));
  });

  test(
      'an unknown folder count cannot be treated as proof that deleting it is safe',
      () async {
    final manager = html.parse(fixture('populated-manager'));
    manager.querySelector('#frow_u_1 strong')!.remove();
    manager.querySelector('#ft_u_1')!.text = '[+]';
    manager.querySelector('td.gtc1')!.parent!.remove();
    client.read = (uri) => uri.path == '/manage'
        ? manager.outerHtml
        : fixture('populated-folders');
    client.apiRead = (_, __) => throw StateError(
        'An empty partial API reply is not proof of an empty folder');
    await expectLater(
        repository.deleteEmptyFolder('101', 1),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.restricted)));
    expect(client.posts, isEmpty);
  });

  test(
      'empty-folder deletion checks ownership after its POST before declaring completion',
      () async {
    var posted = false;
    client.read = (uri) => uri.path == '/manage'
        ? fixture('manage').replaceFirst(RegExp(r'var apiuid\s*=\s*101'),
            'var apiuid = ${posted ? 202 : 101}')
        : fixture('populated-folders');
    client.write = (_) {
      posted = true;
      return fixture('folders');
    };
    await expectLater(
        repository.deleteEmptyFolder('101', 1),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(client.posts, hasLength(1));
  });

  test(
      'folder rename uses observed hidden commands without enabling arbitrary hidden edits',
      () async {
    final baseline = await repository.folders('101');
    client.write = (_) => renamedFolder('Renamed');
    final result = await repository
        .saveFolders('101', baseline, renamed: {1: ' Renamed '});
    expect(result.folders.single.name, 'Renamed');
    expect(client.posts.single.fields['do_save'], ['1']);
    expect(client.posts.single.fields['do_delete'], ['']);
    expect(client.posts.single.fields['do_autosort'], ['']);
    expect(client.posts.single.fields['fn1'], ['Renamed']);
    expect(
        () => baseline.form.submission({
              'do_delete': ['1']
            }),
        throwsA(isA<UploadFailure>()));
  });

  test('folder rename refuses a changed baseline or an excessive current name',
      () async {
    final baseline = await repository.folders('101');
    client.read = (uri) => uri.path == '/manage'
        ? fixture('populated-manager')
        : renamedFolder('Changed elsewhere');
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'Mine'}),
        throwsA(isA<UploadFailure>()));
    expect(client.posts, isEmpty);
    client.read = (uri) => uri.path == '/manage'
        ? fixture('populated-manager')
        : fixture('populated-folders');
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'x' * 51}),
        throwsArgumentError);
    expect(client.posts, isEmpty);
  });

  test('deleting a folder with galleries is rejected before any write',
      () async {
    await expectLater(
        repository.deleteEmptyFolder('101', 1),
        throwsA(isA<UploadFailure>().having(
            (error) => error.kind, 'kind', UploadFailureKind.restricted)));
    expect(client.posts, isEmpty);
  });

  test('empty folder deletion is verified against the returned folder list',
      () async {
    client.read = (uri) => uri.path == '/manage'
        ? fixture('manage')
        : fixture('populated-folders');
    client.write = (_) => fixture('folders');
    final result = await repository.deleteEmptyFolder('101', 1);
    expect(result.folders, isEmpty);
    expect(client.posts.single.fields['do_delete'], ['1']);
    expect(client.posts.single.fields['do_save'], ['']);
  });

  test(
      'folder mutation response without the intended result is uncertain, never replayed',
      () async {
    final baseline = await repository.folders('101');
    client.write = (_) => fixture('populated-folders');
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(client.posts, hasLength(1));
  });

  test('session replacement between refresh and mutation prevents the write',
      () async {
    final baseline = await repository.folders('101');
    client.read = (_) {
      session.revision++;
      return fixture('populated-folders');
    };
    await expectLater(
        repository.saveFolders('101', baseline, renamed: {1: 'New'}),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    expect(client.posts, isEmpty);
  });

  test(
      'writes serialize their refresh and submission, and queued sessions are frozen',
      () async {
    final baseline = await repository.folders('101');
    final held = Completer<String>();
    var reads = 0;
    client.read = (uri) {
      if (uri.path == '/manage') return fixture('populated-manager');
      reads++;
      return fixture('populated-folders');
    };
    client.write = (_) => held.future;
    final first =
        repository.saveFolders('101', baseline, renamed: {1: 'First'});
    final firstCheck = expectLater(
        first,
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    final queued =
        repository.saveFolders('101', baseline, renamed: {1: 'Second'});
    final queuedCheck = expectLater(
        queued,
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    expect(client.posts, hasLength(1));
    session.revision++;
    held.complete(renamedFolder('First'));
    await firstCheck;
    await queuedCheck;
    expect(reads, 1);
    expect(client.posts, hasLength(1));
  });

  test(
      'bulk folder move submits exactly the selected gallery and selected submitter',
      () async {
    final baseline = protocol.manager(fixture('populated-manager'));
    client.write = (_) => movedManager();
    final result =
        await repository.bulkModify('101', baseline.galleries, folderId: 0);
    expect(result.items.single.status, UploadBulkStatus.completed);
    final fields = client.posts.single.fields;
    expect(fields['modify_unpublish[]'], ['12345']);
    expect(fields['folderid'], ['0']);
    expect(fields['folderize'], ['Go']);
    expect(fields, isNot(contains('categorize')));
  });

  test('changed bulk target is skipped without overriding its new content',
      () async {
    final baseline = protocol.manager(fixture('populated-manager'));
    client.read = (_) => fixture('populated-manager').replaceFirst(
        'Fixture upload verification 2026-11-12', 'Changed gallery');
    final result =
        await repository.bulkModify('101', baseline.galleries, folderId: 0);
    expect(result.items.single.status, UploadBulkStatus.skipped);
    expect(client.posts, isEmpty);
  });

  test('cancelled bulk actions never start requests', () async {
    final baseline = protocol.manager(fixture('populated-manager'));
    final result = await repository.bulkModify('101', baseline.galleries,
        folderId: 0, isCancelled: () => true);
    expect(result.items.single.status, UploadBulkStatus.notExecuted);
    expect(client.gets, isEmpty);
    expect(client.posts, isEmpty);
  });

  test(
      'manual reordering uses readonly controls intentionally and verifies content order',
      () async {
    final baseline = protocol.editor(fixture('uploaded'), galleryUri);
    client.write = (_) => fixture('reordered');
    final result = await repository.reorderImages('101', baseline, {
      for (var i = 0; i < baseline.images.length; i++)
        baseline.images[i].positionField: baseline.images.length - i,
    });
    expect(result.images.map((image) => image.name),
        baseline.images.reversed.map((image) => image.name));
    expect(client.posts.single.fields['do_reorder'], ['manual']);
    expect(client.posts.single.fields['pagesel_1'], ['8']);
    expect(client.posts.single.fields, isNot(contains('tos')));
    expect(
        () => baseline.reorderForm!.submission({
              'pagesel_1': ['8']
            }),
        throwsA(isA<UploadFailure>()));
  });

  test(
      'image mutation validates every position and rejects changed remote images',
      () async {
    final baseline = protocol.editor(fixture('uploaded'), galleryUri);
    await expectLater(
        repository.reorderImages('101', baseline, {'pagesel_1': 1}),
        throwsArgumentError);
    await expectLater(
        repository.reorderImages('101', baseline,
            {for (final image in baseline.images) image.positionField: 1}),
        throwsArgumentError);
    client.read = (_) => fixture('reordered');
    await expectLater(
        repository.reorderImages('101', baseline, {
          for (final image in baseline.images)
            image.positionField: image.position
        }),
        throwsA(isA<UploadFailure>()));
    expect(client.posts, isEmpty);
  });

  test('old image order returned after a requested reorder is uncertain',
      () async {
    final baseline = protocol.editor(fixture('uploaded'), galleryUri);
    client.write = (_) => fixture('uploaded');
    await expectLater(
        repository.reorderImages('101', baseline, {
          for (var i = 0; i < baseline.images.length; i++)
            baseline.images[i].positionField: baseline.images.length - i,
        }),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(client.posts, hasLength(1));
  });

  test(
      'viewimage uses the observed gallery/page/file identity and rejects outside hosts',
      () async {
    final baseline = protocol.editor(fixture('uploaded'), galleryUri);
    client.apiRead = (method, args) {
      expect(method, 'viewimage');
      expect(args['ulgid'], 12345);
      expect(args['page'], 1);
      expect(args['fileindex'], baseline.images.first.fileIndex);
      return {'url': 'https://example.hath.network/signed-image'};
    };
    expect(
        (await repository.imageUri('101', baseline, baseline.images.first))
            .host,
        'example.hath.network');
    client.apiRead = (_, __) =>
        {'url': 'https://example.hath.network.attacker.invalid/image'};
    await expectLater(
        repository.imageUri('101', baseline, baseline.images.first),
        throwsA(isA<UploadFailure>()));
  });
}
