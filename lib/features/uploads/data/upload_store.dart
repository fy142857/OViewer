import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../files/upload_asset.dart';
import '../files/upload_file_io.dart';
import 'upload_protocol.dart';

const uploadEditableFields = {
  'gname_en',
  'gname_jp',
  'category',
  'aigen',
  'langtag',
  'langtype',
  'langctl',
  'folderid',
  'foldername',
  'ulcomment',
  'tos',
};

String newUploadId() =>
    base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');

class UploadDraft {
  final String id;
  final String accountId;
  final Map<String, List<String>> fields;
  final Map<String, List<String>> serverFields;
  final List<PreparedUploadAsset> assets;
  final Uri? serverUri;
  final bool dirty;
  final int revision;
  final String? remoteState;
  final String? parentDraftId;
  final Uri? parentGalleryUri;
  final DateTime updatedAt;
  UploadDraft(
      {required this.id,
      required this.accountId,
      required Map<String, List<String>> fields,
      Map<String, List<String>> serverFields = const {},
      required List<PreparedUploadAsset> assets,
      this.serverUri,
      this.dirty = true,
      this.revision = 0,
      this.remoteState,
      this.parentDraftId,
      this.parentGalleryUri,
      DateTime? updatedAt})
      : serverFields = Map.unmodifiable(serverFields
            .map((k, v) => MapEntry(k, List<String>.unmodifiable(v)))),
        fields = Map.unmodifiable(
            fields.map((k, v) => MapEntry(k, List<String>.unmodifiable(v)))),
        assets = List.unmodifiable(assets),
        updatedAt = updatedAt ?? DateTime.now() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id) ||
        accountId.isEmpty ||
        [...fields.keys, ...serverFields.keys]
            .any((name) => !uploadEditableFields.contains(name))) {
      throw ArgumentError('Invalid upload draft identity or fields');
    }
    if (serverUri != null) requireUploadUri(serverUri!);
    if (parentGalleryUri != null) requireUploadUri(parentGalleryUri!);
    if (remoteState != null &&
        !{'published', 'deleted', 'disowned'}.contains(remoteState)) {
      throw ArgumentError('Invalid remote gallery state');
    }
    if (parentDraftId != null &&
        !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(parentDraftId!)) {
      throw ArgumentError('Invalid parent draft');
    }
    for (final asset in assets) {
      uploadPathParts(asset.relativePath);
    }
  }

  String get title => fields['gname_en']?.firstOrNull ?? '';

  UploadDraft copyWith(
          {Map<String, List<String>>? fields,
          Map<String, List<String>>? serverFields,
          List<PreparedUploadAsset>? assets,
          Uri? serverUri,
          bool? dirty,
          int? revision,
          String? remoteState,
          bool clearRemoteState = false,
          String? parentDraftId,
          Uri? parentGalleryUri}) =>
      UploadDraft(
          id: id,
          accountId: accountId,
          fields: fields ?? this.fields,
          serverFields: serverFields ?? this.serverFields,
          assets: assets ?? this.assets,
          serverUri: serverUri ?? this.serverUri,
          dirty: dirty ?? this.dirty,
          revision: revision ?? this.revision,
          remoteState:
              clearRemoteState ? null : remoteState ?? this.remoteState,
          parentDraftId: parentDraftId ?? this.parentDraftId,
          parentGalleryUri: parentGalleryUri ?? this.parentGalleryUri);

  Map<String, Object?> toJson() => {
        'schema': 1,
        'id': id,
        'accountId': accountId,
        'fields': fields,
        'serverFields': serverFields,
        'serverUri': serverUri?.toString(),
        'dirty': dirty,
        'revision': revision,
        'remoteState': remoteState,
        'parentDraftId': parentDraftId,
        'parentGalleryUri': parentGalleryUri?.toString(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'assets': assets
            .map((a) => {
                  'path': a.relativePath,
                  'name': a.displayName,
                  'bytes': a.size,
                  'sha256': a.sha256,
                  'crc32': a.crc32,
                  'format': a.format?.name,
                  'width': a.width,
                  'height': a.height,
                  'animated': a.animated,
                  'uploadName': a.uploadName,
                  'issues': a.issues
                      .map((issue) => {
                            'code': issue.code,
                            'severity': issue.severity.name,
                            'displayName': issue.displayName,
                            'limit': issue.limit,
                            'actual': issue.actual,
                          })
                      .toList(),
                })
            .toList(),
      };

  factory UploadDraft.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported upload draft');
    }
    return UploadDraft(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        fields: (json['fields'] as Map)
            .map((k, v) => MapEntry(k as String, (v as List).cast<String>())),
        serverFields: ((json['serverFields'] as Map?) ?? {})
            .map((k, v) => MapEntry(k as String, (v as List).cast<String>())),
        serverUri: json['serverUri'] == null
            ? null
            : Uri.parse(json['serverUri'] as String),
        dirty: json['dirty'] as bool,
        revision: json['revision'] as int? ?? 0,
        remoteState: json['remoteState'] as String?,
        parentDraftId: json['parentDraftId'] as String?,
        parentGalleryUri: json['parentGalleryUri'] == null
            ? null
            : Uri.parse(json['parentGalleryUri'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        assets: (json['assets'] as List).map((raw) {
          final a = Map<String, dynamic>.from(raw as Map);
          final format = a['format'] == null
              ? null
              : UploadImageFormat.values
                  .firstWhere((format) => format.name == a['format']);
          return PreparedUploadAsset(
              relativePath: a['path'] as String,
              displayName: a['name'] as String,
              size: a['bytes'] as int,
              sha256: a['sha256'] as String,
              crc32: a['crc32'] as int,
              format: format,
              width: a['width'] as int?,
              height: a['height'] as int?,
              animated: a['animated'] as bool,
              uploadName: a['uploadName'] as String?,
              issues: (a['issues'] as List).map((raw) {
                final issue = Map<String, dynamic>.from(raw as Map);
                return ValidationIssue(issue['code'] as String,
                    severity: UploadIssueSeverity.values
                        .firstWhere((e) => e.name == issue['severity']),
                    displayName: issue['displayName'] as String?,
                    limit: issue['limit'] as int?,
                    actual: issue['actual'] as int?);
              }).toList());
        }).toList());
  }
}

