import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:flutter/foundation.dart';

import 'upload_http_client.dart';
import 'upload_protocol.dart';

class UploadVisibilityConsent {
  final String accountId;
  final Uri uri;
  final String targetCategory;
  final String fingerprint;
  final String editsHash;
  final int? revision;
  final UploadEditorSnapshot editor;
  const UploadVisibilityConsent(
      {required this.accountId,
      required this.uri,
      required this.targetCategory,
      required this.fingerprint,
      required this.editsHash,
      required this.revision,
      required this.editor});

  static bool requiredFor(
      UploadEditorSnapshot editor, Map<String, List<String>> edits) {
    if (edits.containsKey('category') && edits['category']!.length != 1) {
      throw ArgumentError('Choose exactly one gallery category');
    }
    if (!edits.containsKey('category')) return false;
    if (editor.form.fields['category']?.values.length != 1) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final target = edits['category']?.firstOrNull;
    final notPublished = editor.metadata['Date Posted']
                ?.toLowerCase()
                .contains('not published') ==
            true ||
        editor.metadata['Visible']?.toLowerCase().contains('unpublished') ==
            true ||
        editor.isNew;
    if (target == '0' &&
        editor.form.fields['category']!.value != '0' &&
        !notPublished) {
      throw const UploadFailure(UploadFailureKind.restricted,
          code: 'public_to_private_forbidden',
          serverMessage: 'A published public gallery cannot be made private.');
    }
    return editor.form.fields['category']?.value == '0' &&
        target != null &&
        target != '0' &&
        !notPublished;
  }

  static String hashEdits(Map<String, List<String>> edits) {
    final keys = edits.keys.toList()..sort();
    return sha256
        .convert(
            utf8.encode(jsonEncode({for (final key in keys) key: edits[key]})))
        .toString();
  }

  static String stateFingerprint(UploadEditorSnapshot editor) => sha256
      .convert(utf8.encode(jsonEncode({
        'uri': editor.uri.toString(),
        'fields': {
          for (final key in [
            'gname_en',
            'gname_jp',
            'category',
            'folderid',
            'ulcomment',
            'langtag',
            'langtype',
            'langctl',
            'aigen'
          ])
            key: [
              editor.form.fields[key]?.values,
              editor.form.fields[key]?.disabled,
              editor.form.fields[key]?.readOnly
            ]
        },
        'posted': editor.metadata['Date Posted'],
        'visible': editor.metadata['Visible'],
        'images': editor.images
            .map((image) => [image.fileIndex, image.position, image.name])
            .toList(),
      })))
      .toString();
}

class UploadVisibilityConfirmationRequired implements Exception {
  final UploadEditorSnapshot editor;
  final String targetCategory;
  const UploadVisibilityConfirmationRequired(this.editor, this.targetCategory);
  @override
  String toString() => 'Confirm making this private gallery public';
}

class UploadRepository {
  final UploadHttpClient client;
  final UploadProtocol protocol;

  /// App-level exclusion against active native uploads, outside cookie locks.
  Future<void> Function(Uri target)? beforeWrite;
  Future<void> Function(
          UploadEditorSnapshot fresh, Map<String, List<String>> edits)?
      beforeVisibilityChange;
  Future<void> _writes = Future<void>.value();
  UploadRepository(this.client, {this.protocol = const UploadProtocol()});

  void _account(UploadApiSession api, String accountId) {
    if (api.uid.toString() != accountId) {
      throw const UploadFailure(UploadFailureKind.sessionChanged);
    }
  }

  void _session(int? revision, {bool sent = false}) {
    if (client.cookies.sessionRevision != revision) {
      throw UploadFailure(sent
          ? UploadFailureKind.resultUncertain
          : UploadFailureKind.sessionChanged);
    }
  }

  Future<void> _beforeWrite(Uri target, int? revision) async {
    _session(revision);
    await beforeWrite?.call(target);
    _session(revision);
  }

