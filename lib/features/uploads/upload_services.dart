import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../../core/network/cookie_manager.dart' as app;
import '../../core/network/network_proxy_io.dart';
import 'data/upload_http_client.dart';
import 'data/upload_advanced_actions.dart';
import 'data/upload_protocol.dart';
import 'data/upload_repository.dart';
import 'data/upload_store.dart';
import 'files/upload_asset.dart';
import 'files/upload_asset_preparer.dart';
import 'files/upload_file_io.dart';
import 'files/upload_multipart.dart';
import 'files/upload_zip.dart';
import 'platform/upload_platform.dart';

class UploadEditingSession {
  final UploadDraft draft;
  final UploadEditorSnapshot editor;
  final bool localOnly;
  const UploadEditingSession(this.draft, this.editor, {this.localOnly = false});
}

class UploadImportException implements Exception {
  final UploadDraft draft;
  final List<Map<String, String>> problems;
  const UploadImportException(this.draft, this.problems);
  @override
  String toString() => 'Some selected files could not be imported';
}

class _PreparedUploadPart extends PreparedUploadBody {
  final List<String> expectedNames;
  _PreparedUploadPart(PreparedUploadBody body, this.expectedNames)
      : super(body.path, body.contentType, body.length, body.sha256);
}

enum UploadAssetState {
  local,
  queued,
  sending,
  paused,
  awaitingVerification,
  uncertain,
  confirmed,
  stopped
}

class UploadAssetProgress {
  final PreparedUploadAsset asset;
  final UploadAssetState state;
  final int? fileIndex;
  final bool manuallyReviewed;
  const UploadAssetProgress(this.asset, this.state,
      {this.fileIndex, this.manuallyReviewed = false});
}

class _UploadWriteIntent {
  final UploadDraft submitted;
  final String? kind;
  final Map<String, Object?> context;
  String? operationId;
  _UploadWriteIntent(this.submitted, {this.kind, this.context = const {}});
}

class UploadReceiptReview {
  final String receiptId;
  final String taskId;
  final String draftId;
  final Uri galleryUri;
  final List<String> expectedNames;
  final Map<String, int> matchedFiles;
  final List<String> missingNames;
  final List<String> ambiguousNames;
  final List<RemoteUploadImage> remoteFiles;
  UploadReceiptReview(
      {required this.receiptId,
      required this.taskId,
      required this.draftId,
      required this.galleryUri,
      required List<String> expectedNames,
      required Map<String, int> matchedFiles,
      required List<String> missingNames,
      required List<String> ambiguousNames,
      List<RemoteUploadImage> remoteFiles = const []})
      : expectedNames = List.unmodifiable(expectedNames),
        matchedFiles = Map.unmodifiable(matchedFiles),
        missingNames = List.unmodifiable(missingNames),
        ambiguousNames = List.unmodifiable(ambiguousNames),
        remoteFiles = List.unmodifiable(remoteFiles);
}

/// A read-only review of one durable operation. The original request is never
/// replayed by recovery; a later confirmation rechecks the owner and state.
class UploadAdvancedRecovery {
  final String accountId;
  final String draftId;
  final String operationId;
  final int? sessionRevision;
  final UploadGalleryAction kind;
  final UploadEditorSnapshot? editor;
  final List<UploadEditorSnapshot> candidates;
  final UploadActionResult? confirmedResult;
  final bool canMarkNoEffect;
  UploadAdvancedRecovery._(
      {required this.accountId,
      required this.draftId,
      required this.operationId,
      required this.sessionRevision,
      required this.kind,
      this.editor,
      List<UploadEditorSnapshot> candidates = const [],
      this.confirmedResult,
      this.canMarkNoEffect = false})
      : candidates = List.unmodifiable(candidates);
}

/// Explicit agreement for one reviewed publication batch. It is neither saved
/// in draft fields nor shared with another action, service instance or login.
class UploadPublicationTermsConsent {
  final String accountId;
  final int? sessionRevision;
  final Object _issuer;
  final Map<String, PreparedUploadAction> _reviewed;
  final Set<String> _used = {};
  UploadPublicationTermsConsent._(this.accountId, this.sessionRevision,
      this._issuer, Map<String, PreparedUploadAction> reviewed)
      : _reviewed = Map.unmodifiable(reviewed);
}

/// Application-owned services. A route never owns a running upload.
class UploadServices {
  final app.CookieManager cookies;
  final UploadRepository repository;
  final UploadPlatform platform;
  late final UploadAdvancedActions advanced;
  Future<UploadStore>? _store;
  final Future<UploadStore> Function() _storeFactory;
  String? _preparationMarker;
  bool _preparing = false;
  bool _preparationCancelled = false;
  bool _invalidating = false;
  bool _disposed = false;
  String? _preparationDraft;
  String? _preparationTask;
  String? _handedOffTask;
  bool _webHandoff = false;
  bool _webPreparing = false;
  int _webGeneration = 0;
  Completer<void>? _preparationDone;
  Future<void> _identityWrites = Future<void>.value();
  Future<void> _remoteWrites = Future<void>.value();
  Uri? _preparingGallery;
  final Object _preparationOwner = Object();
  final Object _publicationTermsIssuer = Object();
  static final Object _writeOwnerKey = Object();
  static final Object _writeIntentKey = Object();
  static final Object _visibilityKey = Object();
  UploadServices(this.cookies,
      {UploadRepository? repository,
      UploadPlatform? platform,
      UploadAdvancedActions? advanced,
      UploadStore? store,
      Future<UploadStore> Function()? storeFactory})
      : repository = repository ?? UploadRepository(UploadHttpClient(cookies)),
        platform = platform ?? UploadPlatform(),
        _storeFactory = storeFactory ??
            (store == null ? UploadStore.open : () async => store) {
    this.advanced = advanced ?? UploadAdvancedActions(this.repository);
    final previous = this.repository.beforeWrite;
    this.repository.beforeWrite = (target) async {
      await previous?.call(target);
      await _guardRemoteWrite(target);
    };
    final visibility = this.repository.beforeVisibilityChange;
    this.repository.beforeVisibilityChange = (fresh, edits) async {
      await visibility?.call(fresh, edits);
      _verifyVisibilityConsent(fresh, edits);
    };
  }

