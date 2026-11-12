import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_advanced_actions.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/platform/upload_platform.dart';
import 'package:oviewer/features/uploads/upload_services.dart';
import 'package:oviewer/features/uploads/files/upload_asset.dart';
import 'package:oviewer/features/uploads/files/upload_asset_preparer.dart';

class UploadTestCookies extends app.CookieManager {
  String? account = '101';
  int revision = 1;
  @override
  int get sessionRevision => revision;
  @override
  Future<String?> getMemberId() async => account;
  @override
  Future<bool> hasLoginCookies() async => account != null;
  @override
  void configureDio(Dio dio) {}
  @override
  Future<String> getCookieHeader(Uri uri) async =>
      'ipb_member_id=101; ipb_pass_hash=test';
  @override
  Future<String> getUploadCookieHeader() async =>
      'ipb_member_id=101; ipb_pass_hash=test';
}

class UploadTestPlatform extends UploadPlatform {
  Future<Map<String, dynamic>> Function()? onPick;
  Future<void> Function()? onCancel;
  Future<Map<String, dynamic>> Function(String)? onConvert;
  final invalidated = <String>[];
  final prepared = <String>[];
  int backupCalls = 0;
  Map<String, dynamic> state = {'tasks': [], 'receipts': []};
  final enqueued = <Map<String, Object?>>[];
  @override
  Future<void> excludeFromBackup() async {
    backupCalls++;
  }

  @override
  Future<Map<String, dynamic>> pick(
          {required bool photos, required String language}) =>
      onPick!();
  @override
  Future<void> cancelImport() async {
    await onCancel?.call();
  }

  @override
  Future<void> invalidateSession(String epoch) async {
    invalidated.add(epoch);
  }

  @override
  Future<void> prepareSession(String account, String epoch) async {
    prepared.add(epoch);
  }