  Future<void> _beforeVisibility(UploadEditorSnapshot fresh,
      Map<String, List<String>> edits, int? revision) async {
    _session(revision);
    if (UploadVisibilityConsent.requiredFor(fresh, edits) &&
        beforeVisibilityChange == null) {
      throw UploadVisibilityConfirmationRequired(
          fresh, edits['category']!.single);
    }
    await beforeVisibilityChange?.call(fresh, _freezeEdits(edits));
    _session(revision);
  }

  Future<UploadVisibilityConsent?> prepareVisibilityChange(
      String accountId, Uri uri, Map<String, List<String>> edits) async {
    final revision = client.cookies.sessionRevision;
    final frozen = _freezeEdits(edits);
    final fresh = await editor(accountId, uri);
    _session(revision);
    if (!UploadVisibilityConsent.requiredFor(fresh, frozen)) return null;
    fresh.form.submission({
      for (final entry in frozen.entries)
        if (!listEquals(entry.value, fresh.form.fields[entry.key]?.values))
          entry.key: entry.value
    });
    return UploadVisibilityConsent(
        accountId: accountId,
        uri: fresh.uri,
        targetCategory: frozen['category']!.single,
        fingerprint: UploadVisibilityConsent.stateFingerprint(fresh),
        editsHash: UploadVisibilityConsent.hashEdits(frozen),
        revision: revision,
        editor: fresh);
  }