/// An independent schema: no migration of reader, history or offline tables.
class UploadDatabase extends GeneratedDatabase {
  UploadDatabase(super.executor);
  @override
  int get schemaVersion => 7;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (_) async {
        await customStatement('CREATE TABLE upload_drafts ('
            'account_id TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, '
            'updated_at INTEGER NOT NULL, PRIMARY KEY(account_id,id))');
        await customStatement('CREATE TABLE upload_session ('
            'singleton INTEGER PRIMARY KEY CHECK(singleton=1), '
            'account_id TEXT NOT NULL, epoch TEXT NOT NULL)');
        await _createArtifacts();
        await _createAttempts();
        await _createPendingWrites();
        await _createWriteHistory();
      }, onUpgrade: (_, from, to) async {
        if (from < 2) await _createArtifacts();
        if (from < 3) await _createAttempts();
        if (from < 4) await _createPendingWrites();
        if (from >= 4 && from < 5) {
          await customStatement(
              "ALTER TABLE upload_pending_writes ADD COLUMN context TEXT NOT NULL DEFAULT '{}'");
        }
        if (from < 6) await _createWriteHistory();
        if (from >= 3 && from < 7) {
          await customStatement(
              'ALTER TABLE upload_confirmed_assets ADD COLUMN occurrence TEXT');
        }
      });

  Future<void> _createArtifacts() => customStatement(
      'CREATE TABLE upload_artifacts ('
      'account_id TEXT NOT NULL, task_id TEXT NOT NULL, group_id TEXT NOT NULL, '
      'PRIMARY KEY(account_id,task_id,group_id))');

  Future<void> _createAttempts() async {
    await customStatement('CREATE TABLE upload_attempts ('
        'account_id TEXT NOT NULL, task_id TEXT NOT NULL, draft_id TEXT NOT NULL, '
        'payload TEXT NOT NULL, PRIMARY KEY(account_id,task_id))');
    await customStatement('CREATE TABLE upload_confirmed_assets ('
        'account_id TEXT NOT NULL, draft_id TEXT NOT NULL, gallery_id TEXT NOT NULL, '
        'asset_key TEXT NOT NULL, upload_name TEXT NOT NULL, file_index INTEGER NOT NULL, '
        'receipt_id TEXT NOT NULL, occurrence TEXT, PRIMARY KEY(account_id,draft_id,gallery_id,asset_key))');
  }

  Future<void> _createPendingWrites() => customStatement(
      'CREATE TABLE upload_pending_writes ('
      'account_id TEXT NOT NULL, draft_id TEXT NOT NULL, operation_id TEXT NOT NULL, '
      "kind TEXT NOT NULL, server_uri TEXT, fields TEXT NOT NULL, context TEXT NOT NULL DEFAULT '{}', "
      'PRIMARY KEY(account_id,draft_id))');

  Future<void> _createWriteHistory() => customStatement(
      'CREATE TABLE upload_write_history ('
      'account_id TEXT NOT NULL, draft_id TEXT NOT NULL, operation_id TEXT NOT NULL, '
      'kind TEXT NOT NULL, server_uri TEXT, outcome TEXT NOT NULL, resolved_at INTEGER NOT NULL, '
      'PRIMARY KEY(account_id,operation_id))');
}

String uploadAssetKey(PreparedUploadAsset asset) =>
    jsonEncode([asset.relativePath, asset.sha256, asset.uploadName]);

String? uploadGalleryId(Uri? uri) {
  if (uri == null || !isUploadUri(uri) || uri.path != '/managegallery') {
    return null;
  }
  final values = uri.queryParametersAll['ulgid'];
  return values?.length == 1 &&
          RegExp(r'^[1-9][0-9]*$').hasMatch(values!.single)
      ? values.single
      : null;
}