  void _verifyVisibilityConsent(
      UploadEditorSnapshot fresh, Map<String, List<String>> edits) {
    final proofs =
        Zone.current[_visibilityKey] as Map<String, UploadVisibilityConsent>?;
    final proof = proofs?[uploadGalleryId(fresh.uri)];
    if (proof == null) {
      if (UploadVisibilityConsent.requiredFor(fresh, edits)) {
        throw UploadVisibilityConfirmationRequired(
            fresh, edits['category']!.single);
      }
      return;
    }
    if (proof.accountId != fresh.api.uid.toString() ||
        proof.uri != fresh.uri ||
        proof.revision != cookies.sessionRevision ||
        proof.targetCategory != edits['category']?.single ||
        proof.fingerprint != UploadVisibilityConsent.stateFingerprint(fresh) ||
        proof.editsHash != UploadVisibilityConsent.hashEdits(edits)) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'The gallery or proposed edits changed after public-visibility review. Review them again.');
    }
  }

  Future<UploadVisibilityConsent?> prepareVisibilityChange(
      UploadDraft draft) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    if (draft.serverUri == null) return null;
    if (_terminalDraft(draft)) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    final proof = await repository.prepareVisibilityChange(
        draft.accountId, draft.serverUri!, draft.fields);
    await _check(draft.accountId, revision);
    return proof;
  }

  Future<UploadEditingSession> saveRemoteWithVisibility(
      UploadDraft draft, UploadVisibilityConsent consent) {
    if (consent.accountId != draft.accountId ||
        uploadGalleryId(consent.uri) != uploadGalleryId(draft.serverUri)) {
      return Future.error(
          ArgumentError('Visibility consent belongs to another gallery'));
    }
    return runZoned(() => saveRemote(draft), zoneValues: {
      _visibilityKey: Map<String, UploadVisibilityConsent>.unmodifiable(
          {uploadGalleryId(consent.uri)!: consent}),
    });
  }

  Future<List<UploadVisibilityConsent>> prepareBulkVisibilityChange(
      String accountId,
      List<ManagedUploadGallery> targets,
      String category) async {
    final revision = cookies.sessionRevision;
    final frozen = List<ManagedUploadGallery>.unmodifiable(targets);
    await _check(accountId, revision);
    final result = <UploadVisibilityConsent>[];
    for (final target in frozen) {
      if (target.managementUri == null) {
        throw ArgumentError('A managed gallery is required');
      }
      final proof = await repository
          .prepareVisibilityChange(accountId, target.managementUri!, {
        'category': [category]
      });
      await _check(accountId, revision);
      if (proof != null) result.add(proof);
    }
    return List.unmodifiable(result);
  }

  Future<UploadBulkResult> bulkModifyWithVisibility(
      String accountId, List<ManagedUploadGallery> targets,
      {required String categoryValue,
      required List<UploadVisibilityConsent> consents,
      bool Function()? isCancelled}) {
    final proofs = <String, UploadVisibilityConsent>{};
    for (final proof in consents) {
      final id = uploadGalleryId(proof.uri);
      if (proof.accountId != accountId ||
          id == null ||
          proofs.containsKey(id)) {
        return Future.error(ArgumentError('Invalid visibility review set'));
      }
      proofs[id] = proof;
    }
    return runZoned(
        () => repository.bulkModify(accountId, targets,
            categoryValue: categoryValue, isCancelled: isCancelled),
        zoneValues: {
          _visibilityKey:
              Map<String, UploadVisibilityConsent>.unmodifiable(proofs)
        });
  }

  Future<UploadStore> get store => _store ??= _openStore();
  Future<UploadStore> _openStore() async {
    try {
      await platform.excludeFromBackup();
      final storage = await _storeFactory();
      await storage.initialize();
      return storage;
    } catch (_) {
      _store = null;
      rethrow;
    }
  }

  Future<void> _check(String accountId, int? revision) async {
    if (_disposed ||
        _invalidating ||
        revision != cookies.sessionRevision ||
        await cookies.getMemberId() != accountId ||
        revision != cookies.sessionRevision) {
      throw const UploadFailure(UploadFailureKind.sessionChanged);
    }
  }

  Future<UploadSessionIdentity> _ensureNativeIdentity(
      String accountId, int? revision) {
    final next = _identityWrites.then((_) async {
      await _check(accountId, revision);
      final storage = await store;
      var identity = await storage.session();
      if (identity?.accountId != accountId) {
        if (identity != null) await platform.invalidateSession(identity.epoch);
        await _check(accountId, revision);
        identity = await storage.createSession(accountId);
      }
      await _check(accountId, revision);
      try {
        await platform.prepareSession(accountId, identity!.epoch);
      } on PlatformException catch (error) {
        if (!{'revoked_session', 'session_revoked'}.contains(error.code)) {
          rethrow;
        }
        await _check(accountId, revision);
        identity = await storage.createSession(accountId);
        await platform.prepareSession(accountId, identity.epoch);
      }
      await _check(accountId, revision);
      return identity;
    });
    _identityWrites =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<Map<String, dynamic>> _nativeSnapshot(
      String accountId, int? revision) async {
    await _ensureNativeIdentity(accountId, revision);
    final raw = await platform.snapshot();
    await _check(accountId, revision);
    final tasks = (raw['tasks'] as List? ?? [])
        .whereType<Map>()
        .where((t) => t['accountId'] == accountId)
        .map((t) => Map<String, dynamic>.from(t))
        .toList();
    final receipts = (raw['receipts'] as List? ?? [])
        .whereType<Map>()
        .where((r) => r['accountId'] == accountId)
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    final storage = await store;
    final attempts = {
      for (final a in await storage.attempts(accountId)) a.taskId: a
    };
    for (final receipt in receipts) {
      if (receipt['acknowledged'] != true ||
          receipt['outcome'] != 'confirmed') {
        continue;
      }
      final attempt = attempts[receipt['taskId']];
      if (attempt == null) continue;
      final savedDraft = await storage.draft(accountId, attempt.draftId);
      if (savedDraft == null) continue;
      final known = {
        for (final a in await storage.confirmedAssets(savedDraft)) a.assetKey
      };
      final selected =
          attempt.assets.where((a) => a.itemId == receipt['itemId']).toList();
      if (selected.isNotEmpty && selected.every((a) => known.contains(a.key))) {
        continue;
      }
      try {
        final mapping = await _confirmedMapping(storage, attempt, receipt);
        await storage.confirmReceipt(attempt, receipt['itemId'] as String,
            receipt['receiptId'] as String, mapping);
      } on Object {
        // The transfer may be accepted, but missing local evidence must not
        // cause either a duplicate re-upload or a fabricated per-file success.
        for (final task in tasks.where((t) => t['taskId'] == attempt.taskId)) {
          task['reconciliationRequired'] = true;
        }
      }
    }
    for (final task in tasks) {
      final attempt = attempts[task['taskId']];
      task['draftId'] = attempt?.draftId ?? task['taskId'];
      if (attempt != null) task['serverUri'] = attempt.serverUri.toString();
      task['blocksEditing'] = _taskBlocks(task, receipts);
    }
    await _check(accountId, revision);
    return {'tasks': tasks, 'receipts': receipts};
  }

  Future<Map<String, int>> _confirmedMapping(UploadStore storage,
      UploadAttempt attempt, Map<String, dynamic> receipt) async {
    final selected =
        attempt.assets.where((a) => a.itemId == receipt['itemId']).toList();
    if (selected.isEmpty ||
        receipt['accountId'] != attempt.accountId ||
        receipt['taskId'] != attempt.taskId) {
      throw const FormatException('Mismatched upload receipt');
    }
    final verification = receipt['verification'] as Map?;
    final expected = (verification?['expectedNames'] as List?)?.cast<String>();
    final names = selected.map((a) => a.uploadName).toSet();
    if (verification?['galleryId'] != uploadGalleryId(attempt.serverUri) ||
        expected == null ||
        expected.length != names.length ||
        !names.containsAll(expected)) {
      throw const FormatException('Mismatched upload receipt manifest');
    }
    final finalUri = Uri.tryParse(receipt['finalUrl'] as String? ?? '');
    if (receipt['status'] != 200 ||
        receipt['sentBytes'] != receipt['length'] ||
        (receipt['length'] as num? ?? 0) <= 0 ||
        uploadGalleryId(finalUri) != uploadGalleryId(attempt.serverUri)) {
      throw const FormatException('Incomplete upload response');
    }
    final path = receipt['responsePath'] as String?;
    if (path == null ||
        !RegExp(r'^native/(android|ios)/responses/[^/]+$').hasMatch(path)) {
      throw const FormatException('Missing upload response');
    }
    final response = await resolveUploadFile(storage.root, path);
    if (await response.length() > 2 * 1024 * 1024) {
      throw const FormatException('Upload response too large');
    }
    final editor =
        repository.protocol.editor(await response.readAsString(), finalUri!);
    if (editor.api.uid.toString() != attempt.accountId ||
        uploadGalleryId(editor.form.action) !=
            uploadGalleryId(attempt.serverUri)) {
      throw const FormatException('Mismatched upload response identity');
    }
    final prior =
        (verification?['priorFileIndexes'] as List? ?? []).cast<int>().toSet();
    final result = <String, int>{};
    for (final name in names) {
      final matches = editor.images.where((i) => i.name == name).toList();
      final id = matches.length == 1 ? matches.single.fileIndex : null;
      if (id == null ||
          id <= 0 ||
          prior.contains(id) ||
          editor.images.where((i) => i.fileIndex == id).length != 1) {
        throw const FormatException('Ambiguous upload response image');
      }
      result[name] = id;
    }
    return result;
  }

  bool _taskBlocks(Map task, List receipts) =>
      !{'stopped', 'completed'}.contains(task['state']) ||
      task['reconciliationRequired'] == true ||
      receipts.whereType<Map>().any(
          (r) => r['taskId'] == task['taskId'] && r['acknowledged'] != true);

  Future<void> _guardRemoteWrite(Uri target) async {
    if (_webHandoff || _webPreparing) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'Close the website manager before changing galleries in the app.');
    }
    final revision = cookies.sessionRevision;
    final account = await cookies.getMemberId();
    if (account == null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    await _check(account, revision);
    final gallery = uploadGalleryId(target);
    if (gallery == null) {
      await _recordWriteIntent();
      return;
    }
    if (uploadGalleryId(_preparingGallery) == gallery &&
        Zone.current[_writeOwnerKey] != _preparationOwner) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'This gallery is preparing an upload. Wait until it stops before editing.');
    }
    final snapshot = await _nativeSnapshot(account, revision);
    final storage = await store;
    for (final task in (snapshot['tasks'] as List).cast<Map>()) {
      if (!_taskBlocks(task, snapshot['receipts'] as List)) continue;
      final uri = task['serverUri'] is String
          ? Uri.tryParse(task['serverUri'] as String)
          : (await storage.draft(account, task['draftId'] as String))
              ?.serverUri;
      if (uploadGalleryId(uri) == null || uploadGalleryId(uri) == gallery) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'This gallery has an active upload or an unresolved result. Reconcile it before editing.');
      }
    }
    for (final draft in await storage.drafts(account)) {
      if (uploadGalleryId(draft.serverUri) == gallery &&
          await storage.pendingWrite(account, draft.id) != null) {
        throw const UploadFailure(UploadFailureKind.resultUncertain,
            serverMessage:
                'A previous write to this gallery still needs reconciliation.');
      }
    }
    await _recordWriteIntent();
  }

  Future<void> _recordWriteIntent() async {
    final intent = Zone.current[_writeIntentKey] as _UploadWriteIntent?;
    if (intent != null && intent.operationId == null) {
      intent.operationId = await (await store).beginWrite(intent.submitted,
          kind: intent.kind, context: intent.context);
    }
  }

  Future<List<PreparedUploadAsset>> pendingAssets(UploadDraft draft) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    final confirmed = {
      for (final a in await (await store).confirmedAssets(draft)) a.assetKey
    };
    await _check(draft.accountId, revision);
    return draft.assets
        .where((a) => !confirmed.contains(uploadAssetKey(a)))
        .toList();
  }

  Future<List<UploadAssetProgress>> assetProgress(UploadDraft draft,
      {Map<String, dynamic>? snapshot}) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    final state = snapshot ?? await transferSnapshot();
    final storage = await store;
    final confirmed = {
      for (final a in await storage.confirmedAssets(draft)) a.assetKey: a
    };
    final attempts = await storage.attempts(draft.accountId, draftId: draft.id);
    final pending = <String, UploadAssetState>{};
    for (final task in (state['tasks'] as List? ?? []).whereType<Map>()) {
      final matching = attempts.where((a) => a.taskId == task['taskId']);
      if (matching.isEmpty) continue;
      for (final item in (task['items'] as List? ?? []).whereType<Map>()) {
        var label = item['state'] as String? ?? 'local';
        if (label == 'accepted') label = 'awaitingVerification';
        if (task['state'] == 'paused' && label == 'queued') label = 'paused';
        if (task['reconciliationRequired'] == true && label == 'confirmed') {
          label = 'uncertain';
        }
        final value =
            UploadAssetState.values.where((s) => s.name == label).firstOrNull ??
                UploadAssetState.local;
        for (final asset
            in matching.single.assets.where((a) => a.itemId == item['id'])) {
          pending[asset.key] = value;
        }
      }
    }
    await _check(draft.accountId, revision);
    return [
      for (final asset in draft.assets)
        UploadAssetProgress(
            asset,
            confirmed.containsKey(uploadAssetKey(asset))
                ? UploadAssetState.confirmed
                : pending[uploadAssetKey(asset)] ?? UploadAssetState.local,
            fileIndex: confirmed[uploadAssetKey(asset)]?.fileIndex,
            manuallyReviewed: confirmed[uploadAssetKey(asset)]
                    ?.receiptId
                    .startsWith('manual:') ??
                false)
    ];
  }

  Map<String, List<String>> _businessFields(UploadEditorSnapshot editor) => {
        for (final field in editor.form.fields.values)
          if (uploadEditableFields.contains(field.name) && field.name != 'tos')
            field.name: List.of(field.values),
      };

  Future<UploadEditingSession> createDraft(String accountId) async {
    final revision = cookies.sessionRevision;
    await _check(accountId, revision);
    final editor = await repository.newEditor(accountId);
    final storage = await store;
    await _check(accountId, revision);
    final draft = UploadDraft(
        id: newUploadId(),
        accountId: accountId,
        fields: {},
        serverFields: _businessFields(editor),
        assets: []);
    return UploadEditingSession(await storage.save(draft), editor);
  }

  Future<UploadEditingSession> openDraft(String accountId, String id) async {
    final revision = cookies.sessionRevision;
    await _check(accountId, revision);
    final storage = await store;
    var draft = await storage.draft(accountId, id);
    if (draft == null) throw StateError('Upload draft no longer exists');
    await _check(accountId, revision);
    if (_terminalDraft(draft)) return _localSession(draft);
    final editor = draft.serverUri == null
        ? await repository.newEditor(accountId)
        : await repository.editor(accountId, draft.serverUri!);
    await _check(accountId, revision);
    if (draft.serverUri != null &&
        uploadGalleryId(editor.form.action) !=
            uploadGalleryId(draft.serverUri)) {
      throw const UploadFailure(UploadFailureKind.resultUncertain);
    }
    if (!draft.dirty) {
      draft = await storage.mergeRemote(
          draft, _businessFields(editor), editor.uri,
          refreshOnly: true);
    }
    return UploadEditingSession(draft, editor);
  }

  Future<UploadEditingSession> openRemote(String accountId, Uri uri) async {
    final revision = cookies.sessionRevision;
    await _check(accountId, revision);
    final storage = await store;
    for (final draft in await storage.drafts(accountId)) {
      if (draft.serverUri == uri) {
        if (_terminalDraft(draft)) {
          final fresh = await repository.editor(accountId, uri);
          await _check(accountId, revision);
          if (fresh.form.fields['ulcomment']?.canEdit == true &&
              fresh.buttons['savebutton']?.enabled == true) {
            final restored =
                await storage.restoreRemoteOwnership(accountId, draft.id);
            final saved = restored.dirty
                ? restored
                : await storage.mergeRemote(
                    restored, _businessFields(fresh), fresh.uri,
                    refreshOnly: true);
            return UploadEditingSession(saved, fresh);
          }
          return _localSession(draft);
        }
        return openDraft(accountId, draft.id);
      }
    }
    final editor = await repository.editor(accountId, uri);
    await _check(accountId, revision);
    final fields = _businessFields(editor);
    final draft = UploadDraft(
        id: newUploadId(),
        accountId: accountId,
        fields: fields,
        serverFields: fields,
        assets: [],
        serverUri: editor.uri,
        dirty: false);
    return UploadEditingSession(await storage.save(draft), editor);
  }

  Future<UploadDraft> saveLocal(UploadDraft draft) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    final storage = await store;
    await _check(draft.accountId, revision);
    if (_preparing && _preparationDraft == draft.id) {
      final current = await storage.draft(draft.accountId, draft.id);
      if (current != null && !_sameAssets(current.assets, draft.assets)) {
        throw StateError('Stop file preparation before changing its file list');
      }
    }
    return storage.saveLocalEdits(draft);
  }

  Future<UploadEditingSession> saveRemote(UploadDraft draft) {
    if (_terminalDraft(draft)) {
      return Future.error(const UploadFailure(UploadFailureKind.restricted));
    }
    if (_webHandoff || _webPreparing) {
      return Future.error(const UploadFailure(UploadFailureKind.restricted));
    }
    final revision = cookies.sessionRevision;
    final next = _remoteWrites.then((_) async {
      await _check(draft.accountId, revision);
      final storage = await store;
      if (await storage.pendingWrite(draft.accountId, draft.id) != null) {
        throw const UploadFailure(UploadFailureKind.resultUncertain,
            serverMessage:
                'Reconcile the previous save before sending it again.');
      }
      final submitted = await storage.saveLocalEdits(draft);
      if (_terminalDraft(submitted)) {
        throw const UploadFailure(UploadFailureKind.restricted);
      }
      final intent = _UploadWriteIntent(submitted);
      final editor = await runZoned(
          () => repository.save(
              submitted.accountId,
              submitted.serverUri ??
                  uploadOrigin.resolve('managegallery?act=new'),
              submitted.fields,
              baseline:
                  submitted.serverUri == null ? null : submitted.serverFields),
          zoneValues: {_writeIntentKey: intent});
      await _check(draft.accountId, revision);
      if (submitted.serverUri != null &&
          uploadGalleryId(editor.form.action) !=
              uploadGalleryId(submitted.serverUri)) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      final saved = await storage.mergeRemote(
          submitted, _businessFields(editor), editor.uri);
      if (intent.operationId != null) {
        await storage.resolveWrite(
            draft.accountId, draft.id, intent.operationId!);
      }
      return UploadEditingSession(saved, editor);
    });
    _remoteWrites =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<PendingUploadWrite?> pendingWrite(UploadDraft draft) async {
    await _check(draft.accountId, cookies.sessionRevision);
    return (await store).pendingWrite(draft.accountId, draft.id);
  }

  Future<T> _serializedRemoteAction<T>(
      UploadDraft draft, Future<T> Function() action) {
    final revision = cookies.sessionRevision;
    final next = _remoteWrites.then((_) async {
      await _check(draft.accountId, revision);
      return action();
    });
    _remoteWrites =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<UploadEditingSession> associatePendingGallery(
          UploadDraft draft, Uri selectedGallery,
          {String? expectedOperationId}) =>
      _serializedRemoteAction(
          draft,
          () => _associatePendingGallery(draft, selectedGallery,
              expectedOperationId: expectedOperationId));

  Future<UploadEditingSession> _associatePendingGallery(
      UploadDraft draft, Uri selectedGallery,
      {String? expectedOperationId}) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    if (uploadGalleryId(selectedGallery) == null) {
      throw ArgumentError('Select a managed gallery');
    }
    final storage = await store;
    final pending = await storage.pendingWrite(draft.accountId, draft.id);
    if (pending == null) throw StateError('There is no unresolved write');
    _requireReviewedWrite(pending, expectedOperationId);
    if (!{'create', 'save'}.contains(pending.kind)) {
      throw StateError(
          'Reconcile this operation using its action-specific result');
    }
    if (pending.serverUri != null &&
        uploadGalleryId(pending.serverUri) !=
            uploadGalleryId(selectedGallery)) {
      throw ArgumentError(
          'A saved gallery must be reconciled with its original identity');
    }
    final editor = await repository.editor(draft.accountId, selectedGallery);
    await _check(draft.accountId, revision);
    final submitted = draft.copyWith(fields: pending.fields);
    final saved = await storage.mergeRemote(
        submitted, _businessFields(editor), editor.uri,
        preserveLocal: true);
    await storage.resolveWrite(draft.accountId, draft.id, pending.operationId,
        outcome: 'manual_association');
    return UploadEditingSession(saved, editor);
  }

  Future<void> retryAfterVerifiedNoChange(UploadDraft draft,
          {required bool confirmed, String? expectedOperationId}) =>
      _serializedRemoteAction(
          draft,
          () => _retryAfterVerifiedNoChange(draft,
              confirmed: confirmed, expectedOperationId: expectedOperationId));

  Future<void> _retryAfterVerifiedNoChange(UploadDraft draft,
      {required bool confirmed, String? expectedOperationId}) async {
    if (!confirmed) throw ArgumentError('Explicit verification is required');
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    final storage = await store;
    final pending = await storage.pendingWrite(draft.accountId, draft.id);
    if (pending == null) return;
    _requireReviewedWrite(pending, expectedOperationId);
    if (!{'create', 'save'}.contains(pending.kind)) {
      throw StateError(
          'Reconcile this operation using its action-specific result');
    }
    await _check(draft.accountId, revision);
    await storage.resolveWrite(draft.accountId, draft.id, pending.operationId,
        outcome: 'manual_no_effect');
  }

  void _requireReviewedWrite(PendingUploadWrite pending, String? operationId) {
    if (operationId == null || pending.operationId != operationId) {
      throw StateError('The unresolved write changed. Review it again.');
    }
  }

  Future<UploadReceiptReview> reviewReceipt(String receiptId) async {
    final revision = cookies.sessionRevision;
    final account = await cookies.getMemberId();
    if (account == null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    final snapshot = await _nativeSnapshot(account, revision);
    final receipt = (snapshot['receipts'] as List)
        .cast<Map>()
        .where((r) => r['receiptId'] == receiptId)
        .firstOrNull;
    if (receipt == null) throw StateError('Upload receipt no longer exists');
    final attempt = (await (await store).attempts(account))
        .where((a) => a.taskId == receipt['taskId'])
        .firstOrNull;
    if (attempt == null) {
      throw StateError('The original upload manifest is unavailable');
    }
    final selected =
        attempt.assets.where((a) => a.itemId == receipt['itemId']).toList();
    if (selected.isEmpty) {
      throw StateError('The original upload manifest is unavailable');
    }
    final editor = await repository.editor(account, attempt.serverUri);
    await _check(account, revision);
    final prior =
        (((receipt['verification'] as Map?)?['priorFileIndexes']) as List? ??
                [])
            .cast<int>()
            .toSet();
    final matched = <String, int>{};
    final missing = <String>[];
    final ambiguous = <String>[];
    for (final asset in selected) {
      final candidates = editor.images
          .where((image) => image.name == asset.uploadName)
          .toList();
      if (candidates.isEmpty) {
        missing.add(asset.uploadName);
        continue;
      }
      final id = candidates.length == 1 ? candidates.single.fileIndex : null;
      if (id == null ||
          id <= 0 ||
          prior.contains(id) ||
          editor.images.where((image) => image.fileIndex == id).length != 1) {
        ambiguous.add(asset.uploadName);
        continue;
      }
      matched[asset.uploadName] = id;
    }
    return UploadReceiptReview(
        receiptId: receiptId,
        taskId: attempt.taskId,
        draftId: attempt.draftId,
        galleryUri: attempt.serverUri,
        expectedNames: selected.map((a) => a.uploadName).toList(),
        matchedFiles: matched,
        missingNames: missing,
        ambiguousNames: ambiguous,
        remoteFiles: editor.images);
  }

  Future<void> acceptReceiptReview(UploadReceiptReview reviewed,
      {required bool confirmed, bool stopRemaining = false}) async {
    if (!confirmed) throw ArgumentError('Explicit verification is required');
    final revision = cookies.sessionRevision;
    final account = await cookies.getMemberId();
    if (account == null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    final latest = await reviewReceipt(reviewed.receiptId);
    if (latest.taskId != reviewed.taskId ||
        latest.galleryUri != reviewed.galleryUri ||
        latest.ambiguousNames.isNotEmpty ||
        latest.matchedFiles.length != reviewed.matchedFiles.length ||
        latest.matchedFiles.entries
            .any((entry) => reviewed.matchedFiles[entry.key] != entry.value) ||
        latest.missingNames.length != reviewed.missingNames.length) {
      throw StateError(
          'The gallery changed during review. Check its files again.');
    }
    if (!stopRemaining && latest.missingNames.isNotEmpty) {
      throw StateError(
          'Some files are missing; stop this attempt and prepare only the remaining files');
    }
    final storage = await store;
    final attempt = (await storage.attempts(account))
        .singleWhere((a) => a.taskId == latest.taskId);
    final snapshot = await _nativeSnapshot(account, revision);
    final receipt = (snapshot['receipts'] as List)
        .cast<Map>()
        .singleWhere((r) => r['receiptId'] == latest.receiptId);
    await _check(account, revision);
    // Persist explicit per-file review before resolving the native lock. If
    // its channel reply is lost, a restart still cannot resend accepted files.
    if (latest.matchedFiles.isNotEmpty) {
      await storage.confirmReceipt(attempt, receipt['itemId'] as String,
          'manual:${latest.receiptId}', latest.matchedFiles,
          allowPartial: stopRemaining);
    }
    await platform.acknowledge(
        latest.receiptId, stopRemaining ? 'stop' : 'confirmed');
    if (stopRemaining) {
      await storage.cleanupPreparations(account, taskId: latest.taskId);
    }
  }

  Future<void> acceptManualReceiptMapping(UploadReceiptReview reviewed,
      {required Map<String, RemoteUploadImage> selectedEntries,
      Set<String> notReceivedNames = const {},
      required bool confirmed}) async {
    final selected =
        Map<String, RemoteUploadImage>.unmodifiable(selectedEntries);
    final notReceived = Set<String>.unmodifiable(notReceivedNames);
    if (!confirmed || (selected.isEmpty && notReceived.isEmpty)) {
      throw ArgumentError('Explicit image association is required');
    }
    final revision = cookies.sessionRevision;
    final account = await cookies.getMemberId();
    if (account == null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    final latest = await reviewReceipt(reviewed.receiptId);
    if (latest.taskId != reviewed.taskId ||
        latest.galleryUri != reviewed.galleryUri ||
        !_sameRemoteOccurrences(latest.remoteFiles, reviewed.remoteFiles) ||
        !{...selected.keys, ...notReceived}
            .containsAll(latest.ambiguousNames) ||
        selected.keys.any(notReceived.contains) ||
        {...selected.keys, ...notReceived}
            .any((name) => !latest.expectedNames.contains(name))) {
      throw StateError(
          'The gallery changed or the review is incomplete. Review its entries again.');
    }
    final used = <int>{};
    for (final entry in selected.values) {
      if ((entry.fileIndex ?? 0) <= 0 ||
          entry.page <= 0 ||
          !used.add(entry.page) ||
          latest.remoteFiles
                  .where((image) => _sameRemoteOccurrence(image, entry))
                  .length !=
              1) {
        throw StateError('A selected site image changed during review');
      }
    }
    final storage = await store;
    final attempt = (await storage.attempts(account))
        .singleWhere((a) => a.taskId == latest.taskId);
    final local = await storage.draft(account, attempt.draftId);
    if (local == null) {
      throw StateError('The original local draft is unavailable');
    }
    final currentAssetKeys = local.assets.map(uploadAssetKey).toSet();
    final selectedAssetKeys = attempt.assets
        .where((asset) => selected.containsKey(asset.uploadName))
        .map((asset) => asset.key)
        .toSet();
    for (final known in await storage.confirmedAssets(local)) {
      if (!currentAssetKeys.contains(known.assetKey) ||
          selectedAssetKeys.contains(known.assetKey)) continue;
      final existing = latest.remoteFiles
          .where((image) =>
              image.fileIndex == known.fileIndex &&
              image.name == (known.occurrence?.name ?? known.uploadName))
          .toList();
      if (existing.isEmpty) {
        continue; // A removed entry is not reserved forever.
      }
      if ((existing.length != 1 &&
              selected.values
                  .any((image) => image.fileIndex == known.fileIndex)) ||
          selected.values
              .any((image) => existing.any((old) => old.page == image.page))) {
        throw StateError(
            'A website entry is already associated with another local image');
      }
    }
    final snapshot = await _nativeSnapshot(account, revision);
    final receipt = (snapshot['receipts'] as List)
        .cast<Map>()
        .singleWhere((r) => r['receiptId'] == latest.receiptId);
    await _check(account, revision);
    if (selected.isNotEmpty) {
      await storage.confirmReceipt(
          attempt,
          receipt['itemId'] as String,
          'manual:${latest.receiptId}',
          {
            for (final entry in selected.entries)
              entry.key: entry.value.fileIndex!,
          },
          allowPartial: true,
          remoteOccurrences: selected);
    }
    // Manual association records the user's review, not success of the old
    // uncertain request. Stop it and freshly prepare any remaining local files.
    await platform.acknowledge(latest.receiptId, 'stop');
    if (notReceived.isNotEmpty) {
      await storage.resetReviewedMissingNames(attempt, notReceived);
    }
    await storage.cleanupPreparations(account, taskId: latest.taskId);
  }

  bool _sameRemoteOccurrence(RemoteUploadImage a, RemoteUploadImage b) =>
      a.page == b.page &&
      a.position == b.position &&
      a.positionField == b.positionField &&
      a.name == b.name &&
      a.fileIndex == b.fileIndex;

  bool _sameRemoteOccurrences(
          List<RemoteUploadImage> a, List<RemoteUploadImage> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length)
          .every((i) => _sameRemoteOccurrence(a[i], b[i]));

  Future<UploadDraft> importFiles(UploadDraft draft,
      {required bool photos, String language = 'zh'}) async {
    if (_terminalDraft(draft)) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    if (_preparing) throw StateError('Upload preparation is already active');
    final revision = cookies.sessionRevision;
    _preparing = true;
    _preparationCancelled = false;
    _preparationDraft = draft.id;
    _preparationDone = Completer<void>();
    UploadStore? storage;
    try {
      await _check(draft.accountId, revision);
      // Cold-start orphan cleanup must precede creation of new native copies.
      storage = await store;
      await _check(draft.accountId, revision);
      _checkPreparationCancellation();
      final result = await platform.pick(photos: photos, language: language);
      await _check(draft.accountId, revision);
      _checkPreparationCancellation();
      if (result['cancelled'] == true) return draft;
      final rootPath = storage.root.path;
      final marker = await _newMarker(storage);
      final rows = (result['files'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final inspected = await _runInspection(rootPath, rows, marker);
      await _check(draft.accountId, revision);
      _checkPreparationCancellation();
      final next = await storage.appendAssets(
          draft.accountId, draft.id, inspected.assets);
      final problems = <Map<String, String>>[
        for (final error in result['errors'] as List? ?? [])
          {
            'displayName': (error as Map)['displayName']?.toString() ?? '',
            'reason': error['reason']?.toString() ?? 'import_failed',
          },
        for (final issue in inspected.excluded)
          {
            'displayName': issue.displayName ?? '',
            'reason': issue.code,
          },
      ];
      if (problems.isNotEmpty) throw UploadImportException(next, problems);
      return next;
    } finally {
      final done = _preparationDone;
      try {
        // Includes copied ZIPs after expansion, rejected files, and files from
        // an interrupted isolate which never made it into a draft record.
        await storage?.cleanupOrphanImports();
        await _clearMarker();
      } finally {
        _preparationDone = null;
        _preparing = false;
        _preparationDraft = null;
        done?.complete();
      }
    }
  }

  Future<UploadDraft> convertAsset(
      UploadDraft draft, PreparedUploadAsset asset) async {
    if (_terminalDraft(draft)) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    if (_preparing) throw StateError('Upload preparation is already active');
    final revision = cookies.sessionRevision;
    _preparing = true;
    _preparationCancelled = false;
    _preparationDraft = draft.id;
    _preparationDone = Completer<void>();
    UploadStore? storage;
    try {
      await _check(draft.accountId, revision);
      storage = await store;
      final confirmed = await storage.confirmedAssets(draft);
      if (confirmed.any((a) => a.assetKey == uploadAssetKey(asset))) {
        throw StateError('An uploaded image cannot be replaced locally');
      }
      _checkPreparationCancellation();
      final row =
          Map<String, dynamic>.from(await platform.convert(asset.relativePath));
      final sourceName =
          asset.displayName.replaceAll('\\', '/').split('/').last;
      final dot = sourceName.lastIndexOf('.');
      row['displayName'] =
          '${dot > 0 ? sourceName.substring(0, dot) : sourceName}.png';
      await _check(draft.accountId, revision);
      _checkPreparationCancellation();
      final marker = await _newMarker(storage);
      final rootPath = storage.root.path;
      final inspected = await _runInspection(rootPath, [row], marker);
      await _check(draft.accountId, revision);
      _checkPreparationCancellation();
      if (inspected.assets.length != 1 || !inspected.assets.single.isValid) {
        throw UploadImportException(draft, [
          for (final issue in [
            ...inspected.excluded,
            ...inspected.assets.expand((a) => a.issues)
          ])
            {
              'displayName': issue.displayName ?? asset.displayName,
              'reason': issue.code
            }
        ]);
      }
      return await storage.replaceAsset(
          draft.accountId, draft.id, asset, inspected.assets.single);
    } finally {
      final done = _preparationDone;
      try {
        await storage?.cleanupOrphanImports();
        await _clearMarker();
      } finally {
        _preparing = false;
        _preparationDraft = null;
        _preparationDone = null;
        done?.complete();
      }
    }
  }

  static Future<ZipImportResult> _inspect(
      String rootPath,
      List<Map<String, dynamic>> rows,
      String marker,
      SendPort spacePort) async {
    final root = Directory(rootPath);
    const preparer = UploadAssetPreparer();
    final assets = <PreparedUploadAsset>[];
    final excluded = <ValidationIssue>[];
    final active = File(marker);
    bool cancelled() => !active.existsSync();
    for (final row in rows) {
      checkUploadCancellation(cancelled);
      final path = row['relativePath'] as String;
      final name = row['displayName'] as String;
      try {
        if (name.toLowerCase().endsWith('.zip')) {
          final result = await const UploadZipExtractor().extract(
              root: root,
              archiveRelativePath: path,
              destinationId: newUploadId(),
              isCancelled: cancelled,
              availableBytes: () => _queryWorkerSpace(spacePort));
          assets.addAll(result.assets);
          excluded.addAll(result.excluded);
        } else {
          assets.add(await preparer.inspect(
              root: root,
              relativePath: path,
              displayName: name,
              isCancelled: cancelled));
        }
      } on UploadFileException catch (error) {
        excluded.add(ValidationIssue(error.code,
            displayName: error.displayName ?? name));
      }
    }
    return ZipImportResult(assets: assets, excluded: excluded);
  }

  // Keep isolate closures in a static scope: closures inside the upload method
  // can otherwise capture its shared context, including unsendable Futures.
  Future<ZipImportResult> _runInspection(
          String rootPath, List<Map<String, dynamic>> rows, String marker) =>
      _withSpacePort((port) => _spawnInspection(rootPath, rows, marker, port));

  static Future<ZipImportResult> _spawnInspection(String rootPath,
          List<Map<String, dynamic>> rows, String marker, SendPort port) =>
      Isolate.run(() => _inspect(rootPath, rows, marker, port));

  Future<List<_PreparedUploadPart>> _runBodies(
          String rootPath,
          List<PreparedUploadAsset> assets,
          Map<String, List<String>> fields,
          String batchId,
          String marker) =>
      _withSpacePort((port) =>
          _spawnBodies(rootPath, assets, fields, batchId, marker, port));

  static Future<List<_PreparedUploadPart>> _spawnBodies(
          String rootPath,
          List<PreparedUploadAsset> assets,
          Map<String, List<String>> fields,
          String batchId,
          String marker,
          SendPort port) =>
      Isolate.run(
          () => _bodies(rootPath, assets, fields, batchId, marker, port));

  Future<T> _withSpacePort<T>(Future<T> Function(SendPort) action) async {
    final receive = ReceivePort();
    final subscription = receive.listen((message) async {
      if (message is! SendPort) return;
      try {
        message.send(await platform.availableBytes());
      } catch (_) {
        message.send('storage_unavailable');
      }
    });
    try {
      return await action(receive.sendPort);
    } finally {
      await subscription.cancel();
      receive.close();
    }
  }

  static Future<int> _queryWorkerSpace(SendPort port) async {
    final reply = ReceivePort();
    try {
      port.send(reply.sendPort);
      final value = await reply.first.timeout(const Duration(seconds: 30));
      if (value is! int || value < 0) {
        throw const UploadFileException('storage_unavailable');
      }
      return value;
    } finally {
      reply.close();
    }
  }

  Future<String> _newMarker(UploadStore storage) async {
    final directory = await createUploadDirectory(storage.root, 'preparation');
    final path = '${directory.path}/${newUploadId()}.active';
    await File(path).writeAsString('', flush: true);
    _preparationMarker = path;
    return path;
  }

  Future<void> _clearMarker() async {
    final path = _preparationMarker;
    _preparationMarker = null;
    if (path != null && await File(path).exists()) await File(path).delete();
  }

  Future<void> cancelPreparation() async {
    _preparationCancelled = true;
    final done = _preparationDone?.future;
    final marker = _preparationMarker;
    try {
      // Removing an existing zero-byte lease does not require disk space,
      // unlike creating a cancellation marker when the disk has filled up.
      if (marker != null && await File(marker).exists()) {
        await File(marker).delete();
      }
      await platform.cancelImport();
      final handedOff = _handedOffTask;
      if (handedOff != null && !_invalidating) {
        try {
          await platform.cancel(handedOff);
        } on PlatformException catch (error) {
          if (!{'unknown_task', 'task_not_found'}.contains(error.code)) rethrow;
        }
      }
    } finally {
      if (done != null) await done;
    }
  }

  void _checkPreparationCancellation() {
    if (_preparationCancelled) throw const UploadCancelled();
  }

  Future<void> startUpload(UploadDraft draft,
      {bool wifiOnly = false, String language = 'zh'}) async {
    if (_terminalDraft(draft)) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    if (_webHandoff || _webPreparing) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    if (_preparing) throw StateError('Upload preparation is already active');
    if (draft.assets.isEmpty) {
      throw const UploadFileException('invalid_gallery');
    }
    final revision = cookies.sessionRevision;
    _preparing = true;
    _preparationCancelled = false;
    _preparationDraft = draft.id;
    _preparingGallery = draft.serverUri;
    _preparationDone = Completer<void>();
    String? artifactGroup;
    final attemptId = newUploadId();
    _preparationTask = attemptId;
    var handedOff = false;
    try {
      await _check(draft.accountId, revision);
      final storage = await store;
      _checkPreparationCancellation();
      final identity = await _ensureNativeIdentity(draft.accountId, revision);
      final state = await _nativeSnapshot(draft.accountId, revision);
      if ((state['tasks'] as List).whereType<Map>().any((t) =>
          t['draftId'] == draft.id &&
          _taskBlocks(t, state['receipts'] as List))) {
        throw StateError(
            'This draft already has an upload task. Check its result before uploading again.');
      }
      final remote = await runZoned(() => saveRemote(draft),
          zoneValues: {_writeOwnerKey: _preparationOwner});
      _preparingGallery = remote.draft.serverUri;
      if (!remote.editor.canUpload || remote.draft.serverUri == null) {
        throw const UploadFailure(UploadFailureKind.restricted);
      }
      final pending = await pendingAssets(remote.draft);
      if (pending.isEmpty) throw const UploadFileException('no_pending_images');
      if (const UploadAssetPreparer()
          .validateGallery(pending,
              existingImages: remote.editor.images.length,
              existingBytes: _remoteBytesLowerBound(
                  remote.editor.metadata['Total Filesize']))
          .any((i) => i.severity == UploadIssueSeverity.error)) {
        throw const UploadFileException('invalid_gallery');
      }
      final names = remote.editor.images.map((i) => i.name).toSet();
      final frozen = <PreparedUploadAsset>[];
      var sequence = remote.editor.images.length + 1;
      for (final asset in pending) {
        if (asset.uploadName != null) {
          if (!names.add(asset.uploadName!)) {
            throw const UploadFileException(
                'upload_name_requires_reconciliation');
          }
          frozen.add(asset);
        } else {
          while (true) {
            final candidate = const UploadAssetPreparer()
                .freezeNames([asset], firstSequence: sequence++).single;
            if (names.add(candidate.uploadName!)) {
              frozen.add(candidate);
              break;
            }
          }
        }
      }
      await storage.freezeAssetNames(remote.draft, pending, frozen);
      final rootPath = storage.root.path;
      final marker = await _newMarker(storage);
      final needsTerms = remote.editor.form.fields.containsKey('tos');
      if (needsTerms && remote.draft.fields['tos']?.contains('on') != true) {
        throw ArgumentError(
            'Explicit terms acceptance is required before uploading');
      }
      final fields = remote.editor.form.submission({
        if (needsTerms) 'tos': ['on']
      });
      final batchId = newUploadId();
      artifactGroup = batchId;
      await storage.registerPreparation(draft.accountId, attemptId, batchId);
      final bodies =
          await _runBodies(rootPath, frozen, fields, batchId, marker);
      _checkPreparationCancellation();
      await _check(draft.accountId, revision);
      final target = remote.editor.form.action;
      final galleryId = target.queryParameters['ulgid'];
      if (galleryId == null || !RegExp(r'^\d+$').hasMatch(galleryId)) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
      await repository.exclusiveWrite(() async {
        final fresh =
            await repository.editor(draft.accountId, remote.editor.uri);
        if (!_sameUploadBaseline(fields, fresh.form.submission({})) ||
            !_sameRemoteImages(remote.editor.images, fresh.images)) {
          throw const UploadFailure(UploadFailureKind.restricted,
              serverMessage:
                  'The gallery changed while files were prepared. Refresh and prepare again.');
        }
        _checkPreparationCancellation();
        final cookie = await cookies.getUploadCookieHeader();
        await _check(draft.accountId, revision);
        _checkPreparationCancellation();
        final frozenByName = {
          for (final asset in frozen) asset.uploadName!: asset
        };
        await storage.registerAttempt(UploadAttempt(
            accountId: draft.accountId,
            taskId: attemptId,
            draftId: draft.id,
            groupId: batchId,
            serverUri: remote.editor.uri,
            assets: [
              for (var i = 0; i < bodies.length; i++)
                for (final name in bodies[i].expectedNames)
                  UploadAttemptAsset(
                      '$batchId-$i',
                      frozenByName[name]!.relativePath,
                      frozenByName[name]!.sha256,
                      name)
            ]));
        await _check(draft.accountId, revision);
        _checkPreparationCancellation();
        handedOff =
            true; // A lost channel reply does not prove native rejection.
        _handedOffTask = attemptId;
        await platform.enqueue({
          'accountId': identity.accountId,
          'epoch': identity.epoch,
          'taskId': attemptId,
          'proxy': NetworkProxy.currentProxy,
          'language': language,
          'items': [
            for (var i = 0; i < bodies.length; i++)
              {
                'id': '$batchId-$i',
                'url': target.toString(),
                'bodyPath': bodies[i].path,
                'length': bodies[i].length,
                'sha256': bodies[i].sha256,
                'wifiOnly': wifiOnly,
                'verification': {
                  'galleryId': galleryId,
                  'expectedNames': bodies[i].expectedNames,
                  'priorFileIndexes': [
                    for (final image in remote.editor.images)
                      if (image.fileIndex != null) image.fileIndex!
                  ],
                },
                'headers': {
                  'Content-Type': bodies[i].contentType,
                  'Cookie': cookie,
                  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                      'AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36'
                },
              }
          ],
        });
      });
    } catch (_) {
      if (!handedOff && artifactGroup != null) {
        await (await store).cleanupPreparations(draft.accountId,
            taskId: attemptId, groupId: artifactGroup);
      }
      rethrow;
    } finally {
      final done = _preparationDone;
      try {
        await _clearMarker();
      } finally {
        _preparationDone = null;
        _preparing = false;
        _preparationDraft = null;
        _preparationTask = null;
        _handedOffTask = null;
        _preparingGallery = null;
        done?.complete();
      }
    }
  }

  static Future<List<_PreparedUploadPart>> _bodies(
      String rootPath,
      List<PreparedUploadAsset> assets,
      Map<String, List<String>> fields,
      String batchId,
      String marker,
      SendPort spacePort) async {
    final root = Directory(rootPath);
    final active = File(marker);
    bool cancelled() => !active.existsSync();
    Future<int> space() => _queryWorkerSpace(spacePort);
    final batches = await const UploadBatchWriter().prepare(
        root: root,
        assets: assets,
        batchId: batchId,
        isCancelled: cancelled,
        availableBytes: space);
    final result = <_PreparedUploadPart>[];
    for (var i = 0; i < batches.length; i++) {
      final body = await prepareUploadBody(
          root: root,
          batch: batches[i],
          fields: fields,
          id: '$batchId-$i',
          groupId: batchId,
          isCancelled: cancelled,
          availableBytes: space);
      result.add(_PreparedUploadPart(
          body, batches[i].assets.map((a) => a.uploadName!).toList()));
    }
    return result;
  }

  Future<Map<String, dynamic>> transferSnapshot() async {
    final revision = cookies.sessionRevision;
    final account = await cookies.getMemberId();
    if (account == null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    final snapshot = await _nativeSnapshot(account, revision);
    await _check(account, revision);
    for (final task in snapshot['tasks'] as List? ?? []) {
      if (task is Map &&
          task['accountId'] == account &&
          {'completed', 'stopped'}.contains(task['state'])) {
        await (await store)
            .cleanupPreparations(account, taskId: task['taskId'] as String);
      }
    }
    final nativeIds = (snapshot['tasks'] as List)
        .whereType<Map>()
        .map((t) => t['taskId'])
        .toSet();
    final storage = await store;
    for (final group in await storage.preparationGroups(account)) {
      if (group['taskId'] == _preparationTask ||
          nativeIds.contains(group['taskId'])) continue;
      await storage.cleanupPreparations(account,
          taskId: group['taskId'], groupId: group['groupId']);
    }
    return snapshot;
  }

  Future<void> pauseTask(String id) => platform.pause(id);
  Future<void> resumeTask(String id) => platform.resume(id);
  Future<void> cancelTask(String id) async {
    final account = await cookies.getMemberId();
    if (account == null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    await platform.cancel(id);
    await (await store).cleanupPreparations(account, taskId: id);
  }

  Future<void> removeLocal(UploadDraft draft) async {
    if (_preparing && _preparationDraft == draft.id) {
      throw StateError(
          'Wait for file preparation to stop before removing this draft');
    }
    await _check(draft.accountId, cookies.sessionRevision);
    final snapshot = await transferSnapshot();
    final tasks = snapshot['tasks'] as List? ?? [];
    if (tasks.any((t) =>
        (t as Map)['draftId'] == draft.id &&
        _taskBlocks(t, snapshot['receipts'] as List))) {
      throw StateError(
          'Stop and reconcile the upload before removing local files');
    }
    final storage = await store;
    for (final attempt
        in await storage.attempts(draft.accountId, draftId: draft.id)) {
      await storage.cleanupPreparations(draft.accountId,
          taskId: attempt.taskId);
    }
    await storage.cleanupPreparations(draft.accountId, taskId: draft.id);
    await storage.removeLocal(draft.accountId, draft.id);
  }

  Future<PreparedUploadAction> prepareAdvanced(
      UploadDraft draft, UploadGalleryAction kind) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    if (_terminalDraft(draft) || draft.serverUri == null) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    final prepared =
        await advanced.prepare(draft.accountId, draft.serverUri!, kind);
    await _check(draft.accountId, revision);
    if (uploadGalleryId(prepared.editorUri) !=
        uploadGalleryId(draft.serverUri)) {
      throw const UploadFailure(UploadFailureKind.resultUncertain);
    }
    return prepared;
  }

  Future<UploadPublicationTermsConsent> acceptPublicationTerms(
      List<PreparedUploadAction> reviewed,
      {required bool confirmed}) async {
    final frozen = List<PreparedUploadAction>.unmodifiable(reviewed);
    if (!confirmed || frozen.isEmpty) {
      throw ArgumentError(
          'Explicit agreement to the reviewed publication terms is required');
    }
    final revision = cookies.sessionRevision;
    final account = frozen.first.accountId;
    await _check(account, revision);
    final targets = <String, PreparedUploadAction>{};
    for (final action in frozen) {
      final id = uploadGalleryId(action.editorUri);
      if (action.action != UploadGalleryAction.publish ||
          action.accountId != account ||
          action.revision != revision ||
          id == null ||
          targets.containsKey(id)) {
        throw ArgumentError(
            'Terms agreement must match one reviewed publication batch');
      }
      targets[id] = action;
    }
    return UploadPublicationTermsConsent._(
        account, revision, _publicationTermsIssuer, targets);
  }

  void _consumePublicationTerms(UploadPublicationTermsConsent consent,
      PreparedUploadAction prepared, String account, int? revision) {
    final id = uploadGalleryId(prepared.editorUri);
    if (prepared.action != UploadGalleryAction.publish ||
        !identical(consent._issuer, _publicationTermsIssuer) ||
        consent.accountId != account ||
        consent.sessionRevision != revision ||
        prepared.revision != revision ||
        id == null ||
        !identical(consent._reviewed[id], prepared) ||
        !consent._used.add(id)) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'Review the publication targets and agree to their terms again.');
    }
  }

  Future<UploadActionResult> performAdvanced(
          UploadDraft draft, PreparedUploadAction prepared,
          {required bool confirmed,
          UploadPublicationTermsConsent? publicationTerms}) =>
      _serializedRemoteAction(draft, () async {
        if (!confirmed ||
            prepared.accountId != draft.accountId ||
            uploadGalleryId(prepared.editorUri) !=
                uploadGalleryId(draft.serverUri)) {
          throw ArgumentError('Confirm the reviewed gallery action');
        }
        final revision = cookies.sessionRevision;
        final storage = await store;
        final current = await storage.draft(draft.accountId, draft.id);
        if (current == null || _terminalDraft(current)) {
          throw const UploadFailure(UploadFailureKind.restricted);
        }
        if (await storage.pendingWrite(draft.accountId, draft.id) != null) {
          throw const UploadFailure(UploadFailureKind.resultUncertain);
        }
        if ({UploadGalleryAction.publish, UploadGalleryAction.clone}
                .contains(prepared.action) &&
            !_sameUploadBaseline(current.fields, current.serverFields)) {
          throw StateError(
              'Save the local metadata before reviewing this action');
        }
        await _nativeSnapshot(draft.accountId, revision);
        if (prepared.action == UploadGalleryAction.publish &&
            (await pendingAssets(current)).isNotEmpty) {
          throw StateError(
              'Upload or remove the pending local images before publishing');
        }
        if (prepared.action == UploadGalleryAction.publish && current.dirty) {
          throw StateError('Save all local changes before publishing');
        }
        if (publicationTerms != null) {
          _consumePublicationTerms(
              publicationTerms, prepared, draft.accountId, revision);
        }
        if (prepared.action == UploadGalleryAction.publish &&
            prepared.editor.form.fields.containsKey('tos') &&
            current.fields['tos']?.contains('on') != true &&
            publicationTerms == null) {
          throw ArgumentError(
              'Explicit terms acceptance is required before publishing');
        }
        final context = <String, Object?>{
          'fingerprint': prepared.fingerprint,
          'actionUri': prepared.actionUri.toString(),
          'editorUri': prepared.editorUri.toString(),
          'galleryId': uploadGalleryId(prepared.editorUri),
          'publicUri':
              UploadAdvancedActions.publicGallery(prepared.editor)?.toString(),
          'beforeCanUpload': prepared.editor.canUpload,
        };
        final intent = _UploadWriteIntent(
            current.copyWith(fields: _businessFields(prepared.editor)),
            kind: prepared.action.name,
            context: context);
        final result = await runZoned(
            () => advanced.perform(draft.accountId, prepared, confirmed: true),
            zoneValues: {_writeIntentKey: intent});
        await _check(draft.accountId, revision);
        if (result.kind != prepared.action || intent.operationId == null) {
          throw const UploadFailure(UploadFailureKind.resultUncertain);
        }
        final localId = await _applyAdvancedResult(current, result);
        await storage.resolveWrite(
            draft.accountId, draft.id, intent.operationId!);
        return UploadActionResult(result.kind,
            editor: result.editor,
            manager: result.manager,
            publicUri: result.publicUri,
            localDraftId: localId);
      });

  Future<String> _applyAdvancedResult(
      UploadDraft draft, UploadActionResult result) async {
    final storage = await store;
    switch (result.kind) {
      case UploadGalleryAction.delete:
        await storage.markRemoteState(draft.accountId, draft.id, 'deleted');
        return draft.id;
      case UploadGalleryAction.disown:
        await storage.markRemoteState(draft.accountId, draft.id, 'disowned');
        return draft.id;
      case UploadGalleryAction.publish:
        if (result.editor == null) {
          throw const UploadFailure(UploadFailureKind.resultUncertain);
        }
        await storage.mergeRemote(
            draft, _businessFields(result.editor!), result.editor!.uri);
        await storage.markRemoteState(draft.accountId, draft.id, 'published');
        return draft.id;
      case UploadGalleryAction.clone:
        final editor = result.editor;
        if (editor == null) {
          throw const UploadFailure(UploadFailureKind.resultUncertain);
        }
        final existing = (await storage.drafts(draft.accountId))
            .where((d) =>
                d.parentDraftId == draft.id &&
                d.serverUri == editor.uri &&
                !_terminalDraft(d))
            .firstOrNull;
        if (existing == null) {
          final latest =
              await storage.draft(draft.accountId, draft.id) ?? draft;
          final remaining = await pendingAssets(latest);
          final assets = remaining
              .map((a) => PreparedUploadAsset(
                  relativePath: a.relativePath,
                  displayName: a.displayName,
                  size: a.size,
                  sha256: a.sha256,
                  crc32: a.crc32,
                  format: a.format,
                  width: a.width,
                  height: a.height,
                  animated: a.animated,
                  issues: a.issues))
              .toList();
          final fields = _businessFields(editor);
          final childFields = <String, List<String>>{...fields};
          for (final entry in latest.fields.entries) {
            if (entry.key == 'tos' ||
                !_sameFields({entry.key: entry.value},
                    {entry.key: draft.fields[entry.key] ?? []})) {
              childFields[entry.key] = entry.value;
            }
          }
          final child = await storage.save(UploadDraft(
              id: newUploadId(),
              accountId: draft.accountId,
              fields: childFields,
              serverFields: fields,
              serverUri: editor.uri,
              assets: assets,
              dirty: !_sameUploadBaseline(childFields, fields),
              parentDraftId: draft.id,
              parentGalleryUri: draft.serverUri));
          return child.id;
        }
        return existing.id;
    }
  }

  Future<UploadActionResult> reconcileAdvanced(UploadDraft draft,
      {Uri? selectedEditor, String? expectedOperationId}) async {
    final review = await prepareAdvancedRecovery(draft);
    if (expectedOperationId != null &&
        review.operationId != expectedOperationId) {
      throw StateError('The unresolved write changed. Review it again.');
    }
    if (selectedEditor != null && expectedOperationId == null) {
      throw StateError(
          'Review the original operation before selecting its result');
    }
    final result = await resolveAdvancedRecovery(draft, review,
        selectedEditor: selectedEditor, confirmedNoEffect: false);
    if (result == null) {
      throw const UploadFailure(UploadFailureKind.resultUncertain);
    }
    return result;
  }

  Future<UploadAdvancedRecovery> prepareAdvancedRecovery(UploadDraft draft) =>
      _serializedRemoteAction(draft, () => _inspectAdvancedRecovery(draft));

  Future<UploadAdvancedRecovery> _inspectAdvancedRecovery(UploadDraft draft,
      {String? expectedOperationId}) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    if (_webHandoff || _webPreparing) {
      throw StateError('Close the website manager before reviewing its result');
    }
    final pending = await (await store).pendingWrite(draft.accountId, draft.id);
    if (pending == null || pending.serverUri == null) {
      throw StateError('No unresolved gallery action');
    }
    if (expectedOperationId != null) {
      _requireReviewedWrite(pending, expectedOperationId);
    }
    final name = pending.kind == 'unlock' ? 'clone' : pending.kind;
    final kind =
        UploadGalleryAction.values.where((a) => a.name == name).firstOrNull;
    if (kind == null) {
      throw StateError('Reconcile this write using its save workflow');
    }
    final original = pending.serverUri!;
    final originalId = uploadGalleryId(original);
    if (originalId == null) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    UploadAdvancedRecovery review(
            {UploadEditorSnapshot? editor,
            List<UploadEditorSnapshot> candidates = const [],
            UploadActionResult? result,
            bool noEffect = false}) =>
        UploadAdvancedRecovery._(
            accountId: draft.accountId,
            draftId: draft.id,
            operationId: pending.operationId,
            sessionRevision: revision,
            kind: kind,
            editor: editor,
            candidates: candidates,
            confirmedResult: result,
            canMarkNoEffect: noEffect);

    if (kind == UploadGalleryAction.publish) {
      final editor = await repository.editor(draft.accountId, original);
      await _checkRecoveryEditor(draft.accountId, revision, original, editor);
      final public = UploadAdvancedActions.publicGallery(editor);
      if (!UploadAdvancedActions.unpublished(editor) && public != null) {
        return review(
            editor: editor,
            result:
                UploadActionResult(kind, editor: editor, publicUri: public));
      }
      return review(
          editor: editor,
          noEffect:
              UploadAdvancedActions.unpublished(editor) && editor.canPublish);
    }

    final manager = await repository.manager(draft.accountId);
    await _check(draft.accountId, revision);
    if (manager.api.uid.toString() != draft.accountId) {
      throw const UploadFailure(UploadFailureKind.sessionChanged);
    }
    final rows = [...manager.galleries];
    for (final folder in manager.folders) {
      if (!folder.collapsed) continue;
      final children =
          await repository.folder(draft.accountId, manager, folder);
      await _check(draft.accountId, revision);
      if (folder.galleryCount == null ||
          children.length != folder.galleryCount) {
        throw const UploadFailure(UploadFailureKind.resultUncertain,
            serverMessage:
                'The complete managed-gallery list could not be verified.');
      }
      rows.addAll(children);
    }
    final targets =
        rows.where((g) => uploadGalleryId(g.managementUri) == originalId);
    if (kind == UploadGalleryAction.delete ||
        kind == UploadGalleryAction.disown) {
      if (targets.isEmpty) {
        final public =
            Uri.tryParse(pending.context['publicUri'] as String? ?? '');
        return review(
            result: UploadActionResult(kind,
                manager: manager,
                publicUri: public?.hasScheme == true ? public : null));
      }
      final editor = await repository.editor(draft.accountId, original);
      await _checkRecoveryEditor(draft.accountId, revision, original, editor);
      return review(editor: editor, noEffect: _ownerCanEdit(editor));
    }

    if (targets.isEmpty) return review();
    final parent = await repository.editor(draft.accountId, original);
    await _checkRecoveryEditor(draft.accountId, revision, original, parent);
    if (pending.context['beforeCanUpload'] != false) {
      return review(editor: parent);
    }
    if (parent.canUpload) {
      return review(
          editor: parent, result: UploadActionResult(kind, editor: parent));
    }
    final candidates = <UploadEditorSnapshot>[];
    final visited = <String>{originalId};
    for (final gallery in rows) {
      final uri = gallery.managementUri;
      final id = uploadGalleryId(uri);
      // A row without a readable owner page cannot be ruled out as a child.
      if (id == null || uri == null) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      if (!visited.add(id)) continue;
      final candidate = await _readChildCandidate(draft.accountId, revision,
          uri, original, pending.context['publicUri'] as String?);
      if (candidate != null) candidates.add(candidate);
    }
    await _check(draft.accountId, revision);
    return review(
        editor: parent,
        candidates: candidates,
        noEffect:
            candidates.isEmpty && !parent.canUpload && _ownerCanEdit(parent));
  }

  bool _ownerCanEdit(UploadEditorSnapshot editor) =>
      editor.buttons['savebutton']?.enabled == true ||
      editor.buttons['savechanges']?.enabled == true ||
      editor.form.fields.values.any((field) =>
          field.name == 'ulcomment' && !field.disabled && !field.readOnly);

  Future<void> _checkRecoveryEditor(String account, int? revision,
      Uri requested, UploadEditorSnapshot editor) async {
    await _check(account, revision);
    if (editor.api.uid.toString() != account ||
        uploadGalleryId(editor.uri) != uploadGalleryId(requested)) {
      throw const UploadFailure(UploadFailureKind.resultUncertain);
    }
  }

  Future<UploadEditorSnapshot?> _readChildCandidate(
      String account,
      int? revision,
      Uri selected,
      Uri original,
      String? previousPublicValue) async {
    requireUploadUri(selected);
    if (uploadGalleryId(selected) == null ||
        selected.queryParameters.containsKey('act')) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    final response = await repository.client.get(selected);
    final editor = repository.protocol.editor(response.body, response.uri);
    await _checkRecoveryEditor(account, revision, selected, editor);
    final previousPublic = Uri.tryParse(previousPublicValue ?? '');
    final doc = repository.protocol.document(response.body);
    final links = doc
        .querySelectorAll('td#d tr')
        .where((row) =>
            row
                .querySelector('td.k')
                ?.text
                .trim()
                .toLowerCase()
                .replaceAll(RegExp(r':$'), '') ==
            'parent gallery')
        .expand((row) => row.querySelectorAll('td.v a[href]'))
        .map((a) => response.uri.resolve(a.attributes['href']!));
    final linked = links.any((uri) =>
        uploadGalleryId(uri) == uploadGalleryId(original) ||
        (previousPublic?.hasScheme == true && uri == previousPublic));
    return linked ? editor : null;
  }

  /// Returns null only for an explicit manual no-effect resolution. This does
  /// not assert that the server never executed the request and never resends it.
  Future<UploadActionResult?> resolveAdvancedRecovery(
          UploadDraft draft, UploadAdvancedRecovery review,
          {Uri? selectedEditor, required bool confirmedNoEffect}) =>
      _serializedRemoteAction(draft, () async {
        if (review.accountId != draft.accountId ||
            review.draftId != draft.id ||
            review.sessionRevision != cookies.sessionRevision) {
          throw const UploadFailure(UploadFailureKind.sessionChanged);
        }
        final fresh = await _inspectAdvancedRecovery(draft,
            expectedOperationId: review.operationId);
        var result = fresh.confirmedResult;
        if (selectedEditor != null) {
          if (fresh.kind != UploadGalleryAction.clone ||
              !review.candidates.any((e) => e.uri == selectedEditor)) {
            throw StateError(
                'Select a child from the reviewed parent-linked candidates');
          }
          final child = fresh.candidates
              .where((e) => e.uri == selectedEditor)
              .firstOrNull;
          if (child == null) {
            throw const UploadFailure(UploadFailureKind.resultUncertain);
          }
          result = UploadActionResult(UploadGalleryAction.clone, editor: child);
        }
        final storage = await store;
        await _check(draft.accountId, review.sessionRevision);
        if (result != null) {
          final localId = await _applyAdvancedResult(draft, result);
          await storage.resolveWrite(
              draft.accountId, draft.id, review.operationId,
              outcome: 'current_state_confirmed');
          return UploadActionResult(result.kind,
              editor: result.editor,
              manager: result.manager,
              publicUri: result.publicUri,
              localDraftId: localId);
        }
        if (!confirmedNoEffect ||
            !review.canMarkNoEffect ||
            !fresh.canMarkNoEffect ||
            fresh.candidates.isNotEmpty) {
          throw const UploadFailure(UploadFailureKind.resultUncertain,
              serverMessage:
                  'Review the current result before resolving this operation.');
        }
        await storage.resolveWrite(
            draft.accountId, draft.id, review.operationId,
            outcome: 'manual_no_effect');
        return null;
      });

  Future<UploadStatsSnapshot> statistics(UploadDraft draft) async {
    final revision = cookies.sessionRevision;
    await _check(draft.accountId, revision);
    if (draft.serverUri == null || _terminalDraft(draft)) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    final value = await advanced.stats(draft.accountId, draft.serverUri!);
    await _check(draft.accountId, revision);
    return value;
  }

  // Legacy entry remains fail-closed; the UI must review prepareAdvanced's
  // fresh snapshot before explicitly calling performAdvanced.
  bool get supportsNativePublication => true;
  bool get publicationProtocolVerified => supportsNativePublication;
  Future<UploadEditingSession> publish(UploadDraft draft) =>
      Future.error(const UploadFailure(UploadFailureKind.protocolChanged));
  Future<void> openExternal(Uri uri) async {
    if (uri.host == uploadOrigin.host) {
      throw StateError(
          'Use the in-app website manager so uploads remain protected until it closes');
    }
    await platform.openExternal(uri);
  }

  Future<int> prepareWebHandoff({UploadDraft? draft}) async {
    if (_webHandoff || _webPreparing) {
      throw StateError('The website manager is already open');
    }
    final generation = ++_webGeneration;
    _webPreparing = true;
    try {
      await _prepareWebHandoff(generation, draft: draft);
      await _remoteWrites;
      await repository.exclusiveWrite(() async {
        if (generation != _webGeneration) {
          throw StateError('The website manager was closed');
        }
        _webHandoff = true;
      });
      return generation;
    } finally {
      if (generation == _webGeneration) _webPreparing = false;
    }
  }

  Future<void> _prepareWebHandoff(int generation, {UploadDraft? draft}) async {
    final revision = cookies.sessionRevision;
    final account = await cookies.getMemberId();
    if (account == null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    await _check(account, revision);
    await cancelPreparation();
    final state = await transferSnapshot();
    if (generation != _webGeneration) {
      throw StateError('The website manager was closed');
    }
    final related = (state['tasks'] as List)
        .whereType<Map>()
        .where((task) =>
            draft == null ||
            task['draftId'] == draft.id ||
            uploadGalleryId(Uri.tryParse(task['serverUri'] as String? ?? '')) ==
                uploadGalleryId(draft.serverUri))
        .toList();
    if ((state['tasks'] as List).whereType<Map>().any((task) =>
        !related.any((r) => r['taskId'] == task['taskId']) &&
        _taskBlocks(task, state['receipts'] as List))) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'Another gallery is uploading. Finish or stop it before opening the website manager.');
    }
    for (final task in related) {
      if (generation != _webGeneration) {
        throw StateError('The website manager was closed');
      }
      if ((state['receipts'] as List).whereType<Map>().any((r) =>
              r['taskId'] == task['taskId'] && r['acknowledged'] != true) ||
          task['reconciliationRequired'] == true) {
        throw const UploadFailure(UploadFailureKind.resultUncertain,
            serverMessage:
                'Review unresolved uploads before editing this gallery on the website.');
      }
      if (!{'completed', 'stopped'}.contains(task['state'])) {
        await platform.cancel(task['taskId'] as String);
      }
    }
    final after = await transferSnapshot();
    for (final task in (after['tasks'] as List).whereType<Map>()) {
      if (related.any((r) => r['taskId'] == task['taskId']) &&
          _taskBlocks(task, after['receipts'] as List)) {
        throw const UploadFailure(UploadFailureKind.resultUncertain,
            serverMessage:
                'The stopped upload may have reached the site. Review it before opening the website.');
      }
    }
    await _check(account, revision);
  }

  Future<void> endWebHandoff({int? generation}) async {
    if (generation != null && generation != _webGeneration) return;
    _webGeneration++;
    _webHandoff = false;
    _webPreparing = false;
  }

  Future<UploadEditingSession> finishWebHandoff(UploadDraft draft,
      {int? generation}) async {
    try {
      if (generation != null && generation != _webGeneration) {
        throw StateError('This website session has ended');
      }
      return await openDraft(draft.accountId, draft.id);
    } finally {
      await endWebHandoff(generation: generation);
    }
  }

  Future<void> invalidateSession() async {
    _invalidating = true;
    try {
      await endWebHandoff();
      repository.client.cancelActive();
      await _identityWrites;
      // A cold start can still have OS-owned uploads even before this route opens.
      final storage = await store;
      var identity = await storage.session();
      if (identity != null) await platform.invalidateSession(identity.epoch);
      await cancelPreparation();
      final latest = await storage.session();
      if (latest != null && latest.epoch != identity?.epoch) {
        await platform.invalidateSession(latest.epoch);
      }
      if (identity != null) {
        await storage.cleanupPreparations(identity.accountId);
      }
      if (latest != null && latest.accountId != identity?.accountId) {
        await storage.cleanupPreparations(latest.accountId);
      }
      await storage.clearSession();
    } finally {
      _invalidating = false;
    }
  }

  static int _remoteBytesLowerBound(String? text) {
    if (text == null || text == '(empty)') return 0;
    final match =
        RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*(B|KiB|MiB|GiB)$').firstMatch(text);
    if (match == null) return 0; // Unknown precision remains server-validated.
    final units = {'B': 1, 'KiB': 1024, 'MiB': 1048576, 'GiB': 1073741824};
    final value = double.parse(match[1]!);
    final lower = value - (match[1]!.contains('.') ? 0.1 : 1);
    return lower <= 0 ? 0 : (lower * units[match[2]]!).floor();
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancelPreparation();
    repository.client.dispose();
    if (_store != null) await (await _store!).close();
  }

  bool _terminalDraft(UploadDraft draft) =>
      {'deleted', 'disowned'}.contains(draft.remoteState);

  UploadEditingSession _localSession(UploadDraft draft) => UploadEditingSession(
      draft,
      UploadEditorSnapshot(
          uri: draft.serverUri ?? uploadOrigin.resolve('manage'),
          form: UploadForm(
              action: draft.serverUri ?? uploadOrigin.resolve('manage'),
              fields: {
                for (final field in draft.fields.entries)
                  field.key: UploadField(
                      name: field.key,
                      type: field.key == 'ulcomment' ? 'textarea' : 'text',
                      values: field.value,
                      readOnly: true),
              }),
          api: UploadApiSession(int.tryParse(draft.accountId) ?? 0, ''),
          buttons: const {},
          images: const [],
          metadata: {'Local only': draft.remoteState ?? ''},
          links: const {}),
      localOnly: true);
}

bool _sameAssets(List<PreparedUploadAsset> a, List<PreparedUploadAsset> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (uploadAssetKey(a[i]) != uploadAssetKey(b[i])) return false;
  }
  return true;
}

bool _sameFields(Map<String, List<String>> a, Map<String, List<String>> b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    final left = a[key]!;
    final right = b[key];
    if (right == null || left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
  }
  return true;
}

bool _sameUploadBaseline(
    Map<String, List<String>> a, Map<String, List<String>> b) {
  const ephemeral = {'PHP_SESSION_UPLOAD_PROGRESS', 'tos'};
  return _sameFields({
    for (final e in a.entries)
      if (!ephemeral.contains(e.key)) e.key: e.value
  }, {
    for (final e in b.entries)
      if (!ephemeral.contains(e.key)) e.key: e.value
  });
}

bool _sameRemoteImages(List<RemoteUploadImage> a, List<RemoteUploadImage> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].fileIndex != b[i].fileIndex ||
        a[i].name != b[i].name ||
        a[i].position != b[i].position) return false;
  }
  return true;
}