  Future<T> _serialWrite<T>(Future<T> Function() action) {
    final revision = client.cookies.sessionRevision;
    final result = _writes.then((_) {
      _session(revision);
      return action();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Coordinates the final native enqueue with HTTP mutations. The callback
  /// may read fresh server state, but must not call a queued write recursively.
  Future<T> exclusiveWrite<T>(Future<T> Function() action) =>
      _serialWrite(action);

  Map<String, List<String>> _freezeEdits(Map<String, List<String>> source) =>
      Map.unmodifiable(source.map(
          (name, values) => MapEntry(name, List<String>.unmodifiable(values))));

  Future<UploadFoldersSnapshot> saveFolders(
      String accountId, UploadFoldersSnapshot baseline,
      {Map<int, String> renamed = const {},
      List<int>? orderedIds,
      String? newName}) {
    final names = Map<int, String>.unmodifiable(renamed);
    final order =
        orderedIds == null ? null : List<int>.unmodifiable(orderedIds);
    return _serialWrite(() => _saveFolders(accountId, baseline,
        renamed: names, orderedIds: order, newName: newName));
  }

  Future<UploadFoldersSnapshot> deleteEmptyFolder(String accountId, int id) =>
      _serialWrite(() => _deleteEmptyFolder(accountId, id));

  Future<UploadBulkResult> bulkModify(
      String accountId, List<ManagedUploadGallery> targets,
      {int? folderId, String? categoryValue, bool Function()? isCancelled}) {
    final frozen = List<ManagedUploadGallery>.unmodifiable(targets);
    return _serialWrite(() => _bulkModify(accountId, frozen,
        folderId: folderId,
        categoryValue: categoryValue,
        isCancelled: isCancelled));
  }

  Future<UploadEditorSnapshot> reorderImages(String accountId,
      UploadEditorSnapshot baseline, Map<String, int> positions) {
    final frozen = Map<String, int>.unmodifiable(positions);
    return _serialWrite(() => _reorderImages(accountId, baseline, frozen));
  }

  Future<UploadEditorSnapshot> autoSortImages(
          String accountId, UploadEditorSnapshot baseline, String method) =>
      _serialWrite(() => _autoSortImages(accountId, baseline, method));

  Future<UploadEditorSnapshot> save(
      String accountId, Uri uri, Map<String, List<String>> edits,
      {Map<String, List<String>>? baseline}) {
    final frozen = _freezeEdits(edits);
    final previous = baseline == null ? null : _freezeEdits(baseline);
    return _serialWrite(
        () => _save(accountId, uri, frozen, baseline: previous));
  }

  Future<UploadManagerSnapshot> manager(String accountId) async {
    final response = await client.get(uploadOrigin.resolve('manage'));
    final snapshot = protocol.manager(response.body);
    _account(snapshot.api, accountId);
    return snapshot;
  }

  Future<UploadEditorSnapshot> editor(String accountId, Uri uri) async {
    requireUploadUri(uri);
    if (uri.path != '/managegallery') {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final response = await client.get(uri);
    final snapshot = protocol.editor(response.body, response.uri);
    _account(snapshot.api, accountId);
    if (uri.queryParameters['ulgid'] != null &&
        snapshot.uri.queryParameters['ulgid'] != uri.queryParameters['ulgid']) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    return snapshot;
  }

  Future<UploadEditorSnapshot> newEditor(String accountId) =>
      editor(accountId, uploadOrigin.resolve('managegallery?act=new'));

  Future<List<ManagedUploadGallery>> folder(String accountId,
      UploadManagerSnapshot manager, UploadFolderSection folder) async {
    _account(manager.api, accountId);
    final result = await client.readApi(manager.api, 'managefolders', {
      'state': folder.state,
      'fid': folder.folderId,
      'ss': manager.sort,
      'sd': manager.direction,
    });
    if (result['state'] != folder.state ||
        result['fid'] != folder.folderId ||
        result['rows'] is! List) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final galleries = <ManagedUploadGallery>[];
    for (final raw in result['rows'] as List) {
      if (raw is! Map ||
          List.generate(6, (i) => 'c${i + 1}')
              .any((name) => raw[name] is! String)) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
      final row = html
          .parse(
              '<table><tr>${List.generate(6, (i) => '<td class="gtc${i + 1}">${raw['c${i + 1}']}</td>').join()}</tr></table>')
          .querySelector('tr')!;
      galleries.add(protocol.galleryRow(
          row, folder.state, uploadOrigin.resolve('manage'),
          folderId: folder.folderId,
          sectionLabel: manager.sectionLabels[folder.state]));
    }
    return galleries;
  }

  Future<UploadFoldersSnapshot> folders(String accountId) async {
    final revision = client.cookies.sessionRevision;
    await _folderCookieOwner(accountId, revision);
    final response = await client.get(uploadOrigin.resolve('managefolders'));
    _session(revision);
    final snapshot = _parseFolders(response);
    await _folderOwner(accountId, revision);
    return _bindFolders(snapshot, accountId, revision);
  }

  UploadFoldersSnapshot _parseFolders(UploadResponse response) {
    if (requireUploadUri(response.uri) !=
        uploadOrigin.resolve('managefolders')) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    return protocol.folders(response.body);
  }

  UploadFoldersSnapshot _bindFolders(
          UploadFoldersSnapshot value, String accountId, int? revision) =>
      UploadFoldersSnapshot(
          form: value.form,
          folders: value.folders,
          accountId: accountId,
          sessionRevision: revision);

  Future<void> _folderCookieOwner(String accountId, int? revision,
      {bool sent = false}) async {
    _session(revision, sent: sent);
    if (await client.cookies.getMemberId() != accountId) {
      throw UploadFailure(sent
          ? UploadFailureKind.resultUncertain
          : UploadFailureKind.sessionChanged);
    }
    _session(revision, sent: sent);
  }

  Future<UploadManagerSnapshot> _folderOwner(String accountId, int? revision,
      {bool sent = false}) async {
    await _folderCookieOwner(accountId, revision, sent: sent);
    // The real folder form has no API credentials. Only this independent
    // authenticated manager response supplies the owner identity.
    final owner = await manager(accountId);
    await _folderCookieOwner(accountId, revision, sent: sent);
    return owner;
  }

  /// Only observed hidden command fields/readonly ordering controls may be
  /// changed here. General UploadForm edits still cannot alter hidden fields.
  UploadForm _commandForm(UploadForm form, Map<String, String> commands,
      {Map<String, UploadField> extra = const {}}) {
    final fields = <String, UploadField>{...form.fields, ...extra};
    for (final command in commands.entries) {
      final field = fields[command.key];
      if (field == null || field.disabled) {
        throw const UploadFailure(UploadFailureKind.restricted);
      }
      fields[command.key] = UploadField(
          name: field.name, type: 'hidden', values: [command.value]);
    }
    return UploadForm(
        action: form.action,
        fields: Map.unmodifiable(fields),
        multipart: form.multipart);
  }

  Future<UploadFoldersSnapshot> _saveFolders(
      String accountId, UploadFoldersSnapshot baseline,
      {Map<int, String> renamed = const {},
      List<int>? orderedIds,
      String? newName}) async {
    final revision = client.cookies.sessionRevision;
    if (baseline.accountId != accountId ||
        baseline.sessionRevision != revision) {
      throw const UploadFailure(UploadFailureKind.sessionChanged);
    }
    final fresh = await folders(accountId);
    final byId = {for (final folder in fresh.folders) folder.id: folder};
    final previous = {for (final folder in baseline.folders) folder.id: folder};
    final edits = <String, List<String>>{};
    for (final rename in renamed.entries) {
      final target = byId[rename.key];
      if (target == null ||
          previous[rename.key]?.name != target.name ||
          !target.nameField.canEdit ||
          rename.value.trim().isEmpty) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'A folder changed or cannot be renamed. Refresh before saving.');
      }
      edits[target.nameField.name] = [rename.value.trim()];
    }
    if (orderedIds != null) {
      if (orderedIds.length != byId.length ||
          orderedIds.toSet().length != orderedIds.length ||
          !orderedIds.toSet().containsAll(byId.keys) ||
          byId.values.any((folder) =>
              !folder.positionField.canEdit ||
              previous[folder.id]?.position != folder.position)) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'The folder list changed. Refresh before reordering.');
      }
      for (var i = 0; i < orderedIds.length; i++) {
        edits[byId[orderedIds[i]]!.positionField.name] = ['${i + 1}'];
      }
    }
    if (newName != null) {
      if (newName.trim().isEmpty) {
        throw ArgumentError('Folder name is required');
      }
      edits['fname'] = [newName.trim()];
    }
    if (edits.isEmpty) return fresh;
    final operation = _commandForm(
        fresh.form, {'do_save': '1', 'do_delete': '', 'do_autosort': ''});
    operation.submission(edits);
    await _beforeWrite(operation.action, revision);
    await _folderOwner(accountId, revision);
    final response = await client.postForm(operation, edits);
    _session(revision, sent: true);
    try {
      final saved = _parseFolders(response);
      await _folderOwner(accountId, revision, sent: true);
      final after = {for (final folder in saved.folders) folder.id: folder};
      if (renamed.entries
              .any((entry) => after[entry.key]?.name != entry.value.trim()) ||
          (orderedIds != null &&
              Iterable<int>.generate(orderedIds.length)
                  .any((i) => after[orderedIds[i]]?.position != '${i + 1}')) ||
          (newName != null &&
              saved.folders
                      .where((folder) =>
                          !byId.containsKey(folder.id) &&
                          folder.name == newName.trim())
                      .length !=
                  1)) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      return _bindFolders(saved, accountId, revision);
    } on UploadFailure catch (error) {
      if ({
        UploadFailureKind.protocolChanged,
        UploadFailureKind.sessionChanged,
        UploadFailureKind.network,
        UploadFailureKind.loginRequired
      }.contains(error.kind)) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      rethrow;
    }
  }

