// Read-only recovery contract tests. Published/clone states are synthetic
// variations of the sanitized fixture, not evidence of live publication.
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:sqlite3/open.dart';
import 'package:oviewer/features/uploads/data/upload_advanced_actions.dart';
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/upload_services.dart';

import 'upload_services_test.dart' show UploadTestCookies, UploadTestPlatform;

class _Client extends UploadHttpClient {
  _Client(super.cookies);
  final pages = <String, String>{};
  final reads = <Uri>[];
  @override
  Future<UploadResponse> get(Uri uri, {CancelToken? cancelToken}) async {
    expect(uri.queryParameters.containsKey('act'), isFalse);
    reads.add(uri);
    final body = pages[uploadGalleryId(uri)];
    if (body == null) throw const UploadFailure(UploadFailureKind.network);
    return UploadResponse(uri, body);
  }
}

class _Repository extends UploadRepository {
  _Repository(super.client);
  List<ManagedUploadGallery> rows = [];
  List<UploadFolderSection> sections = [];
  List<ManagedUploadGallery> folderRows = [];
  @override
  Future<UploadManagerSnapshot> manager(String accountId) async {
    final base = protocol
        .manager(File('test/fixtures/uploads/manage.html').readAsStringSync());
    return UploadManagerSnapshot(
        form: base.form,
        api: base.api,
        galleries: List.of(rows),
        folders: List.of(sections),
        sort: base.sort,
        direction: base.direction);
  }

