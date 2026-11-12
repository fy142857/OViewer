import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/files/upload_asset.dart';

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  late Directory root;
  late UploadStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oviewer-upload-store-');
    store = UploadStore(UploadDatabase(NativeDatabase.memory()), root);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  UploadDraft draft(String account,
          {String id = 'draft-1',
          String title = 'Original',
          List<PreparedUploadAsset> assets = const []}) =>
      UploadDraft(
          id: id,
          accountId: account,
          fields: {
            'gname_en': [title]
          },
          assets: assets);

  test(
      'account-scoped IDs cannot read overwrite or remove another account draft',
      () async {
    await store.save(draft('a'));
    await store.save(draft('b', title: 'B'));
    await store.save(draft('a', title: 'Changed A'));
    expect((await store.drafts('a')).single.title, 'Changed A');
    expect((await store.drafts('b')).single.title, 'B');
    expect(await store.draft('c', 'draft-1'), isNull);
    await store.removeLocal('a', 'draft-1');
    expect(await store.drafts('a'), isEmpty);
    expect((await store.drafts('b')).single.title, 'B');
  });

  test('session epoch is durable and never reused when identity is renewed',
      () async {
    final first = await store.createSession('a');
    expect((await store.session())!.epoch, first.epoch);
    final next = await store.createSession('a');
    expect(next.epoch, isNot(first.epoch));
    await store.clearSession();
    expect(await store.session(), isNull);
  });

  test('local draft cannot persist API credentials or arbitrary file paths',
      () {
    expect(
        () => UploadDraft(id: 'd', accountId: 'a', fields: {
              'apikey': ['secret']
            }, assets: []),
        throwsArgumentError);
    expect(
        () => UploadDraft(
            id: '../escape', accountId: 'a', fields: {}, assets: []),
        throwsArgumentError);
    final fields = <String, List<String>>{
      'gname_en': ['before']
    };
    final saved =
        UploadDraft(id: 'safe', accountId: 'a', fields: fields, assets: []);
    fields['gname_en']![0] = 'after';
    expect(saved.title, 'before');
  });

  test(
      'draft and session survive database reopen without touching shared database',
      () async {
    await store.close();
    final file = File('${root.path}/uploads.sqlite');
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    final session = await store.createSession('a');
    await store.save(draft('a'));
    await store.close();
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    expect((await store.draft('a', 'draft-1'))!.title, 'Original');
    expect((await store.session())!.epoch, session.epoch);
    expect(File('${root.path}/oviewer.db').existsSync(), isFalse);
  });

  test('local removal only deletes unreferenced imported copies', () async {
    final directory =
        await Directory('${root.path}/imports/pick').create(recursive: true);
    final copy =
        await File('${directory.path}/image.jpg').writeAsBytes([1, 2, 3]);
    const asset = PreparedUploadAsset(
        relativePath: 'imports/pick/image.jpg',
        displayName: 'source.jpg',
        size: 3,
        sha256: 'test',
        crc32: 0,
        format: UploadImageFormat.jpeg,
        width: 100,
        height: 200);
    await store.save(draft('a', assets: [asset]));
    await store.save(draft('a', id: 'draft-2', assets: [asset]));
    await store.removeLocal('a', 'draft-1');
    expect(await copy.exists(), isTrue);
    await store.removeLocal('a', 'draft-2');
    expect(await copy.exists(), isFalse);
  });

  test('unrecognized or corrupt records are surfaced, never silently erased',
      () async {
    await store.save(draft('a'));
    await store.database.customStatement('UPDATE upload_drafts SET payload=?', [
      jsonEncode({'schema': 99})
    ]);
    await expectLater(store.drafts('a'), throwsFormatException);
    final rows =
        await store.database.customSelect('SELECT id FROM upload_drafts').get();
    expect(rows, hasLength(1));
  });

  test('preparation cleanup is durable, account scoped and preserves imports',
      () async {
    await store.registerPreparation('a', 'draft-a', 'group-a');
    await store.registerPreparation('b', 'draft-b', 'group-b');
    for (final name in [
      'prepared/group-a',
      'batches/group-a',
      'prepared/group-b',
      'imports/keep'
    ]) {
      final directory =
          await Directory('${root.path}/$name').create(recursive: true);
      await File('${directory.path}/sample').writeAsString('owned');
    }
    await store.cleanupPreparations('a');
    expect(await Directory('${root.path}/prepared/group-a').exists(), isFalse);
    expect(await Directory('${root.path}/batches/group-a').exists(), isFalse);
    expect(await File('${root.path}/prepared/group-b/sample').exists(), isTrue);
    expect(await File('${root.path}/imports/keep/sample').exists(), isTrue);
    await store.cleanupPreparations('a');
    expect(
        await store.database
            .customSelect('SELECT group_id FROM upload_artifacts')
            .get(),
        hasLength(1));
  });

  test(
      'cold orphan sweep touches only generated unreferenced copies across all accounts',
      () async {
    const group = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    final directory =
        await Directory('${root.path}/imports/$group').create(recursive: true);
    final keep =
        await File('${directory.path}/0000.image').writeAsString('referenced');
    final orphan =
        await File('${directory.path}/0001.image').writeAsString('orphan');
    final note = await File('${directory.path}/user-note.txt')
        .writeAsString('not generated');
    const asset = PreparedUploadAsset(
        relativePath: 'imports/$group/0000.image',
        displayName: 'x.png',
        size: 10,
        sha256: 'test',
        crc32: 0,
        format: UploadImageFormat.png,
        width: 100,
        height: 200);
    await store.save(draft('other-account', assets: [asset]));
    await store.initialize();
    expect(await keep.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
    expect(await note.exists(), isTrue);
  });

  test(
      'pending writes survive reopen and newer server metadata is not lost by stale UI saves',
      () async {
    await store.close();
    final file = File('${root.path}/uploads.sqlite');
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    final original = await store.save(draft('a'));
    final operation = await store.beginWrite(original);
    await store.close();
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    expect(
        (await store.pendingWrite('a', original.id))!.operationId, operation);
    await expectLater(store.beginWrite(original), throwsA(isA<Exception>()));
    await expectLater(
        store.resolveWrite('a', original.id, 'wrong-id'), throwsStateError);
    expect(await store.pendingWrite('a', original.id), isNotNull);
    await store.resolveWrite('a', original.id, operation,
        outcome: 'manual_no_effect');
    await store.close();
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    expect((await store.writeHistory('a', original.id)).single.outcome,
        'manual_no_effect');
    expect(await store.writeHistory('another-account', original.id), isEmpty);
    final remote =
        Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=12345');
    await store.mergeRemote(
        original,
        {
          'gname_en': ['Original']
        },
        remote);
    final edited = await store.saveLocalEdits(original.copyWith(fields: {
      'gname_en': ['next edit']
    }));
    expect(edited.serverUri, remote);
    expect(edited.serverFields['gname_en'], ['Original']);
  });

  test(
      'schema two upgrades preserve drafts while adding attempts and unresolved writes',
      () async {
    await store.close();
    final file = File('${root.path}/migration.sqlite');
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    await store.save(draft('a'));
    for (final table in [
      'upload_attempts',
      'upload_confirmed_assets',
      'upload_pending_writes',
      'upload_write_history'
    ]) {
      await store.database.customStatement('DROP TABLE $table');
    }
    await store.database.customStatement('PRAGMA user_version=2');
    await store.close();
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    final saved = (await store.draft('a', 'draft-1'))!;
    expect(saved.title, 'Original');
    expect(await store.attempts('a'), isEmpty);
    await store.beginWrite(saved);
    expect(await store.pendingWrite('a', saved.id), isNotNull);
  });

  test(
      'manual duplicate confirmation requires distinct occurrences and persists them across restart',
      () async {
    await store.close();
    final file = File('${root.path}/occurrences.sqlite');
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    final hash = List.filled(64, 'a').join();
    final asset = PreparedUploadAsset(
        relativePath: 'imports/source.png',
        displayName: 'source.png',
        size: 10,
        sha256: hash,
        crc32: 0,
        format: UploadImageFormat.png,
        width: 100,
        height: 100);
    final saved = await store.save(draft('a', assets: [
      asset.withUploadName('0001.png'),
      asset.withUploadName('0002.png')
    ]).copyWith(serverUri: uploadOrigin.resolve('managegallery?ulgid=12345')));
    final attempt = UploadAttempt(
        accountId: 'a',
        taskId: 'copies',
        draftId: saved.id,
        groupId: 'copies',
        serverUri: saved.serverUri!,
        assets: [
          for (final image in saved.assets)
            UploadAttemptAsset(
                'item', image.relativePath, image.sha256, image.uploadName!)
        ]);
    await store.registerAttempt(attempt);
    const first = RemoteUploadImage(
        page: 1,
        positionField: 'p1',
        position: 1,
        name: '0001.png',
        fileIndex: 77);
    const second = RemoteUploadImage(
        page: 2,
        positionField: 'p2',
        position: 2,
        name: '0002.png',
        fileIndex: 77);
    const mapping = {'0001.png': 77, '0002.png': 77};
    await expectLater(
        store.confirmReceipt(attempt, 'item', 'manual:receipt', mapping,
            remoteOccurrences: {'0001.png': first, '0002.png': first}),
        throwsFormatException);
    expect(await store.confirmedAssets(saved), isEmpty);
    await store.confirmReceipt(attempt, 'item', 'manual:receipt', mapping,
        remoteOccurrences: {'0001.png': first, '0002.png': second});
    await store.close();
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    final confirmed = await store.confirmedAssets(saved);
    expect(confirmed.map((a) => a.occurrence!.page).toSet(), {1, 2});
    expect(confirmed.map((a) => a.occurrence!.name).toSet(),
        {'0001.png', '0002.png'});
    expect(confirmed.map((a) => a.fileIndex).toSet(), {77});
  });

  test(
      'schema six upgrade retains earlier receipt records without inventing occurrence evidence',
      () async {
    await store.close();
    final file = File('${root.path}/schema-six.sqlite');
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    final saved = await store.save(draft('a').copyWith(
        serverUri: uploadOrigin.resolve('managegallery?ulgid=12345')));
    await store.database.customStatement('DROP TABLE upload_confirmed_assets');
    await store.database.customStatement(
        'CREATE TABLE upload_confirmed_assets ('
        'account_id TEXT NOT NULL, draft_id TEXT NOT NULL, gallery_id TEXT NOT NULL, '
        'asset_key TEXT NOT NULL, upload_name TEXT NOT NULL, file_index INTEGER NOT NULL, '
        'receipt_id TEXT NOT NULL, PRIMARY KEY(account_id,draft_id,gallery_id,asset_key))');
    await store.database.customStatement(
        'INSERT INTO upload_confirmed_assets VALUES (?,?,?,?,?,?,?)', [
      'a',
      saved.id,
      '12345',
      'legacy-key',
      '0001.png',
      77,
      'legacy-receipt'
    ]);
    await store.database.customStatement('PRAGMA user_version=6');
    await store.close();
    store = UploadStore(UploadDatabase(NativeDatabase(file)), root);
    final confirmed = (await store.confirmedAssets(saved)).single;
    expect(confirmed.fileIndex, 77);
    expect(confirmed.occurrence, isNull);
  });
}