class UploadAttemptAsset {
  final String itemId;
  final String relativePath;
  final String sha256;
  final String uploadName;
  const UploadAttemptAsset(
      this.itemId, this.relativePath, this.sha256, this.uploadName);
  String get key => jsonEncode([relativePath, sha256, uploadName]);
  Map<String, String> toJson() => {
        'itemId': itemId,
        'path': relativePath,
        'sha256': sha256,
        'name': uploadName
      };
  factory UploadAttemptAsset.fromJson(Map<String, dynamic> value) {
    final result = UploadAttemptAsset(
        value['itemId'] as String,
        value['path'] as String,
        value['sha256'] as String,
        value['name'] as String);
    uploadPathParts(result.relativePath);
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(result.itemId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(result.sha256) ||
        !RegExp(r'^[A-Za-z0-9_-]+\.(jpg|png|gif|webp)$')
            .hasMatch(result.uploadName)) {
      throw const FormatException('Invalid upload attempt asset');
    }
    return result;
  }
}

class UploadAttempt {
  final String accountId;
  final String taskId;
  final String draftId;
  final String groupId;
  final Uri serverUri;
  final List<UploadAttemptAsset> assets;
  UploadAttempt(
      {required this.accountId,
      required this.taskId,
      required this.draftId,
      required this.groupId,
      required this.serverUri,
      required List<UploadAttemptAsset> assets})
      : assets = List.unmodifiable(assets) {
    if (accountId.isEmpty ||
        [taskId, draftId, groupId]
            .any((id) => !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) ||
        uploadGalleryId(serverUri) == null ||
        assets.isEmpty ||
        assets.length > UploadFileLimits.maxImages ||
        assets.map((a) => a.uploadName).toSet().length != assets.length) {
      throw const FormatException('Invalid upload attempt');
    }
    for (final asset in assets) {
      UploadAttemptAsset.fromJson(asset.toJson());
    }
  }
  Map<String, Object?> toJson() => {
        'schema': 1,
        'accountId': accountId,
        'taskId': taskId,
        'draftId': draftId,
        'groupId': groupId,
        'serverUri': serverUri.toString(),
        'assets': assets.map((a) => a.toJson()).toList()
      };
  factory UploadAttempt.fromJson(Map<String, dynamic> value) {
    if (value['schema'] != 1) {
      throw const FormatException('Unknown upload attempt');
    }
    return UploadAttempt(
        accountId: value['accountId'] as String,
        taskId: value['taskId'] as String,
        draftId: value['draftId'] as String,
        groupId: value['groupId'] as String,
        serverUri: Uri.parse(value['serverUri'] as String),
        assets: (value['assets'] as List)
            .map((a) => UploadAttemptAsset.fromJson(
                Map<String, dynamic>.from(a as Map)))
            .toList());
  }
}

class ConfirmedUploadAsset {
  final String assetKey;
  final String uploadName;
  final int fileIndex;
  final String receiptId;
  final RemoteUploadImage? occurrence;
  const ConfirmedUploadAsset(
      this.assetKey, this.uploadName, this.fileIndex, this.receiptId,
      {this.occurrence});
}

class PendingUploadWrite {
  final String operationId;
  final String kind;
  final Uri? serverUri;
  final Map<String, List<String>> fields;
  final Map<String, Object?> context;
  const PendingUploadWrite(
      this.operationId, this.kind, this.serverUri, this.fields,
      {this.context = const {}});
}

class ResolvedUploadWrite {
  final String operationId;
  final String kind;
  final Uri? serverUri;
  final String outcome;
  const ResolvedUploadWrite(
      this.operationId, this.kind, this.serverUri, this.outcome);
}

class UploadSessionIdentity {
  final String accountId;
  final String epoch;
  const UploadSessionIdentity(this.accountId, this.epoch);
}

class UploadStore {
  final UploadDatabase database;
  final Directory root;
  final _changes = StreamController<void>.broadcast();
  Future<void> _writes = Future<void>.value();
  Future<void>? _initialized;
  Stream<void> get changes => _changes.stream;
  UploadStore(this.database, this.root);