  @override
  Future<Map<String, dynamic>> snapshot() async => state;
  @override
  Future<void> enqueue(Map<String, Object?> plan) async {
    enqueued.add(plan);
    state['tasks'] = [
      ...(state['tasks'] as List),
      <String, dynamic>{
        'taskId': plan['taskId'],
        'accountId': plan['accountId'],
        'epoch': plan['epoch'],
        'state': 'queued',
        'items': [
          for (final raw in plan['items'] as List)
            {
              'id': (raw as Map)['id'],
              'state': 'queued',
              'length': raw['length'],
              'sentBytes': 0
            }
        ]
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> convert(String relativePath) =>
      onConvert!(relativePath);
  @override
  Future<int> availableBytes() async => 10000000000;
  @override
  Future<void> cancel(String taskId) async {
    final task = (state['tasks'] as List)
        .cast<Map>()
        .singleWhere((t) => t['taskId'] == taskId);
    task['state'] = 'stopped';
    for (final item in (task['items'] as List).cast<Map>()) {
      if (item['state'] != 'confirmed') item['state'] = 'stopped';
    }
  }

  @override
  Future<void> acknowledge(String receiptId, String outcome) async {
    final receipt = (state['receipts'] as List)
        .cast<Map>()
        .singleWhere((r) => r['receiptId'] == receiptId);
    receipt['acknowledged'] = true;
    receipt['outcome'] = outcome;
    final task = (state['tasks'] as List)
        .cast<Map>()
        .singleWhere((t) => t['taskId'] == receipt['taskId']);
    task['state'] = outcome == 'confirmed' ? 'completed' : 'stopped';
    for (final item in (task['items'] as List).cast<Map>()) {
      if (item['state'] != 'confirmed') {
        item['state'] = outcome == 'confirmed' ? 'confirmed' : 'stopped';
      }
    }
  }
}

class UploadTestRepository extends UploadRepository {
  UploadTestRepository(UploadTestCookies cookies)
      : super(UploadHttpClient(cookies));
  Future<UploadEditorSnapshot> Function()? saveResult;
  Future<UploadEditorSnapshot> Function()? editorResult;
  void Function()? saveStarted;
  int saveCalls = 0;
  @override
  Future<UploadEditorSnapshot> save(
      String account, Uri uri, Map<String, List<String>> edits,
      {Map<String, List<String>>? baseline}) async {
    await beforeWrite?.call(uri);
    saveCalls++;
    saveStarted?.call();
    return saveResult!();
  }

  @override
  Future<UploadEditorSnapshot> editor(String account, Uri uri) =>
      editorResult!();
}

class UploadCleanupFailureStore extends UploadStore {
  bool failCleanup = false;
  UploadCleanupFailureStore(super.database, super.root);
  @override
  Future<void> cleanupOrphanImports() {
    if (failCleanup) {
      return Future.error(
          const FileSystemException('Injected cleanup failure'));
    }
    return super.cleanupOrphanImports();
  }
}

class UploadTestAdvanced extends UploadAdvancedActions {
  UploadTestAdvanced(super.repository);
  Future<UploadActionResult> Function()? result;
  int calls = 0;
  @override
  Future<UploadActionResult> perform(
      String accountId, PreparedUploadAction prepared,
      {required bool confirmed}) async {
    if (!confirmed) throw ArgumentError('Confirm');
    await repository.beforeWrite?.call(prepared.editorUri);
    calls++;
    return result!();
  }
}

UploadEditorSnapshot serverEditor(String title) {
  final value = const UploadProtocol().editor(
      File('test/fixtures/uploads/uploaded.html').readAsStringSync(),
      Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=12345'));
  return UploadEditorSnapshot(
      uri: value.uri,
      form: UploadForm(action: value.form.action, multipart: true, fields: {
        'gname_en':
            UploadField(name: 'gname_en', type: 'text', values: [title]),
      }),
      api: value.api,
      buttons: {
        ...value.buttons,
        'uploadbutton': const UploadButton('Upload', true, null)
      },
      images: value.images,
      metadata: value.metadata,
      links: value.links,
      reorderForm: value.reorderForm);
}

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  late Directory root;
  late UploadStore storage;
  late UploadTestCookies cookies;
  late UploadTestPlatform platform;
  late UploadTestRepository repository;
  late UploadTestAdvanced advanced;
  late UploadServices service;
  var factoryCalls = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('upload-services-');
    storage = UploadStore(UploadDatabase(NativeDatabase.memory()), root);
    cookies = UploadTestCookies();
    platform = UploadTestPlatform();
    repository = UploadTestRepository(cookies);
    advanced = UploadTestAdvanced(repository);
    factoryCalls = 0;
    service = UploadServices(cookies,
        repository: repository,
        advanced: advanced,
        platform: platform, storeFactory: () async {
      factoryCalls++;
      return storage;
    });
  });
  tearDown(() async {
    if (factoryCalls > 0) {
      await service.dispose();
    } else {
      repository.client.dispose();
      await storage.close();
    }
    await root.delete(recursive: true);
  });
  Future<UploadDraft> seed() =>
      storage.save(UploadDraft(id: 'draft', accountId: '101', fields: const {
        'gname_en': ['submitted']
      }, serverFields: const {
        'gname_en': ['old']
      }, assets: const []));
  Future<Map<String, dynamic>> selection({bool valid = true}) async {
    const path =
        'imports/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.png';
    final copy = File('${root.path}/$path');
    await copy.parent.create(recursive: true);
    if (valid) {
      await File('test/uploads/fixtures/assets/sample.png').copy(copy.path);
    } else {
      await copy.writeAsString('not an archive');
    }
    return {
      'cancelled': false,
      'files': [
        {
          'relativePath': path,
          'displayName': valid ? 'sample.png' : 'bad.zip',
          'size': await copy.length()
        }
      ],
      'errors': []
    };
  }

  test('cold logout opens durable upload store before invalidating native work',
      () async {
    final identity = await storage.createSession('101');
    expect(factoryCalls, 0);
    await service.invalidateSession();
    expect(factoryCalls, 1);
    expect(platform.invalidated, [identity.epoch]);
    expect(await storage.session(), isNull);
  });
  test(
      'cold orphan cleanup runs before picker, while referenced copies survive',
      () async {
    final draft = await seed();
    final stale = await selection();
    final path = (stale['files'] as List).single['relativePath'] as String;
    platform.onPick = () async {
      expect(factoryCalls, 1);
      expect(await File('${root.path}/$path').exists(), isFalse);
      return selection();
    };
    final saved = await service.importFiles(draft, photos: false);
    expect(saved.assets, hasLength(1));
    expect(
        await File('${root.path}/${saved.assets.single.relativePath}').exists(),
        isTrue);
  });
  test('account change after selection cleans uncommitted native copies',
      () async {
    final draft = await seed();
    platform.onPick = () async {
      final rows = await selection();
      cookies.account = '202';
      cookies.revision++;
      return rows;
    };
    await expectLater(service.importFiles(draft, photos: false),
        throwsA(isA<UploadFailure>()));
    expect(
        await Directory('${root.path}/imports')
            .list(recursive: true)
            .where((e) => e is File)
            .toList(),
        isEmpty);
    expect((await storage.draft('101', 'draft'))!.assets, isEmpty);
  });
  test('rejected ZIP copies are reported and removed rather than orphaned',
      () async {
    final draft = await seed();
    platform.onPick = () => selection(valid: false);
    await expectLater(service.importFiles(draft, photos: false),
        throwsA(isA<UploadImportException>()));
    expect(
        await Directory('${root.path}/imports')
            .list(recursive: true)
            .where((e) => e is File)
            .toList(),
        isEmpty);
  });
  test('cancellation waits for preparation cleanup and completes its waiter',
      () async {
    final draft = await seed();
    final opened = Completer<void>();
    final selected = Completer<Map<String, dynamic>>();
    platform.onPick = () {
      opened.complete();
      return selected.future;
    };
    platform.onCancel = () async {
      if (!selected.isCompleted) selected.complete(await selection());
    };
    final operation = service.importFiles(draft, photos: false);
    final expected = expectLater(operation, throwsA(isA<UploadCancelled>()));
    await opened.future;
    await service.cancelPreparation().timeout(const Duration(seconds: 3));
    await expected;
    expect(
        await Directory('${root.path}/imports')
            .list(recursive: true)
            .where((e) => e is File)
            .toList(),
        isEmpty);
  });
  test('cleanup failure cannot strand a caller awaiting cancellation',
      () async {
    await storage.close();
    final failing = UploadCleanupFailureStore(
        UploadDatabase(NativeDatabase.memory()), root);
    storage = failing;
    final draft = await seed();
    final opened = Completer<void>();
    final selected = Completer<Map<String, dynamic>>();
    platform.onPick = () {
      opened.complete();
      return selected.future;
    };
    platform.onCancel = () async {
      if (selected.isCompleted) return;
      failing.failCleanup = true;
      selected.complete(await selection());
    };
    final importing = service.importFiles(draft, photos: false);
    final failure = expectLater(importing, throwsA(isA<FileSystemException>()));
    await opened.future;
    await service.cancelPreparation().timeout(const Duration(seconds: 3));
    await failure;
    failing.failCleanup = false;
  });

  test(
      'a delayed remote save keeps later local edits and the returned server URI',
      () async {
    final draft = await seed();
    final reply = Completer<UploadEditorSnapshot>();
    final started = Completer<void>();
    repository.saveStarted = started.complete;
    repository.saveResult = () => reply.future;
    final saving = service.saveRemote(draft);
    await started.future;
    final later = await service.saveLocal(draft.copyWith(fields: const {
      'gname_en': ['typed later']
    }));
    reply.complete(serverEditor('submitted'));
    final result = await saving;
    expect(result.draft.title, later.title);
    expect(result.draft.serverFields['gname_en'], ['submitted']);
    expect(result.draft.serverUri!.queryParameters['ulgid'], '12345');
    expect(result.draft.dirty, isTrue);
    expect((await storage.draft('101', 'draft'))!.title, 'typed later');
  });

  test(
      'unknown create is durable and cannot be repeated until explicitly reconciled',
      () async {
    final draft = await seed();
    repository.saveResult = () =>
        Future.error(const UploadFailure(UploadFailureKind.resultUncertain));
    await expectLater(service.saveRemote(draft), throwsA(isA<UploadFailure>()));
    expect((await service.pendingWrite(draft))!.kind, 'create');
    await expectLater(service.saveRemote(draft), throwsA(isA<UploadFailure>()));
    expect(repository.saveCalls, 1);
    repository.editorResult = () async => serverEditor('submitted');
    final associated = await service.associatePendingGallery(
        draft, Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=12345'),
        expectedOperationId: (await service.pendingWrite(draft))!.operationId);
    expect(associated.draft.serverUri!.queryParameters['ulgid'], '12345');
    expect(await service.pendingWrite(draft), isNull);
  });

  test(
      'explicit retry verification is required and preflight failure does not create pending write',
      () async {
    final draft = await seed();
    final operation = await storage.beginWrite(draft);
    await expectLater(
        service.retryAfterVerifiedNoChange(draft, confirmed: false),
        throwsArgumentError);
    expect(await service.pendingWrite(draft), isNotNull);
    await service.retryAfterVerifiedNoChange(draft,
        confirmed: true, expectedOperationId: operation);
    expect(await service.pendingWrite(draft), isNull);
  });

  Future<UploadDraft> receivedDraft({bool known = true}) async {
    final selectionResult = await selection();
    final path = ((selectionResult['files'] as List).single
        as Map)['relativePath'] as String;
    final asset = (await const UploadAssetPreparer()
            .inspect(root: root, relativePath: path, displayName: 'sample.png'))
        .withUploadName('0001.png');
    final draft = await storage.save(UploadDraft(
        id: 'received',
        accountId: '101',
        fields: const {
          'gname_en': ['submitted']
        },
        serverFields: const {
          'gname_en': ['submitted']
        },
        serverUri:
            Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=12345'),
        assets: [asset],
        dirty: false));
    await storage.registerAttempt(UploadAttempt(
        accountId: '101',
        taskId: 'attempt-old',
        draftId: draft.id,
        groupId: 'group-old',
        serverUri: draft.serverUri!,
        assets: [
          UploadAttemptAsset(
              'item-old', asset.relativePath, asset.sha256, '0001.png')
        ]));
    final response =
        File('${root.path}/native/android/responses/receipt.response');
    await response.parent.create(recursive: true);
    await File('test/fixtures/uploads/uploaded.html').copy(response.path);
    platform.state = {
      'tasks': [
        {
          'taskId': 'attempt-old',
          'accountId': '101',
          'epoch': 'old',
          'state': known ? 'completed' : 'uncertain',
          'items': [
            {'id': 'item-old', 'state': known ? 'confirmed' : 'uncertain'}
          ]
        }
      ],
      'receipts': [
        {
          'receiptId': 'receipt',
          'taskId': 'attempt-old',
          'itemId': 'item-old',
          'accountId': '101',
          'epoch': 'old',
          'state': known ? 'awaitingVerification' : 'uncertain',
          'status': 200,
          'sentBytes': 100,
          'length': 100,
          'finalUrl': draft.serverUri.toString(),
          'responsePath': 'native/android/responses/receipt.response',
          'acknowledged': known,
          'outcome': known ? 'confirmed' : null,
          'verification': {
            'galleryId': '12345',
            'expectedNames': ['0001.png'],
            'priorFileIndexes': []
          }
        }
      ]
    };
    return draft;
  }

  test(
      'confirmed receipt projects file identity durably and never uploads the same assets twice',
      () async {
    final draft = await receivedDraft();
    final snapshot = await service.transferSnapshot();
    expect((snapshot['tasks'] as List).single['draftId'], draft.id);
    expect(await service.pendingAssets(draft), isEmpty);
    final status =
        (await service.assetProgress(draft, snapshot: snapshot)).single;
    expect(status.state, UploadAssetState.confirmed);
    expect(status.fileIndex, 279367042);
    await File('${root.path}/native/android/responses/receipt.response')
        .delete();
    // Already projected proof survives response cleanup and app polling.
    expect(
        (await service.transferSnapshot())['tasks']
            .single['reconciliationRequired'],
        isNull);
    repository.saveResult = () async => serverEditor('submitted');
    await expectLater(
        service.startUpload(draft),
        throwsA(isA<UploadFileException>()
            .having((e) => e.code, 'code', 'no_pending_images')));
    expect(platform.enqueued, isEmpty);
  });

  test(
      'unknown upload blocks gallery writes until explicit live review confirms its new file IDs',
      () async {
    final draft = await receivedDraft(known: false);
    await expectLater(repository.beforeWrite!(draft.serverUri!),
        throwsA(isA<UploadFailure>()));
    repository.editorResult = () async => const UploadProtocol().editor(
        await File('test/fixtures/uploads/uploaded.html').readAsString(),
        draft.serverUri!);
    final review = await service.reviewReceipt('receipt');
    expect(review.matchedFiles, {'0001.png': 279367042});
    expect(review.ambiguousNames, isEmpty);
    await expectLater(service.acceptReceiptReview(review, confirmed: false),
        throwsArgumentError);
    await service.acceptReceiptReview(review, confirmed: true);
    expect(await service.pendingAssets(draft), isEmpty);
    await repository.beforeWrite!(draft.serverUri!);
  });

  test('append creates a new attempt containing only not-yet-confirmed assets',
      () async {
    final draft = await receivedDraft();
    await service.transferSnapshot();
    const relative =
        'imports/cccccccc-cccc-cccc-cccc-cccccccccccc/dddddddd-dddd-dddd-dddd-dddddddddddd.png';
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await File('test/uploads/fixtures/assets/sample.png').copy(file.path);
    final added = await const UploadAssetPreparer()
        .inspect(root: root, relativePath: relative, displayName: 'new.png');
    final updated =
        await storage.appendAssets(draft.accountId, draft.id, [added]);
    repository.saveResult = () async => serverEditor('submitted');
    repository.editorResult = () async => serverEditor('submitted');
    await service.startUpload(updated);
    final plan = platform.enqueued.single;
    expect(plan['taskId'], isNot('attempt-old'));
    expect(plan['taskId'], isNot(draft.id));
    final verification =
        (((plan['items'] as List).single as Map)['verification']) as Map;
    expect(verification['expectedNames'], ['0009_new.png']);
    expect(await storage.attempts('101', draftId: draft.id), hasLength(2));
    final latest = (await storage.draft('101', draft.id))!;
    final snapshot = await service.transferSnapshot();
    final statuses = await service.assetProgress(latest, snapshot: snapshot);
    expect(statuses.map((s) => s.state),
        [UploadAssetState.confirmed, UploadAssetState.queued]);
    await expectLater(repository.beforeWrite!(draft.serverUri!),
        throwsA(isA<UploadFailure>()));
  });

  test(
      'raw unchecked terms and rotating PHP progress keys preserve explicit consent for upload',
      () async {
    final selected = await selection();
    final path =
        ((selected['files'] as List).single as Map)['relativePath'] as String;
    final asset = await const UploadAssetPreparer()
        .inspect(root: root, relativePath: path, displayName: 'sample.png');
    UploadEditorSnapshot raw(String progress) {
      final html = File('test/fixtures/uploads/unchecked.html')
          .readAsStringSync()
          .replaceAll('fixture-progress', progress);
      return const UploadProtocol().editor(html,
          Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=12345'));
    }

    final before = raw('progress-before');
    expect(before.form.fields['tos']!.values, isEmpty);
    final metadata = {
      for (final field in before.form.fields.values)
        if (uploadEditableFields.contains(field.name) && field.name != 'tos')
          field.name: field.values
    };
    final draft = await storage.save(UploadDraft(
        id: 'consent',
        accountId: '101',
        serverUri: before.uri,
        fields: {
          ...metadata,
          'tos': ['on']
        },
        serverFields: metadata,
        assets: [asset]));
    repository.saveResult = () async => raw('progress-after-save');
    repository.editorResult = () async => raw('progress-after-final-read');
    await service.startUpload(draft);
    final item = (platform.enqueued.single['items'] as List).single as Map;
    final body = await File('${root.path}/${item['bodyPath']}').readAsBytes();
    final text = String.fromCharCodes(body);
    expect(text, contains('name="tos"\r\n\r\non\r\n'));
    expect(text, contains('progress-after-save'));
    final saved = (await storage.draft('101', draft.id))!;
    expect(saved.fields['tos'], ['on']);
    expect(saved.serverFields.containsKey('tos'), isFalse);
    expect(saved.dirty, isFalse);
  });

  test(
      'partial explicit review retains accepted files and stops the old batch for fresh preparation',
      () async {
    final draft = await receivedDraft(known: false);
    final first = draft.assets.single;
    final extra = first.withUploadName('0009.png');
    final updated = await storage.save(draft.copyWith(assets: [first, extra]));
    await storage.registerAttempt(UploadAttempt(
        accountId: '101',
        taskId: 'partial',
        draftId: draft.id,
        groupId: 'partial-group',
        serverUri: draft.serverUri!,
        assets: [
          UploadAttemptAsset(
              'partial-item', first.relativePath, first.sha256, '0001.png'),
          UploadAttemptAsset(
              'partial-item', extra.relativePath, extra.sha256, '0009.png')
        ]));
    final receipt = ((platform.state['receipts'] as List).single as Map)
      ..['taskId'] = 'partial'
      ..['itemId'] = 'partial-item';
    (receipt['verification'] as Map)['expectedNames'] = [
      '0001.png',
      '0009.png'
    ];
    platform.state['tasks'] = [
      {
        'taskId': 'partial',
        'accountId': '101',
        'state': 'uncertain',
        'items': [
          {'id': 'partial-item', 'state': 'uncertain'}
        ]
      }
    ];
    repository.editorResult = () async => const UploadProtocol().editor(
        await File('test/fixtures/uploads/uploaded.html').readAsString(),
        draft.serverUri!);
    final review = await service.reviewReceipt('receipt');
    expect(review.matchedFiles.keys, ['0001.png']);
    expect(review.missingNames, ['0009.png']);
    await expectLater(
        service.acceptReceiptReview(review, confirmed: true), throwsStateError);
    await service.acceptReceiptReview(review,
        confirmed: true, stopRemaining: true);
    expect((await service.pendingAssets(updated)).map((a) => a.uploadName),
        ['0009.png']);
    expect(
        ((await service.transferSnapshot())['tasks'] as List)
            .single['blocksEditing'],
        isFalse);
  });

  test(
      'web handoff discards queued bodies instead of allowing stale prepared requests to resume',
      () async {
    final draft = await receivedDraft();
    await service.transferSnapshot();
    (platform.state['tasks'] as List).add({
      'taskId': 'queued',
      'accountId': '101',
      'state': 'queued',
      'items': [
        {'id': 'q', 'state': 'queued'}
      ]
    });
    await storage.registerAttempt(UploadAttempt(
        accountId: '101',
        taskId: 'queued',
        draftId: draft.id,
        groupId: 'queued-group',
        serverUri: draft.serverUri!,
        assets: [
          UploadAttemptAsset('q', draft.assets.single.relativePath,
              draft.assets.single.sha256, '0009.png')
        ]));
    await storage.registerPreparation('101', 'queued', 'queued-group');
    await Directory('${root.path}/prepared/queued-group')
        .create(recursive: true);
    await File('${root.path}/prepared/queued-group/body')
        .writeAsString('form token');
    await service.prepareWebHandoff(draft: draft);
    expect((platform.state['tasks'] as List).last['state'], 'stopped');
    expect(await Directory('${root.path}/prepared/queued-group').exists(),
        isFalse);
  });

  test(
      'conversion preserves the original display name and only replaces the selected local copy',
      () async {
    const oldPath =
        'imports/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.heic';
    final oldFile = File('${root.path}/$oldPath');
    await oldFile.parent.create(recursive: true);
    await oldFile.writeAsString('opaque HEIC fixture');
    final asset = await const UploadAssetPreparer()
        .inspect(root: root, relativePath: oldPath, displayName: '中文原图.heic');
    final draft = await storage.save(UploadDraft(
        id: 'conversion', accountId: '101', fields: const {}, assets: [asset]));
    platform.onConvert = (path) async {
      expect(path, oldPath);
      const output =
          'imports/cccccccc-cccc-cccc-cccc-cccccccccccc/converted.png';
      final file = File('${root.path}/$output');
      await file.parent.create(recursive: true);
      await File('test/uploads/fixtures/assets/sample.png').copy(file.path);
      return {
        'relativePath': output,
        'displayName': 'converted.png',
        'size': await file.length(),
        'mimeType': 'image/png'
      };
    };
    final converted = await service.convertAsset(draft, asset);
    expect(converted.assets.single.displayName, '中文原图.png');
    expect(converted.assets.single.format, UploadImageFormat.png);
    expect(await oldFile.exists(), isFalse);
    expect(
        await File('${root.path}/${converted.assets.single.relativePath}')
            .exists(),
        isTrue);
    expect(platform.enqueued, isEmpty);
  });

  test(
      'manual association resolves prior-ID ambiguity without claiming the old request succeeded',
      () async {
    final draft = await receivedDraft(known: false);
    final receipt = (platform.state['receipts'] as List).single as Map;
    (receipt['verification'] as Map)['priorFileIndexes'] = [279367042];
    repository.editorResult = () async => const UploadProtocol().editor(
        await File('test/fixtures/uploads/uploaded.html').readAsString(),
        draft.serverUri!);
    final review = await service.reviewReceipt('receipt');
    expect(review.ambiguousNames, ['0001.png']);
    await expectLater(
        service.acceptReceiptReview(review, confirmed: true), throwsStateError);
    await service.acceptManualReceiptMapping(review,
        selectedEntries: {
          '0001.png':
              review.remoteFiles.firstWhere((image) => image.name == '0001.png')
        },
        confirmed: true);
    expect(receipt['outcome'], 'stop');
    expect(await service.pendingAssets(draft), isEmpty);
    expect(
        (await service.assetProgress(draft)).single.manuallyReviewed, isTrue);
  });

  test(
      'explicit not-received decision resets conflicting names and stale UI cannot restore them',
      () async {
    final draft = await receivedDraft(known: false);
    final receipt = (platform.state['receipts'] as List).single as Map;
    (receipt['verification'] as Map)['priorFileIndexes'] = [279367042];
    repository.editorResult = () async => const UploadProtocol().editor(
        await File('test/fixtures/uploads/uploaded.html').readAsString(),
        draft.serverUri!);
    final review = await service.reviewReceipt('receipt');
    await service.acceptManualReceiptMapping(review,
        selectedEntries: {}, notReceivedNames: {'0001.png'}, confirmed: true);
    final reset = (await storage.draft('101', draft.id))!;
    expect(reset.assets.single.uploadName, isNull);
    final savedFromOldUi = await service.saveLocal(draft);
    expect(savedFromOldUi.assets.single.uploadName, isNull);
    expect((await service.pendingAssets(savedFromOldUi)), hasLength(1));
  });

  Future<UploadDraft> duplicateReceipt() async {
    final original = await receivedDraft(known: false);
    final draft = await storage.save(original.copyWith(assets: [
      original.assets.single,
      original.assets.single.withUploadName('0002.png'),
    ]));
    await storage.registerAttempt(UploadAttempt(
        accountId: '101',
        taskId: 'attempt-copies',
        draftId: draft.id,
        groupId: 'copies',
        serverUri: draft.serverUri!,
        assets: [
          for (final asset in draft.assets)
            UploadAttemptAsset('item-copies', asset.relativePath, asset.sha256,
                asset.uploadName!),
        ]));
    final task = (platform.state['tasks'] as List).single as Map;
    task['taskId'] = 'attempt-copies';
    (task['items'] as List).single['id'] = 'item-copies';
    final receipt = (platform.state['receipts'] as List).single as Map;
    receipt['taskId'] = 'attempt-copies';
    receipt['itemId'] = 'item-copies';
    (receipt['verification'] as Map)['expectedNames'] = [
      '0001.png',
      '0002.png'
    ];
    (receipt['verification'] as Map)['priorFileIndexes'] = [279367042];
    return draft;
  }

  UploadEditorSnapshot duplicateEditor({int count = 2, bool renamed = false}) {
    final base = serverEditor('submitted');
    return UploadEditorSnapshot(
        uri: base.uri,
        form: base.form,
        api: base.api,
        buttons: base.buttons,
        metadata: base.metadata,
        links: base.links,
        images: [
          for (var i = 0; i < count; i++)
            RemoteUploadImage(
                page: i + 1,
                positionField: 'p${i + 1}',
                position: i + 1,
                name: renamed && i == 1 ? 'changed.png' : '000${i + 1}.png',
                fileIndex: 279367042)
        ]);
  }

  test(
      'two identical local copies can confirm two distinct website entries with the same content ID',
      () async {
    final draft = await duplicateReceipt();
    repository.editorResult = () async => duplicateEditor();
    final review = await service.reviewReceipt('receipt');
    expect(review.ambiguousNames, ['0001.png', '0002.png']);
    await service.acceptManualReceiptMapping(review,
        selectedEntries: {
          '0001.png': review.remoteFiles[0],
          '0002.png': review.remoteFiles[1],
        },
        confirmed: true);
    final confirmed = await storage.confirmedAssets(draft);
    expect(confirmed, hasLength(2));
    expect(confirmed.map((a) => a.fileIndex).toSet(), {279367042});
    expect(confirmed.map((a) => a.occurrence!.page).toSet(), {1, 2});
    expect(await service.pendingAssets(draft), isEmpty);
    expect((platform.state['receipts'] as List).single['outcome'], 'stop');
  });

  test('one website entry cannot confirm two identical local copies', () async {
    final draft = await duplicateReceipt();
    repository.editorResult = () async => duplicateEditor(count: 1);
    final review = await service.reviewReceipt('receipt');
    await expectLater(
        service.acceptManualReceiptMapping(review,
            selectedEntries: {
              '0001.png': review.remoteFiles.single,
              '0002.png': review.remoteFiles.single,
            },
            confirmed: true),
        throwsStateError);
    expect(await storage.confirmedAssets(draft), isEmpty);
    expect((platform.state['receipts'] as List).single['acknowledged'], false);
  });

  test(
      'manual occurrence confirmation rejects a changed full remote list even when selected IDs remain',
      () async {
    final draft = await duplicateReceipt();
    repository.editorResult = () async => duplicateEditor();
    final review = await service.reviewReceipt('receipt');
    repository.editorResult = () async => duplicateEditor(renamed: true);
    await expectLater(
        service.acceptManualReceiptMapping(review,
            selectedEntries: {
              '0001.png': review.remoteFiles[0],
              '0002.png': review.remoteFiles[1],
            },
            confirmed: true),
        throwsStateError);
    expect(await storage.confirmedAssets(draft), isEmpty);
    expect((platform.state['receipts'] as List).single['acknowledged'], false);
  });

  test('a fabricated second occurrence cannot replace a missing duplicate',
      () async {
    final draft = await duplicateReceipt();
    repository.editorResult = () async => duplicateEditor(count: 1);
    final review = await service.reviewReceipt('receipt');
    await expectLater(
        service.acceptManualReceiptMapping(review,
            selectedEntries: {
              '0001.png': review.remoteFiles.single,
              '0002.png': duplicateEditor().images[1],
            },
            confirmed: true),
        throwsStateError);
    expect(await storage.confirmedAssets(draft), isEmpty);
  });

  test(
      'a later batch cannot reuse the existing entry of an already confirmed local copy',
      () async {
    final draft = await duplicateReceipt();
    final original = (await storage.attempts('101'))
        .singleWhere((a) => a.taskId == 'attempt-old');
    await storage.confirmReceipt(
        original, 'item-old', 'earlier', {'0001.png': 279367042});
    final extra = draft.assets[1];
    await storage.registerAttempt(UploadAttempt(
        accountId: '101',
        taskId: 'append',
        draftId: draft.id,
        groupId: 'append',
        serverUri: draft.serverUri!,
        assets: [
          UploadAttemptAsset(
              'append-item', extra.relativePath, extra.sha256, '0002.png')
        ]));
    final task = (platform.state['tasks'] as List).single as Map;
    task['taskId'] = 'append';
    (task['items'] as List).single['id'] = 'append-item';
    final receipt = (platform.state['receipts'] as List).single as Map;
    receipt['taskId'] = 'append';
    receipt['itemId'] = 'append-item';
    (receipt['verification'] as Map)['expectedNames'] = ['0002.png'];
    repository.editorResult = () async => duplicateEditor(count: 1);
    final review = await service.reviewReceipt('receipt');
    await expectLater(
        service.acceptManualReceiptMapping(review,
            selectedEntries: {'0002.png': review.remoteFiles.single},
            confirmed: true),
        throwsStateError);
    expect(
        (await storage.confirmedAssets(draft)).single.uploadName, '0001.png');
    expect((await service.pendingAssets(draft)).single.uploadName, '0002.png');
    expect(receipt['acknowledged'], false);
  });

  test('old website close cannot release a newer account website lease',
      () async {
    final draft = await seed();
    final old = await service.prepareWebHandoff(draft: draft);
    await service.invalidateSession();
    cookies.account = '202';
    cookies.revision++;
    final current = await service.prepareWebHandoff();
    await expectLater(
        service.finishWebHandoff(draft, generation: old), throwsStateError);
    await expectLater(
        repository
            .beforeWrite!(Uri.parse('https://upld.e-hentai.org/managefolders')),
        throwsA(isA<UploadFailure>()));
    await service.endWebHandoff(generation: current);
    await repository
        .beforeWrite!(Uri.parse('https://upld.e-hentai.org/managefolders'));
  });

  test('deleted or disowned gallery keeps its copies in a local read-only view',
      () async {
    final draft = await receivedDraft();
    final terminal = await storage.markRemoteState('101', draft.id, 'disowned');
    repository.editorResult =
        () => throw StateError('Must not read relinquished editor');
    final session = await service.openDraft('101', draft.id);
    expect(session.localOnly, isTrue);
    expect(session.editor.buttons, isEmpty);
    expect(session.editor.canUpload, isFalse);
    expect(session.draft.assets, hasLength(1));
    expect(
        await File('${root.path}/${draft.assets.single.relativePath}').exists(),
        isTrue);
    await expectLater(
        service.saveRemote(terminal), throwsA(isA<UploadFailure>()));
    await expectLater(service.saveRemote(draft), throwsA(isA<UploadFailure>()));
    expect((await storage.draft('101', draft.id))!.remoteState, 'disowned');
    expect(repository.saveCalls, 0);
  });

  PreparedUploadAction prepared(UploadDraft draft, UploadGalleryAction kind) =>
      PreparedUploadAction(
          accountId: draft.accountId,
          action: kind,
          editorUri: draft.serverUri!,
          actionUri: draft.serverUri!.replace(queryParameters: {
            'ulgid': '12345',
            'act': kind == UploadGalleryAction.clone ? 'unlock' : kind.name
          }),
          editor: serverEditor('submitted'),
          fingerprint: List.filled(64, 'a').join(),
          revision: cookies.revision);

  test('advanced unknown outcome remains durable and cannot be sent twice',
      () async {
    final draft = await receivedDraft();
    advanced.result = () =>
        Future.error(const UploadFailure(UploadFailureKind.resultUncertain));
    final review = prepared(draft, UploadGalleryAction.disown);
    await expectLater(service.performAdvanced(draft, review, confirmed: true),
        throwsA(isA<UploadFailure>()));
    final pending = (await service.pendingWrite(draft))!;
    expect(pending.kind, 'disown');
    expect(pending.context['galleryId'], '12345');
    expect(pending.context.containsKey('apikey'), isFalse);
    await expectLater(service.performAdvanced(draft, review, confirmed: true),
        throwsA(isA<UploadFailure>()));
    await expectLater(
        service.retryAfterVerifiedNoChange(draft, confirmed: true),
        throwsStateError);
    expect(advanced.calls, 1);
  });

  test(
      'advanced delete retains local files and returns the exact local draft identity',
      () async {
    final draft = await receivedDraft();
    advanced.result =
        () async => const UploadActionResult(UploadGalleryAction.delete);
    final result = await service.performAdvanced(
        draft, prepared(draft, UploadGalleryAction.delete),
        confirmed: true);
    expect(result.localDraftId, draft.id);
    expect((await service.openDraft('101', draft.id)).localOnly, isTrue);
    expect(
        await File('${root.path}/${draft.assets.single.relativePath}').exists(),
        isTrue);
    expect(await service.pendingWrite(draft), isNull);
  });

  test(
      'clone creates a child even for the same management URI and carries only pending assets',
      () async {
    final draft = await receivedDraft();
    await service.transferSnapshot();
    final extra = draft.assets.single.withUploadName('0009.png');
    final parent = await storage.appendAssets('101', draft.id, [extra]);
    advanced.result = () async => UploadActionResult(UploadGalleryAction.clone,
        editor: serverEditor('Child'));
    final result = await service.performAdvanced(
        parent, prepared(parent, UploadGalleryAction.clone),
        confirmed: true);
    expect(result.localDraftId, isNot(parent.id));
    final child = (await storage.draft('101', result.localDraftId!))!;
    expect(child.parentDraftId, parent.id);
    expect(child.parentGalleryUri, parent.serverUri);
    expect(child.assets, hasLength(1));
    expect(child.assets.single.uploadName, isNull);
    expect((await storage.draft('101', parent.id))!.assets, hasLength(2));
  });

  test(
      'publication is blocked by dirty fields or unresolved uploads even with caller confirmation',
      () async {
    final draft = await receivedDraft();
    await storage.save(draft.copyWith(fields: const {
      'gname_en': ['unsaved']
    }, dirty: true));
    advanced.result = () async => UploadActionResult(
        UploadGalleryAction.publish,
        editor: serverEditor('submitted'));
    await expectLater(
        service.performAdvanced(
            draft, prepared(draft, UploadGalleryAction.publish),
            confirmed: true),
        throwsStateError);
    expect(advanced.calls, 0);
    final clean = await storage.save(draft.copyWith(dirty: false));
    (platform.state['receipts'] as List).single['acknowledged'] = false;
    (platform.state['receipts'] as List).single['outcome'] = null;
    (platform.state['tasks'] as List).single['state'] = 'uncertain';
    await expectLater(
        service.performAdvanced(
            clean, prepared(clean, UploadGalleryAction.publish),
            confirmed: true),
        throwsStateError);
    expect(advanced.calls, 0);
  });

  test(
      'website lifetime blocks writes and failure during close still releases the handoff',
      () async {
    final draft = await seed();
    await service.prepareWebHandoff(draft: draft);
    await expectLater(
        service.startUpload(draft), throwsA(isA<UploadFailure>()));
    await expectLater(
        repository
            .beforeWrite!(Uri.parse('https://upld.e-hentai.org/managefolders')),
        throwsA(isA<UploadFailure>()));
    repository.editorResult =
        () => Future.error(const UploadFailure(UploadFailureKind.network));
    // A new local draft asks for newEditor instead of editor. Fail directly by
    // using a saved URI, and ensure its finally releases the same global lease.
    final saved = await storage.save(draft.copyWith(
        serverUri:
            Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=12345')));
    await expectLater(
        service.finishWebHandoff(saved), throwsA(isA<UploadFailure>()));
    await service.prepareWebHandoff(draft: saved);
    await service.endWebHandoff();
    await repository
        .beforeWrite!(Uri.parse('https://upld.e-hentai.org/managefolders'));
  });
}