  @override
  Future<List<ManagedUploadGallery>> folder(String accountId,
          UploadManagerSnapshot manager, UploadFolderSection folder) async =>
      List.of(folderRows);
}

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  final original = uploadOrigin.resolve('managegallery?ulgid=12345');
  final public = Uri.parse('https://e-hentai.org/g/99999/abcde12345/');
  late Directory root;
  late UploadStore storage;
  late UploadTestCookies cookies;
  late _Client client;
  late _Repository repository;
  late UploadServices service;
  late UploadDraft draft;

  String page(
      {String id = '12345',
      bool locked = false,
      bool published = false,
      String? parent,
      bool misleading = false}) {
    final doc = html.parse(File('test/fixtures/uploads/uploaded.html')
        .readAsStringSync()
        .replaceAll('12345', id));
    if (locked) {
      doc.querySelector('#uploadbutton')!.attributes['disabled'] = 'disabled';
    }
    if (published) {
      for (final row in doc.querySelectorAll('td#d tr')) {
        final label = row.querySelector('td.k')?.text;
        if (label == 'Date Posted:') {
          row.querySelector('td.v')!.text = '2026-11-12 12:00';
        }
        if (label == 'Visible:') row.querySelector('td.v')!.text = 'Yes';
      }
      doc.querySelector('#publishbutton')!.attributes['disabled'] = 'disabled';
      doc.querySelector('td#d')!.append(Element.tag('a')
        ..attributes['href'] = public.toString()
        ..text = 'Show Public Gallery');
    }
    if (parent != null) {
      final row = Element.tag('tr');
      row.append(Element.tag('td')
        ..classes.add('k')
        ..text = 'Parent Gallery:');
      row.append(Element.tag('td')
        ..classes.add('v')
        ..append(Element.tag('a')
          ..attributes['href'] = parent
          ..text = 'Same title'));
      if (misleading) {
        doc.body!.append(Element.tag('table')..append(row));
      } else {
        doc.querySelector('td#d table')!.append(row);
      }
    }
    return doc.documentElement!.outerHtml;
  }

  ManagedUploadGallery row(String id) => ManagedUploadGallery(
      title: 'Same title',
      date: '',
      category: 'Non-H',
      fileCount: 8,
      section: 'p',
      actions: {'Manage': uploadOrigin.resolve('managegallery?ulgid=$id')});

  setUp(() async {
    root = await Directory.systemTemp.createTemp('upload-recovery-');
    storage = UploadStore(UploadDatabase(NativeDatabase.memory()), root);
    cookies = UploadTestCookies();
    client = _Client(cookies)..pages['12345'] = page();
    repository = _Repository(client)..rows = [row('12345')];
    service = UploadServices(cookies,
        repository: repository, platform: UploadTestPlatform(), store: storage);
    await service.store;
    draft = await storage.save(UploadDraft(
        id: 'recovery',
        accountId: '101',
        fields: const {
          'gname_en': ['Same title']
        },
        assets: const [],
        serverUri: original));
  });
  tearDown(() async {
    await service.dispose();
    await root.delete(recursive: true);
  });

  Future<String> begin(String kind) => storage.beginWrite(draft,
      kind: kind,
      context: {'beforeCanUpload': false, 'publicUri': public.toString()});

  test('save recovery requires the operation reviewed before confirmation',
      () async {
    final first = await begin('save');
    await expectLater(
        service.retryAfterVerifiedNoChange(draft, confirmed: true),
        throwsStateError);
    await storage.resolveWrite('101', draft.id, first);
    final second = await begin('save');
    await expectLater(
        service.retryAfterVerifiedNoChange(draft,
            confirmed: true, expectedOperationId: first),
        throwsStateError);
    await expectLater(
        service.associatePendingGallery(draft, original,
            expectedOperationId: first),
        throwsStateError);
    expect((await service.pendingWrite(draft))!.operationId, second);
    await service.retryAfterVerifiedNoChange(draft,
        confirmed: true, expectedOperationId: second);
    expect((await storage.writeHistory('101', draft.id)).last.outcome,
        'manual_no_effect');
    expect(client.reads, isEmpty);
  });

  test(
      'publication appearing after review is confirmed instead of marked ineffective',
      () async {
    await begin('publish');
    final review = await service.prepareAdvancedRecovery(draft);
    expect(review.canMarkNoEffect, isTrue);
    await expectLater(
        service.resolveAdvancedRecovery(draft, review,
            confirmedNoEffect: false),
        throwsA(isA<UploadFailure>()));
    client.pages['12345'] = page(published: true, locked: true);
    final result = await service.resolveAdvancedRecovery(draft, review,
        confirmedNoEffect: true);
    expect(result!.kind, UploadGalleryAction.publish);
    expect(result.publicUri, public);
    expect((await storage.draft('101', draft.id))!.remoteState, 'published');
    expect((await storage.writeHistory('101', draft.id)).single.outcome,
        'current_state_confirmed');
  });

  test('unpublished state without the publish control stays unresolved',
      () async {
    await begin('publish');
    final doc = html.parse(page());
    doc.querySelector('#publishbutton')!.attributes['disabled'] = 'disabled';
    client.pages['12345'] = doc.documentElement!.outerHtml;
    final review = await service.prepareAdvancedRecovery(draft);
    expect(review.canMarkNoEffect, isFalse);
    await expectLater(
        service.resolveAdvancedRecovery(draft, review, confirmedNoEffect: true),
        throwsA(isA<UploadFailure>()));
    expect(await service.pendingWrite(draft), isNotNull);
  });

  for (final action in ['delete', 'disown']) {
    test(
        '$action rechecks ownership and only then allows a manual no-effect decision',
        () async {
      await begin(action);
      final review = await service.prepareAdvancedRecovery(draft);
      expect(review.canMarkNoEffect, isTrue);
      expect(
          await service.resolveAdvancedRecovery(draft, review,
              confirmedNoEffect: true),
          isNull);
      expect((await storage.draft('101', draft.id))!.remoteState, isNull);
      expect((await storage.writeHistory('101', draft.id)).single.outcome,
          'manual_no_effect');
    });
    test(
        '$action disappearance at confirmation becomes the observed terminal state',
        () async {
      await begin(action);
      final review = await service.prepareAdvancedRecovery(draft);
      repository.rows = [];
      final result = await service.resolveAdvancedRecovery(draft, review,
          confirmedNoEffect: true);
      expect(result!.localDraftId, draft.id);
      expect((await storage.draft('101', draft.id))!.remoteState,
          action == 'delete' ? 'deleted' : 'disowned');
      expect((await storage.writeHistory('101', draft.id)).single.outcome,
          'current_state_confirmed');
    });
  }

  test(
      'clone manual exit requires a still-locked parent and complete candidate inspection',
      () async {
    client.pages['12345'] = page(locked: true, published: true);
    client.pages['54321'] =
        page(id: '54321', parent: public.toString(), misleading: true);
    repository.rows.add(row('54321'));
    await begin('clone');
    final review = await service.prepareAdvancedRecovery(draft);
    expect(review.candidates, isEmpty);
    expect(review.canMarkNoEffect, isTrue);
    expect(
        await service.resolveAdvancedRecovery(draft, review,
            confirmedNoEffect: true),
        isNull);
    expect((await storage.drafts('101')), hasLength(1));
    expect((await storage.writeHistory('101', draft.id)).single.outcome,
        'manual_no_effect');
  });

  test(
      'parent-linked child requires explicit selection and preserves its local identity',
      () async {
    client.pages['12345'] = page(locked: true, published: true);
    client.pages['54321'] = page(id: '54321', parent: public.toString());
    repository.rows.add(row('54321'));
    await begin('clone');
    final review = await service.prepareAdvancedRecovery(draft);
    expect(review.candidates, hasLength(1));
    expect(review.canMarkNoEffect, isFalse);
    await expectLater(
        service.resolveAdvancedRecovery(draft, review, confirmedNoEffect: true),
        throwsA(isA<UploadFailure>()));
    final result = await service.resolveAdvancedRecovery(draft, review,
        selectedEditor: review.candidates.single.uri, confirmedNoEffect: false);
    expect(result!.localDraftId, isNot(draft.id));
    expect((await storage.draft('101', result.localDraftId!))!.parentDraftId,
        draft.id);
  });

  test(
      'a child appearing after the no-effect review prevents clearing the operation',
      () async {
    client.pages['12345'] = page(locked: true, published: true);
    await begin('clone');
    final review = await service.prepareAdvancedRecovery(draft);
    client.pages['54321'] = page(id: '54321', parent: original.toString());
    repository.rows.add(row('54321'));
    await expectLater(
        service.resolveAdvancedRecovery(draft, review, confirmedNoEffect: true),
        throwsA(isA<UploadFailure>()));
    expect(await service.pendingWrite(draft), isNotNull);
  });

  test('a partial collapsed folder never proves that an action had no effect',
      () async {
    client.pages['12345'] = page(locked: true, published: true);
    repository.sections = [
      const UploadFolderSection('p', 1, 'Hidden', true, galleryCount: 1)
    ];
    await begin('clone');
    await expectLater(
        service.prepareAdvancedRecovery(draft), throwsA(isA<UploadFailure>()));
    expect(await service.pendingWrite(draft), isNotNull);
  });

  test('recovery cannot clear a newer pending write or another login session',
      () async {
    final first = await begin('publish');
    final review = await service.prepareAdvancedRecovery(draft);
    await storage.resolveWrite('101', draft.id, first);
    final second = await begin('publish');
    await expectLater(
        service.resolveAdvancedRecovery(draft, review, confirmedNoEffect: true),
        throwsStateError);
    expect((await service.pendingWrite(draft))!.operationId, second);
    final current = await service.prepareAdvancedRecovery(draft);
    cookies.revision++;
    await expectLater(
        service.resolveAdvancedRecovery(draft, current,
            confirmedNoEffect: true),
        throwsA(isA<UploadFailure>()));
    expect((await service.pendingWrite(draft))!.operationId, second);
  });

  test(
      'observed in-place unlock creates a child and is not labeled ineffective',
      () async {
    client.pages['12345'] = page(locked: true, published: true);
    await begin('clone');
    final review = await service.prepareAdvancedRecovery(draft);
    client.pages['12345'] = page();
    final result = await service.resolveAdvancedRecovery(draft, review,
        confirmedNoEffect: true);
    expect(result!.kind, UploadGalleryAction.clone);
    expect(result.localDraftId, isNot(draft.id));
    expect((await storage.draft('101', result.localDraftId!))!.serverUri,
        original);
    expect((await storage.writeHistory('101', draft.id)).single.outcome,
        'current_state_confirmed');
  });
}