  /// Must finish before opening any native picker. At cold start no importer
  /// owns live files yet, so only unreferenced generated copies can be removed.
  Future<void> initialize() => _initialized ??=
          cleanupOrphanImports().catchError((Object error, StackTrace stack) {
        _initialized = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _writes.then((_) => operation());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  static Future<UploadStore> open() async {
    final documents = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(documents.path, 'uploads'));
    await root.create(recursive: true);
    return UploadStore(
        UploadDatabase(NativeDatabase.createInBackground(
            File(p.join(root.path, 'uploads.sqlite')))),
        root);
  }

  Future<UploadDraft> save(UploadDraft value) => _serial(() async {
        final current = await draft(value.accountId, value.id);
        return _persist(value.copyWith(revision: (current?.revision ?? 0) + 1));
      });

  Future<UploadDraft> _persist(UploadDraft draft) async {
    await database.customStatement(
        'INSERT INTO upload_drafts '
        '(account_id,id,payload,updated_at) VALUES (?,?,?,?) '
        'ON CONFLICT(account_id,id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at',
        [
          draft.accountId,
          draft.id,
          jsonEncode(draft.toJson()),
          draft.updatedAt.millisecondsSinceEpoch
        ]);
    _changes.add(null);
    return draft;
  }

  /// Local edits keep the latest server acknowledgement/URI. An editor that
  /// predates a newer unsaved local edit cannot silently overwrite that edit.
  Future<UploadDraft> saveLocalEdits(UploadDraft value) => _serial(() async {
        final current = await draft(value.accountId, value.id);
        if (current == null) throw StateError('Upload draft no longer exists');
        // A UI snapshot captured before preparation must not erase a frozen
        // filename and thereby make an accepted source copy look new again.
        value = value.copyWith(
            assets: value.assets.map((asset) {
          final matches = current.assets
              .where((saved) =>
                  saved.relativePath == asset.relativePath &&
                  saved.sha256 == asset.sha256)
              .toList();
          return matches.length == 1
              ? _withUploadName(asset, matches.single.uploadName)
              : asset;
        }).toList());
        if (_sameFieldMap(value.fields, current.fields) &&
            _sameAssetList(value.assets, current.assets)) {
          return current;
        }
        if (value.revision != current.revision && current.dirty) {
          for (final field in value.fields.keys) {
            if (!_sameValues(value.fields[field], current.fields[field]) &&
                !_sameValues(
                    current.fields[field], value.serverFields[field]) &&
                !_sameValues(
                    current.fields[field], current.serverFields[field])) {
              throw StateError(
                  'This draft was edited in another page. Reopen it before saving.');
            }
          }
        }
        return _persist(value.copyWith(
            serverFields: current.serverFields,
            serverUri: current.serverUri,
            remoteState: current.remoteState,
            parentDraftId: current.parentDraftId,
            parentGalleryUri: current.parentGalleryUri,
            revision: current.revision + 1));
      });

  Future<UploadDraft> replaceAsset(String accountId, String id,
          PreparedUploadAsset original, PreparedUploadAsset replacement) =>
      _serial(() async {
        final current = await draft(accountId, id);
        if (current == null) throw StateError('Upload draft no longer exists');
        final assets = List<PreparedUploadAsset>.of(current.assets);
        final index = assets
            .indexWhere((a) => uploadAssetKey(a) == uploadAssetKey(original));
        if (index < 0) {
          throw StateError('The selected image is no longer in this draft');
        }
        assets[index] = replacement;
        return _persist(current.copyWith(
            assets: assets, dirty: true, revision: current.revision + 1));
      });

  Future<UploadDraft> appendAssets(
          String accountId, String id, List<PreparedUploadAsset> assets) =>
      _serial(() async {
        final current = await draft(accountId, id);
        if (current == null) throw StateError('Upload draft no longer exists');
        return _persist(current.copyWith(
            assets: [...current.assets, ...assets],
            dirty: true,
            revision: current.revision + 1));
      });

  /// A slow server reply updates the saved baseline but merges, rather than
  /// replacing, edits/imports committed while the request was in flight.
  Future<UploadDraft> mergeRemote(UploadDraft submitted,
          Map<String, List<String>> serverFields, Uri serverUri,
          {bool refreshOnly = false, bool preserveLocal = false}) =>
      _serial(() async {
        final current = await draft(submitted.accountId, submitted.id);
        if (current == null) throw StateError('Upload draft no longer exists');
        if (refreshOnly && current.dirty) return current;
        final fields = <String, List<String>>{};
        for (final name in {...serverFields.keys, ...current.fields.keys}) {
          if (name == 'tos') {
            if (current.fields.containsKey(name)) {
              fields[name] = List.of(current.fields[name]!);
            }
            continue;
          }
          if (preserveLocal && current.fields.containsKey(name)) {
            fields[name] = List.of(current.fields[name]!);
            continue;
          }
          final unchanged =
              _sameValues(current.fields[name], submitted.fields[name]);
          if (unchanged && (!refreshOnly || !current.dirty)) {
            if (serverFields.containsKey(name)) {
              fields[name] = List.of(serverFields[name]!);
            }
          } else if (current.fields.containsKey(name)) {
            fields[name] = List.of(current.fields[name]!);
          }
        }
        final dirty = fields.keys
                .where((key) => key != 'tos')
                .any((key) => !_sameValues(fields[key], serverFields[key])) ||
            serverFields.keys
                .where((key) => key != 'tos')
                .any((key) => !_sameValues(fields[key], serverFields[key]));
        return _persist(current.copyWith(
            fields: fields,
            serverFields: serverFields,
            serverUri: serverUri,
            dirty: dirty,
            revision: current.revision + 1));
      });

  Future<void> cleanupOrphanImports() => _serial(() async {
        final rows = await database
            .customSelect('SELECT payload FROM upload_drafts')
            .get();
        final referenced = <String>{};
        // A corrupt record fails closed before touching any file.
        for (final row in rows) {
          final saved = UploadDraft.fromJson(
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>);
          referenced.addAll(
              saved.assets.map((a) => a.relativePath.replaceAll('\\', '/')));
        }
        final imports = await resolveUploadFile(root, 'imports');
        if (await FileSystemEntity.type(imports.path, followLinks: false) ==
            FileSystemEntityType.notFound) return;
        if (await FileSystemEntity.type(imports.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw const UploadFileException('unsafe_path');
        }
        final groupPattern = RegExp(
            r'^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9_-]{32})$',
            caseSensitive: false);
        final filePattern = RegExp(
            r'^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{1,12}(?:\.part)?|[0-9]{4}\.image|converted\.png(?:\.part)?)$',
            caseSensitive: false);
        await for (final group
            in Directory(imports.path).list(followLinks: false)) {
          final id = p.basename(group.path);
          if (!groupPattern.hasMatch(id) || group is! Directory) continue;
          final safe = await resolveUploadFile(root, 'imports/$id');
          await for (final entity
              in Directory(safe.path).list(followLinks: false)) {
            final name = p.basename(entity.path);
            final relative = 'imports/$id/$name';
            if (entity is! File ||
                !filePattern.hasMatch(name) ||
                referenced.contains(relative)) continue;
            final file = await resolveUploadFile(root, relative);
            await file.delete();
          }
          if (await Directory(safe.path).list(followLinks: false).isEmpty) {
            await Directory(safe.path).delete();
          }
        }
      });

  Future<List<UploadDraft>> drafts(String accountId) async {
    final rows = await database.customSelect(
        'SELECT id,payload FROM upload_drafts WHERE account_id=? ORDER BY updated_at DESC',
        variables: [Variable<String>(accountId)]).get();
    return rows.map((row) {
      final value = UploadDraft.fromJson(
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>);
      if (value.accountId != accountId || value.id != row.read<String>('id')) {
        throw const FormatException('Upload draft identity mismatch');
      }
      return value;
    }).toList();
  }

  Future<UploadDraft?> draft(String accountId, String id) async {
    final row = await database.customSelect(
        'SELECT payload FROM upload_drafts WHERE account_id=? AND id=?',
        variables: [
          Variable<String>(accountId),
          Variable<String>(id)
        ]).getSingleOrNull();
    if (row == null) return null;
    final draft = UploadDraft.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>);
    if (draft.accountId != accountId || draft.id != id) {
      throw const FormatException('Upload draft identity mismatch');
    }
    return draft;
  }

  /// Called only after active native tasks are stopped and reconciled. It never
  /// deletes source files or makes a remote request. Shared copies remain live.
  Future<void> removeLocal(String accountId, String id) => _serial(() async {
        final removed = await draft(accountId, id);
        if (removed == null) return;
        await database.customStatement(
            'DELETE FROM upload_drafts WHERE account_id=? AND id=?',
            [accountId, id]);
        final rows = await database
            .customSelect('SELECT payload FROM upload_drafts')
            .get();
        final referenced = <String>{};
        for (final row in rows) {
          final other = UploadDraft.fromJson(
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>);
          referenced.addAll(other.assets.map((a) => a.relativePath));
        }
        for (final asset in removed.assets) {
          if (referenced.contains(asset.relativePath)) continue;
          final first = uploadPathParts(asset.relativePath).first;
          if (!{'imports', 'expanded'}.contains(first)) continue;
          final file = await resolveUploadFile(root, asset.relativePath);
          if (await file.exists()) await file.delete();
        }
        _changes.add(null);
      });

  Future<UploadSessionIdentity?> session() async {
    final row = await database
        .customSelect(
            'SELECT account_id,epoch FROM upload_session WHERE singleton=1')
        .getSingleOrNull();
    return row == null
        ? null
        : UploadSessionIdentity(
            row.read<String>('account_id'), row.read<String>('epoch'));
  }

  Future<UploadSessionIdentity> createSession(String accountId) =>
      _serial(() async {
        if (accountId.isEmpty) throw ArgumentError('Account required');
        final identity = UploadSessionIdentity(accountId, newUploadId());
        await database.customStatement(
            'INSERT OR REPLACE INTO upload_session (singleton,account_id,epoch) VALUES (1,?,?)',
            [identity.accountId, identity.epoch]);
        return identity;
      });

  Future<void> clearSession() =>
      _serial(() => database.customStatement('DELETE FROM upload_session'));

  Future<UploadDraft> markRemoteState(
          String accountId, String id, String state) =>
      _serial(() async {
        final current = await draft(accountId, id);
        if (current == null) throw StateError('Upload draft no longer exists');
        return _persist(current.copyWith(
            remoteState: state, revision: current.revision + 1));
      });

  Future<UploadDraft> restoreRemoteOwnership(String accountId, String id) =>
      _serial(() async {
        final current = await draft(accountId, id);
        if (current == null) throw StateError('Upload draft no longer exists');
        return _persist(current.copyWith(
            clearRemoteState: true, revision: current.revision + 1));
      });

  Future<List<Map<String, String>>> preparationGroups(String accountId) async {
    final rows = await database.customSelect(
        'SELECT task_id,group_id FROM upload_artifacts WHERE account_id=?',
        variables: [Variable<String>(accountId)]).get();
    return [
      for (final row in rows)
        {
          'taskId': row.read<String>('task_id'),
          'groupId': row.read<String>('group_id')
        }
    ];
  }

  Future<void> registerAttempt(UploadAttempt attempt) => _serial(() async {
        if (await draft(attempt.accountId, attempt.draftId) == null) {
          throw StateError('Upload draft no longer exists');
        }
        await database.customStatement(
            'INSERT INTO upload_attempts '
            '(account_id,task_id,draft_id,payload) VALUES (?,?,?,?)',
            [
              attempt.accountId,
              attempt.taskId,
              attempt.draftId,
              jsonEncode(attempt.toJson())
            ]);
      });

  Future<PendingUploadWrite?> pendingWrite(
      String accountId, String draftId) async {
    final row = await database.customSelect(
        'SELECT operation_id,kind,server_uri,fields,context FROM upload_pending_writes '
        'WHERE account_id=? AND draft_id=?',
        variables: [
          Variable<String>(accountId),
          Variable<String>(draftId)
        ]).getSingleOrNull();
    if (row == null) return null;
    final uri = row.readNullable<String>('server_uri');
    return PendingUploadWrite(
        row.read<String>('operation_id'),
        row.read<String>('kind'),
        uri == null ? null : requireUploadUri(Uri.parse(uri)),
        (jsonDecode(row.read<String>('fields')) as Map)
            .map((k, v) => MapEntry(k as String, (v as List).cast<String>())),
        context: Map<String, Object?>.from(
            jsonDecode(row.read<String>('context')) as Map));
  }

  Future<String> beginWrite(UploadDraft draft,
          {String? kind, Map<String, Object?> context = const {}}) =>
      _serial(() async {
        final operationKind =
            kind ?? (draft.serverUri == null ? 'create' : 'save');
        if (!{
          'create',
          'save',
          'publish',
          'delete',
          'disown',
          'unlock',
          'clone'
        }.contains(operationKind)) {
          throw ArgumentError('Unsupported upload write kind');
        }
        const safeKeys = {
          'fingerprint',
          'actionUri',
          'editorUri',
          'galleryId',
          'publicUri',
          'parentUri',
          'beforeCanUpload'
        };
        if (context.keys.any((key) => !safeKeys.contains(key)) ||
            context.values.any((value) =>
                value != null &&
                value is! String &&
                value is! int &&
                value is! bool) ||
            jsonEncode(context).length > 32768) {
          throw ArgumentError('Unsafe upload write context');
        }
        if (await pendingWrite(draft.accountId, draft.id) != null) {
          throw const UploadFailure(UploadFailureKind.resultUncertain,
              serverMessage:
                  'A previous save has an unresolved result. Associate its gallery or verify that it did not apply before retrying.');
        }
        final id = newUploadId();
        await database.customStatement(
            'INSERT INTO upload_pending_writes '
            '(account_id,draft_id,operation_id,kind,server_uri,fields,context) VALUES (?,?,?,?,?,?,?)',
            [
              draft.accountId,
              draft.id,
              id,
              operationKind,
              draft.serverUri?.toString(),
              jsonEncode(draft.fields),
              jsonEncode(context)
            ]);
        _changes.add(null);
        return id;
      });

  Future<void> resolveWrite(
          String accountId, String draftId, String operationId,
          {String outcome = 'response_confirmed'}) =>
      _serial(() async {
        if (!{
          'response_confirmed',
          'current_state_confirmed',
          'manual_association',
          'manual_no_effect'
        }.contains(outcome)) {
          throw ArgumentError('Unknown write resolution');
        }
        await database.transaction(() async {
          final pending = await pendingWrite(accountId, draftId);
          if (pending == null || pending.operationId != operationId) {
            throw StateError('The unresolved write changed. Review it again.');
          }
          await database.customStatement(
              'INSERT INTO upload_write_history '
              '(account_id,draft_id,operation_id,kind,server_uri,outcome,resolved_at) '
              'VALUES (?,?,?,?,?,?,?)',
              [
                accountId,
                draftId,
                operationId,
                pending.kind,
                pending.serverUri?.toString(),
                outcome,
                DateTime.now().millisecondsSinceEpoch
              ]);
          await database.customStatement(
              'DELETE FROM upload_pending_writes WHERE account_id=? AND draft_id=? AND operation_id=?',
              [accountId, draftId, operationId]);
        });
        _changes.add(null);
      });

  Future<List<ResolvedUploadWrite>> writeHistory(
      String accountId, String draftId) async {
    final rows = await database.customSelect(
        'SELECT operation_id,kind,server_uri,outcome FROM upload_write_history '
        'WHERE account_id=? AND draft_id=? ORDER BY resolved_at',
        variables: [
          Variable<String>(accountId),
          Variable<String>(draftId)
        ]).get();
    return rows.map((row) {
      final uri = row.readNullable<String>('server_uri');
      return ResolvedUploadWrite(
          row.read<String>('operation_id'),
          row.read<String>('kind'),
          uri == null ? null : requireUploadUri(Uri.parse(uri)),
          row.read<String>('outcome'));
    }).toList();
  }

  Future<List<UploadAttempt>> attempts(String accountId,
      {String? draftId}) async {
    final rows = await database.customSelect(
        'SELECT account_id,task_id,draft_id,payload FROM upload_attempts WHERE account_id=?'
        '${draftId == null ? '' : ' AND draft_id=?'}',
        variables: [
          Variable<String>(accountId),
          if (draftId != null) Variable<String>(draftId)
        ]).get();
    return rows.map((row) {
      final value = UploadAttempt.fromJson(
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>);
      if (value.accountId != accountId ||
          value.taskId != row.read<String>('task_id') ||
          value.draftId != row.read<String>('draft_id')) {
        throw const FormatException('Upload attempt identity mismatch');
      }
      return value;
    }).toList();
  }

  Future<List<ConfirmedUploadAsset>> confirmedAssets(UploadDraft draft) async {
    final gallery = uploadGalleryId(draft.serverUri);
    if (gallery == null) return const [];
    final rows = await database.customSelect(
        'SELECT asset_key,upload_name,file_index,receipt_id,occurrence FROM upload_confirmed_assets '
        'WHERE account_id=? AND draft_id=? AND gallery_id=?',
        variables: [
          Variable<String>(draft.accountId),
          Variable<String>(draft.id),
          Variable<String>(gallery)
        ]).get();
    return rows
        .map((r) => ConfirmedUploadAsset(
            r.read<String>('asset_key'),
            r.read<String>('upload_name'),
            r.read<int>('file_index'),
            r.read<String>('receipt_id'),
            occurrence: _readOccurrence(r.readNullable<String>('occurrence'))))
        .toList();
  }

  RemoteUploadImage? _readOccurrence(String? value) {
    if (value == null) return null;
    final data = jsonDecode(value) as Map<String, dynamic>;
    return RemoteUploadImage(
        page: data['page'] as int,
        positionField: data['positionField'] as String,
        position: data['position'] as int,
        name: data['name'] as String,
        fileIndex: data['fileIndex'] as int);
  }

  String _writeOccurrence(RemoteUploadImage value) => jsonEncode({
        'page': value.page,
        'positionField': value.positionField,
        'position': value.position,
        'name': value.name,
        'fileIndex': value.fileIndex,
      });

  Future<void> confirmReceipt(UploadAttempt attempt, String itemId,
          String receiptId, Map<String, int> confirmed,
          {bool allowPartial = false,
          Map<String, RemoteUploadImage>? remoteOccurrences}) =>
      _serial(() async {
        final record = await database.customSelect(
            'SELECT payload FROM upload_attempts WHERE account_id=? AND task_id=?',
            variables: [
              Variable<String>(attempt.accountId),
              Variable<String>(attempt.taskId)
            ]).getSingleOrNull();
        if (record == null ||
            record.read<String>('payload') != jsonEncode(attempt.toJson())) {
          throw const FormatException('Unknown upload attempt');
        }
        final manifest =
            attempt.assets.where((a) => a.itemId == itemId).toList();
        final selected = allowPartial
            ? manifest
                .where((a) => confirmed.containsKey(a.uploadName))
                .toList()
            : manifest;
        if (selected.isEmpty ||
            confirmed.length != selected.length ||
            selected.any((a) => (confirmed[a.uploadName] ?? 0) <= 0) ||
            (remoteOccurrences == null &&
                confirmed.values.toSet().length != confirmed.length)) {
          throw const FormatException('Incomplete upload receipt mapping');
        }
        if (remoteOccurrences != null) {
          if (remoteOccurrences.length != selected.length ||
              remoteOccurrences.values
                      .map((image) => image.page)
                      .toSet()
                      .length !=
                  selected.length ||
              remoteOccurrences.values
                      .map((image) => image.positionField)
                      .toSet()
                      .length !=
                  selected.length ||
              selected.any((asset) {
                final image = remoteOccurrences[asset.uploadName];
                return image == null ||
                    image.page <= 0 ||
                    image.position <= 0 ||
                    image.positionField.isEmpty ||
                    image.name.isEmpty ||
                    image.fileIndex != confirmed[asset.uploadName];
              })) {
            throw const FormatException(
                'Manual review needs distinct website entries');
          }
          for (final index in confirmed.values.toSet()) {
            if (selected
                    .where((a) => confirmed[a.uploadName] == index)
                    .map((a) => a.sha256)
                    .toSet()
                    .length >
                1) {
              throw const FormatException(
                  'Different image bytes cannot share a website content identity');
            }
          }
        }
        var changed = false;
        await database.transaction(() async {
          for (final asset in selected) {
            final previous = await database.customSelect(
                'SELECT file_index,occurrence FROM upload_confirmed_assets '
                'WHERE account_id=? AND draft_id=? AND gallery_id=? AND asset_key=?',
                variables: [
                  Variable<String>(attempt.accountId),
                  Variable<String>(attempt.draftId),
                  Variable<String>(uploadGalleryId(attempt.serverUri)!),
                  Variable<String>(asset.key)
                ]).getSingleOrNull();
            if (previous != null &&
                previous.read<int>('file_index') !=
                    confirmed[asset.uploadName]) {
              throw const FormatException('Conflicting upload receipt mapping');
            }
            final occurrence = remoteOccurrences?[asset.uploadName];
            if (previous != null &&
                occurrence != null &&
                previous.readNullable<String>('occurrence') != null &&
                previous.readNullable<String>('occurrence') !=
                    _writeOccurrence(occurrence)) {
              throw const FormatException('Conflicting reviewed website entry');
            }
            if (previous != null) continue;
            changed = true;
            await database.customStatement(
                'INSERT OR IGNORE INTO upload_confirmed_assets '
                '(account_id,draft_id,gallery_id,asset_key,upload_name,file_index,receipt_id,occurrence) VALUES (?,?,?,?,?,?,?,?)',
                [
                  attempt.accountId,
                  attempt.draftId,
                  uploadGalleryId(attempt.serverUri),
                  asset.key,
                  asset.uploadName,
                  confirmed[asset.uploadName],
                  receiptId,
                  occurrence == null ? null : _writeOccurrence(occurrence)
                ]);
          }
        });
        if (changed) _changes.add(null);
      });

  Future<UploadDraft> freezeAssetNames(
          UploadDraft draft,
          List<PreparedUploadAsset> pending,
          List<PreparedUploadAsset> frozen) =>
      _serial(() async {
        if (pending.length != frozen.length) {
          throw ArgumentError('Mismatched upload assets');
        }
        final current = await this.draft(draft.accountId, draft.id);
        if (current == null) throw StateError('Upload draft no longer exists');
        final replacements = <String, List<PreparedUploadAsset>>{};
        for (var i = 0; i < pending.length; i++) {
          replacements
              .putIfAbsent(uploadAssetKey(pending[i]), () => [])
              .add(frozen[i]);
        }
        return _persist(current.copyWith(
            assets: current.assets.map((a) {
              final options = replacements[uploadAssetKey(a)];
              return options == null || options.isEmpty
                  ? a
                  : options.removeAt(0);
            }).toList(),
            revision: current.revision + 1));
      });

  Future<void> resetReviewedMissingNames(
          UploadAttempt attempt, Set<String> names) =>
      _serial(() async {
        final current = await draft(attempt.accountId, attempt.draftId);
        if (current == null) throw StateError('Upload draft no longer exists');
        final selected =
            attempt.assets.where((a) => names.contains(a.uploadName)).toList();
        if (selected.length != names.length) {
          throw ArgumentError('Unknown reviewed image');
        }
        final confirmed = {
          for (final file in await confirmedAssets(current)) file.assetKey
        };
        if (selected.any((a) => confirmed.contains(a.key))) {
          throw StateError(
              'An already confirmed image cannot be marked missing');
        }
        final keys = selected.map((a) => a.key).toSet();
        final assets = current.assets
            .map((asset) => keys.contains(uploadAssetKey(asset))
                ? _withUploadName(asset, null)
                : asset)
            .toList();
        if (!_sameAssetList(current.assets, assets)) {
          await _persist(current.copyWith(
              assets: assets, dirty: true, revision: current.revision + 1));
        }
      });

  /// Ownership is recorded before preparation, so a crash cannot orphan form
  /// tokens. Only these two dedicated generated directories can be removed.
  Future<void> registerPreparation(
          String accountId, String taskId, String groupId) =>
      _serial(() async {
        if (accountId.isEmpty ||
            !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(taskId) ||
            !RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(groupId)) {
          throw ArgumentError('Invalid upload preparation owner');
        }
        await database.customStatement(
            'INSERT INTO upload_artifacts '
            '(account_id,task_id,group_id) VALUES (?,?,?)',
            [accountId, taskId, groupId]);
      });

  Future<void> cleanupPreparations(String accountId,
          {String? taskId, String? groupId}) =>
      _serial(() async {
        final rows = await database.customSelect(
            'SELECT task_id,group_id FROM upload_artifacts '
            'WHERE account_id=?${taskId == null ? '' : ' AND task_id=?'}'
            '${groupId == null ? '' : ' AND group_id=?'}',
            variables: [
              Variable<String>(accountId),
              if (taskId != null) Variable<String>(taskId),
              if (groupId != null) Variable<String>(groupId),
            ]).get();
        for (final row in rows) {
          final group = row.read<String>('group_id');
          if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(group)) {
            throw const FormatException('Invalid preparation record');
          }
          for (final prefix in ['prepared', 'batches']) {
            final resolved = await resolveUploadFile(root, '$prefix/$group');
            final kind =
                await FileSystemEntity.type(resolved.path, followLinks: false);
            if (kind == FileSystemEntityType.notFound) continue;
            if (kind != FileSystemEntityType.directory) {
              throw const UploadFileException('unsafe_path');
            }
            // resolveUploadFile checks every ancestor and rejects links. Dart
            // recursive deletion removes child links without following them.
            await Directory(resolved.path).delete(recursive: true);
          }
          await database.customStatement(
              'DELETE FROM upload_artifacts '
              'WHERE account_id=? AND task_id=? AND group_id=?',
              [accountId, row.read<String>('task_id'), group]);
        }
      });

  Future<void> close() async {
    await _writes;
    await _changes.close();
    await database.close();
  }
}

bool _sameValues(List<String>? left, List<String>? right) {
  if (left == null || right == null) return left == right;
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

bool _sameFieldMap(
        Map<String, List<String>> left, Map<String, List<String>> right) =>
    left.length == right.length &&
    left.keys.every((key) => _sameValues(left[key], right[key]));

PreparedUploadAsset _withUploadName(PreparedUploadAsset asset, String? name) =>
    PreparedUploadAsset(
        relativePath: asset.relativePath,
        displayName: asset.displayName,
        size: asset.size,
        sha256: asset.sha256,
        crc32: asset.crc32,
        format: asset.format,
        width: asset.width,
        height: asset.height,
        animated: asset.animated,
        uploadName: name,
        issues: asset.issues);

bool _sameAssetList(
    List<PreparedUploadAsset> left, List<PreparedUploadAsset> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (uploadAssetKey(left[i]) != uploadAssetKey(right[i]) ||
        left[i].displayName != right[i].displayName) return false;
  }
  return true;
}