  Future<UploadFoldersSnapshot> _deleteEmptyFolder(
      String accountId, int id) async {
    final revision = client.cookies.sessionRevision;
    final fresh = await folders(accountId);
    final target = fresh.folders.where((folder) => folder.id == id).firstOrNull;
    if (target == null || !target.canDelete) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    // The website moves remaining galleries to Unsorted when deleting a folder.
    // The app permits only an empty folder after a fresh complete manager read.
    await _beforeWrite(fresh.form.action, revision);
    final current = await _folderOwner(accountId, revision);
    for (final section
        in current.folders.where((folder) => folder.folderId == id)) {
      if (section.galleryCount == null || section.galleryCount! > 0) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'This folder is not confirmed empty. Refresh and move all galleries out before deleting it.');
      }
    }
    if (current.galleries.any((gallery) => gallery.folderId == id)) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'Move all galleries out of this folder before deleting it.');
    }
    final response = await client.postForm(
        _commandForm(
            fresh.form, {'do_delete': '$id', 'do_save': '', 'do_autosort': ''}),
        const {});
    _session(revision, sent: true);
    try {
      final saved = _parseFolders(response);
      await _folderOwner(accountId, revision, sent: true);
      if (saved.folders.any((folder) => folder.id == id)) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      return _bindFolders(saved, accountId, revision);
    } on UploadFailure catch (error) {
      if ({
        UploadFailureKind.protocolChanged,
        UploadFailureKind.sessionChanged,
        UploadFailureKind.network,
        UploadFailureKind.loginRequired
      }.contains(error.kind)) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      rethrow;
    }
  }

  Future<ManagedUploadGallery?> _findGallery(String accountId,
      UploadManagerSnapshot snapshot, ManagedUploadGallery target,
      {int? expectedFolder, bool identityOnly = false}) async {
    bool matches(ManagedUploadGallery value) =>
        (identityOnly || value.selectionKey == target.selectionKey) &&
        value.managementUri == target.managementUri;
    final visible = snapshot.galleries.where(matches).firstOrNull;
    if (visible != null) return visible;
    for (final section in snapshot.folders) {
      if (!section.collapsed ||
          section.galleryCount == 0 ||
          (expectedFolder != null && section.folderId != expectedFolder)) {
        continue;
      }
      final found = (await folder(accountId, snapshot, section))
          .where(matches)
          .firstOrNull;
      if (found != null) return found;
    }
    return null;
  }

  /// The target list is frozen by the UI. Each request selects one refreshed
  /// gallery; failures do not roll back previous items or replay uncertain work.
  Future<UploadBulkResult> _bulkModify(
      String accountId, List<ManagedUploadGallery> targets,
      {int? folderId,
      String? categoryValue,
      bool Function()? isCancelled}) async {
    final revision = client.cookies.sessionRevision;
    if ((folderId == null) == (categoryValue == null) ||
        targets.isEmpty ||
        targets.map((gallery) => gallery.selectionKey).toSet().length !=
            targets.length) {
      throw ArgumentError('Choose one bulk operation and distinct targets');
    }
    final frozen = List<ManagedUploadGallery>.unmodifiable(targets);
    final results = <UploadBulkItemResult>[];
    var stopped = false;
    for (final target in frozen) {
      if (stopped || isCancelled?.call() == true) {
        results.add(UploadBulkItemResult(target, UploadBulkStatus.notExecuted));
        continue;
      }
      try {
        _session(revision);
        final fresh = await manager(accountId);
        final selected = await _findGallery(accountId, fresh, target);
        if (selected == null ||
            !selected.canSelect ||
            selected.title != target.title ||
            selected.date != target.date ||
            selected.fileCount != target.fileCount ||
            selected.category != target.category ||
            (target.folderId != null && selected.folderId != target.folderId)) {
          results.add(UploadBulkItemResult(target, UploadBulkStatus.skipped,
              reason:
                  'The gallery changed, disappeared, or is no longer selectable.'));
          continue;
        }
        final fieldName = folderId != null ? 'folderid' : 'publiccat';
        final submitter = folderId != null ? 'folderize' : 'categorize';
        final value = folderId != null ? '$folderId' : categoryValue!;
        final control = fresh.form.fields[fieldName];
        final button = fresh.form.fields[submitter];
        if (control?.canEdit != true ||
            button?.type != 'submit' ||
            button!.disabled ||
            button.value.isEmpty ||
            !control!.options
                .any((option) => option.value == value && !option.disabled)) {
          throw const UploadFailure(UploadFailureKind.restricted,
              serverMessage:
                  'The selected bulk action or destination is no longer available.');
        }
        if (categoryValue != null) {
          final permissions = await editor(accountId, selected.managementUri!);
          final category = permissions.form.fields['category'];
          final unpublished = permissions.metadata['Date Posted']
                      ?.toLowerCase()
                      .contains('not published') ==
                  true ||
              permissions.metadata['Visible']
                      ?.toLowerCase()
                      .contains('unpublished') ==
                  true;
          if (category?.canEdit != true ||
              !category!.options
                  .any((option) => option.value == value && !option.disabled) ||
              (value == '0' && category.value != '0' && !unpublished)) {
            results.add(UploadBulkItemResult(target, UploadBulkStatus.skipped,
                reason:
                    'The current gallery does not allow this category change.'));
            continue;
          }
          await _beforeVisibility(
              permissions,
              {
                'category': [value]
              },
              revision);
        }
        if (isCancelled?.call() == true) {
          results
              .add(UploadBulkItemResult(target, UploadBulkStatus.notExecuted));
          stopped = true;
          continue;
        }
        final selectionName = selected.selectionName!;
        final selectionValue = selected.selectionValue!;
        if (!RegExp(r'^modify_[a-z]+\[\]$').hasMatch(selectionName) ||
            !RegExp(r'^\d+$').hasMatch(selectionValue) ||
            selected.managementUri!.queryParameters['ulgid'] !=
                selectionValue) {
          throw const UploadFailure(UploadFailureKind.protocolChanged);
        }
        final controls = <String, UploadField>{
          for (final field in fresh.form.fields.values)
            if (field.type == 'checkbox')
              field.name: UploadField(
                  name: field.name,
                  type: 'checkbox',
                  values: const [],
                  options: field.options,
                  disabled: field.disabled,
                  readOnly: field.readOnly),
          selectionName: UploadField(
              name: selectionName,
              type: 'checkbox',
              options: [UploadOption(selectionValue, selected.title)]),
        };
        final form = _commandForm(fresh.form, {submitter: button.value},
            extra: controls);
        await _beforeWrite(selected.managementUri!, revision);
        final response = await client.postForm(form, {
          selectionName: [selectionValue],
          fieldName: [value],
        });
        _session(revision, sent: true);
        final updated = protocol.manager(response.body);
        _account(updated.api, accountId);
        final after = await _findGallery(accountId, updated, selected,
            expectedFolder: folderId, identityOnly: true);
        if (after == null || (folderId != null && after.folderId != folderId)) {
          throw const UploadFailure(UploadFailureKind.resultUncertain);
        }
        if (categoryValue != null) {
          final checked = await editor(accountId, after.managementUri!);
          if (checked.form.fields['category']?.value != categoryValue) {
            throw const UploadFailure(UploadFailureKind.resultUncertain);
          }
        }
        results.add(UploadBulkItemResult(target, UploadBulkStatus.completed));
      } on UploadVisibilityConfirmationRequired {
        results.add(UploadBulkItemResult(target, UploadBulkStatus.failed,
            reason:
                'Review and confirm making this private gallery public before changing its category.'));
        stopped = true;
      } on UploadFailure catch (error) {
        results.add(UploadBulkItemResult(
            target,
            error.kind == UploadFailureKind.resultUncertain ||
                    error.kind == UploadFailureKind.protocolChanged
                ? UploadBulkStatus.uncertain
                : UploadBulkStatus.failed,
            reason: error.serverMessage ?? error.kind.name));
        stopped = true;
      } catch (_) {
        results.add(UploadBulkItemResult(target, UploadBulkStatus.uncertain));
        stopped = true;
      }
    }
    return UploadBulkResult(results);
  }

  bool _sameImages(
          List<RemoteUploadImage> first, List<RemoteUploadImage> second) =>
      first.length == second.length &&
      Iterable<int>.generate(first.length).every((i) =>
          first[i].positionField == second[i].positionField &&
          first[i].position == second[i].position &&
          first[i].name == second[i].name &&
          first[i].fileIndex == second[i].fileIndex);

  Future<UploadEditorSnapshot> _reorderImages(String accountId,
      UploadEditorSnapshot baseline, Map<String, int> positions) async {
    final revision = client.cookies.sessionRevision;
    _account(baseline.api, accountId);
    final fresh = await editor(accountId, baseline.uri);
    if (!_sameImages(fresh.images, baseline.images) ||
        fresh.reorderForm == null ||
        fresh.buttons['reorder_manual']?.enabled != true) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'The image list changed or cannot be edited. Refresh before saving.');
    }
    final keys = fresh.images.map((image) => image.positionField).toSet();
    final ordered = positions.values.where((position) => position != 0).toList()
      ..sort();
    if (positions.length != keys.length ||
        !positions.keys.toSet().containsAll(keys) ||
        positions.values.any((position) => position < 0) ||
        Iterable<int>.generate(ordered.length)
            .any((i) => ordered[i] != i + 1)) {
      throw ArgumentError(
          'Retained image positions must be a complete unique sequence');
    }
    final requested = fresh.images
        .where((image) => positions[image.positionField]! > 0)
        .toList()
      ..sort((a, b) =>
          positions[a.positionField]!.compareTo(positions[b.positionField]!));
    final commands = {
      'do_reorder': 'manual',
      for (final entry in positions.entries) entry.key: '${entry.value}'
    };
    await _beforeWrite(fresh.uri, revision);
    final response = await client
        .postForm(_commandForm(fresh.reorderForm!, commands), const {});
    _session(revision, sent: true);
    try {
      final saved = protocol.editor(response.body, response.uri);
      _account(saved.api, accountId);
      // The site renumbers page inputs after saving. Verify content order.
      if (saved.images.length != requested.length ||
          Iterable<int>.generate(requested.length).any((i) =>
              saved.images[i].name != requested[i].name ||
              (requested[i].fileIndex != null &&
                  saved.images[i].fileIndex != requested[i].fileIndex))) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      return saved;
    } on UploadFailure catch (error) {
      if (error.kind == UploadFailureKind.protocolChanged) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      rethrow;
    }
  }

  Future<UploadEditorSnapshot> _autoSortImages(
      String accountId, UploadEditorSnapshot baseline, String method) async {
    if (!{'natural', 'lexical', 'dedupe'}.contains(method)) {
      throw ArgumentError('Unsupported image sorting operation');
    }
    final revision = client.cookies.sessionRevision;
    _account(baseline.api, accountId);
    final fresh = await editor(accountId, baseline.uri);
    final form = fresh.reorderForm;
    if (!_sameImages(fresh.images, baseline.images) ||
        form == null ||
        fresh.buttons['reorder_auto']?.enabled != true ||
        form.fields['autosort']?.canEdit != true ||
        !form.fields['autosort']!.options
            .any((option) => option.value == method && !option.disabled)) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'The image list or sorting capability changed. Refresh before sorting.');
    }
    await _beforeWrite(fresh.uri, revision);
    final response =
        await client.postForm(_commandForm(form, {'do_reorder': 'auto'}), {
      'autosort': [method]
    });
    _session(revision, sent: true);
    try {
      final saved = protocol.editor(response.body, response.uri);
      _account(saved.api, accountId);
      final remaining = fresh.images
          .map((image) => '${image.fileIndex}:${image.name}')
          .toList();
      for (final image in saved.images) {
        if (!remaining.remove('${image.fileIndex}:${image.name}')) {
          throw const UploadFailure(UploadFailureKind.resultUncertain);
        }
      }
      if (method != 'dedupe' && remaining.isNotEmpty) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      return saved;
    } on UploadFailure catch (error) {
      if (error.kind == UploadFailureKind.protocolChanged) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      rethrow;
    }
  }

  Future<Uri> imageUri(String accountId, UploadEditorSnapshot snapshot,
      RemoteUploadImage image) async {
    final revision = client.cookies.sessionRevision;
    _account(snapshot.api, accountId);
    final galleryId = int.tryParse(snapshot.uri.queryParameters['ulgid'] ?? '');
    if (galleryId == null ||
        image.fileIndex == null ||
        !snapshot.images.any((candidate) =>
            candidate.page == image.page &&
            candidate.fileIndex == image.fileIndex &&
            candidate.name == image.name)) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final result = await client.readApi(
        snapshot.api,
        'viewimage',
        {
          'ulgid': galleryId,
          'page': image.page,
          'fileindex': image.fileIndex!,
        },
        referer: snapshot.uri);
    _session(revision);
    final uri =
        Uri.tryParse(result['url'] is String ? result['url'] as String : '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !(uri.host == 'ehgt.org' || uri.host.endsWith('.hath.network'))) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    return uri;
  }

  /// Refresh the form before a write so stale capabilities and tokens are not
  /// reused. Caller presents/records explicit user intent and TOS acceptance.
  Future<UploadEditorSnapshot> _save(
      String accountId, Uri uri, Map<String, List<String>> edits,
      {Map<String, List<String>>? baseline}) async {
    final revision = client.cookies.sessionRevision;
    final fresh = await editor(accountId, uri);
    if (fresh.buttons['savebutton']?.enabled != true) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    final title = edits['gname_en']?.firstOrNull ??
        fresh.form.fields['gname_en']?.value ??
        '';
    final tos = edits['tos'] ?? fresh.form.fields['tos']?.values ?? [];
    if (title.trim().isEmpty ||
        (fresh.form.fields.containsKey('tos') && !tos.contains('on'))) {
      throw ArgumentError('A title and explicit terms acceptance are required');
    }
    final changes = <String, List<String>>{};
    for (final entry in edits.entries) {
      final field = fresh.form.fields[entry.key];
      final previous = baseline?[entry.key];
      if (previous != null && listEquals(previous, entry.value)) continue;
      if (field == null || !field.canEdit) {
        if (field != null && listEquals(field.values, entry.value)) continue;
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage: 'The current gallery no longer allows this edit.');
      }
      if (previous != null &&
          !listEquals(previous, field.values) &&
          !listEquals(entry.value, field.values)) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'The gallery was edited elsewhere. Refresh before saving.');
      }
      changes[entry.key] = entry.value;
    }
    final submitted = fresh.form.submission(changes);
    await _beforeVisibility(fresh, edits, revision);
    await _beforeWrite(fresh.uri, revision);
    final response = await client.postForm(fresh.form, changes);
    _session(revision, sent: true);
    try {
      final saved = protocol.editor(response.body, response.uri);
      _account(saved.api, accountId);
      if (fresh.isNew && saved.isNew) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      if (!fresh.isNew &&
          saved.uri.queryParameters['ulgid'] !=
              fresh.uri.queryParameters['ulgid']) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      _verifySavedFields(fresh, saved, submitted);
      return saved;
    } on UploadFailure catch (error) {
      if (error.kind == UploadFailureKind.protocolChanged) {
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      }
      rethrow;
    }
  }

  void _verifySavedFields(UploadEditorSnapshot before,
      UploadEditorSnapshot after, Map<String, List<String>> submitted) {
    const businessFields = {
      'gname_en',
      'gname_jp',
      'category',
      'aigen',
      'langtag',
      'langtype',
      'langctl',
      'folderid',
      'foldername',
      'ulcomment'
    };
    final newFolder = submitted['foldername']?.singleOrNull?.trim() ?? '';
    if (newFolder.isNotEmpty) {
      final folder = after.form.fields['folderid'];
      if (folder == null ||
          folder.values.length != 1 ||
          folder.value == '0' ||
          folder.options
                  .where((o) =>
                      o.value == folder.value && o.label.trim() == newFolder)
                  .length !=
              1) {
        throw const UploadFailure(UploadFailureKind.resultUncertain,
            serverMessage:
                'The requested folder was not confirmed in the saved gallery.');
      }
    }
    for (final name in businessFields) {
      if (before.form.fields[name]?.canEdit != true ||
          !submitted.containsKey(name)) continue;
      if (name == 'foldername' ||
          (name == 'folderid' && newFolder.isNotEmpty)) {
        continue;
      }
      final actual = after.form.fields[name]?.values;
      final expected = submitted[name]!;
      // HTML textarea parsing normalizes line endings. Do not otherwise guess
      // that a rejected or rewritten value was accepted by the server.
      String normalized(String value) =>
          value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      if (actual == null ||
          !listEquals(expected.map(normalized).toList(),
              actual.map(normalized).toList())) {
        throw const UploadFailure(UploadFailureKind.resultUncertain,
            serverMessage:
                'The saved gallery did not confirm every submitted change. Review its current values.');
      }
    }
  }
}
