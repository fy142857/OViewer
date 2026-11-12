import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'upload_protocol.dart';
import 'upload_repository.dart';
import 'upload_store.dart' show uploadGalleryId;

enum UploadGalleryAction { publish, delete, disown, clone }

class PreparedUploadAction {
  final String accountId;
  final UploadGalleryAction action;
  final Uri editorUri;
  final Uri actionUri;
  final UploadEditorSnapshot editor;
  final String fingerprint;
  final int? revision;
  const PreparedUploadAction(
      {required this.accountId,
      required this.action,
      required this.editorUri,
      required this.actionUri,
      required this.editor,
      required this.fingerprint,
      required this.revision});
}

class UploadActionResult {
  final UploadGalleryAction kind;
  final UploadEditorSnapshot? editor;
  final UploadManagerSnapshot? manager;
  final Uri? publicUri;
  final String? localDraftId;
  const UploadActionResult(this.kind,
      {this.editor, this.manager, this.publicUri, this.localDraftId});
}

class UploadStatsSnapshot {
  final Uri uri;
  final String title;
  final List<List<List<String>>> tables;
  final List<String> notes;
  const UploadStatsSnapshot(
      {required this.uri,
      required this.title,
      required this.tables,
      required this.notes});
}

/// Follows an operation advertised by the freshly authenticated owner page.
/// No guessed write URL, JavaScript execution or automatic mutation retries.
class UploadAdvancedActions {
  final UploadRepository repository;
  const UploadAdvancedActions(this.repository);

  void _current(String account, int? revision, UploadEditorSnapshot editor,
      {bool sent = false}) {
    if (editor.api.uid.toString() != account ||
        repository.client.cookies.sessionRevision != revision) {
      throw UploadFailure(sent
          ? UploadFailureKind.resultUncertain
          : UploadFailureKind.sessionChanged);
    }
  }

  static Uri? publicGallery(UploadEditorSnapshot editor) {
    for (final entry in editor.links.entries) {
      final uri = entry.value;
      if (entry.key.toLowerCase().contains('public gallery') &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          uri.port == 443 &&
          {'e-hentai.org', 'exhentai.org'}.contains(uri.host) &&
          RegExp(r'^/g/[1-9]\d*/[a-f0-9]+/?$').hasMatch(uri.path)) return uri;
    }
    return null;
  }

  static bool unpublished(UploadEditorSnapshot editor) =>
      editor.metadata['Date Posted']?.toLowerCase().contains('not published') ==
          true ||
      editor.metadata['Visible']?.toLowerCase().contains('unpublished') == true;

  String _fingerprint(UploadEditorSnapshot editor, Uri action) => sha256
      .convert(utf8.encode(jsonEncode({
        'uri': editor.uri.toString(),
        'action': action.toString(),
        'fields': {
          for (final name in [
            'gname_en',
            'gname_jp',
            'category',
            'folderid',
            'ulcomment'
          ])
            name: editor.form.fields[name]?.values
        },
        'metadata': editor.metadata,
        'images': editor.images
            .map((i) => [i.fileIndex, i.position, i.name])
            .toList(),
      })))
      .toString();

  Uri? _controlUri(Element control, Uri base) {
    final href = control.attributes['href'];
    if (href != null &&
        href.isNotEmpty &&
        !href.startsWith('#') &&
        !href.startsWith('javascript:')) {
      return base.resolve(href);
    }
    final script = control.attributes['onclick'] ?? '';
    final locations = RegExp(
            r'''(?:document|window)\.location(?:\.href)?\s*=\s*(['"])([^'"]+)\1''')
        .allMatches(script)
        .toList();
    if (locations.length == 1) return base.resolve(locations.single[2]!);
    final popups =
        RegExp(r'''(?:popUp|window\.open)\(\s*(['"])(https://[^'"]+)\1''')
            .allMatches(script)
            .toList();
    if (popups.length == 1) return base.resolve(popups.single[2]!);
    return null;
  }

  bool _matches(Uri? uri, String id, UploadGalleryAction action) =>
      uri != null &&
      isUploadUri(uri) &&
      uri.path == '/managegallery' &&
      uri.queryParametersAll['ulgid']?.length == 1 &&
      uri.queryParameters['ulgid'] == id &&
      uri.queryParametersAll['act']?.length == 1 &&
      (action == UploadGalleryAction.clone
              ? {'unlock', 'clone'}
              : {action.name})
          .contains(uri.queryParameters['act']) &&
      uri.queryParameters.keys
          .every((key) => {'ulgid', 'act', 'from'}.contains(key));

  Future<PreparedUploadAction> prepare(
      String accountId, Uri editorUri, UploadGalleryAction action) async {
    final revision = repository.client.cookies.sessionRevision;
    final response = await repository.client.get(editorUri);
    final editor = repository.protocol.editor(response.body, response.uri);
    _current(accountId, revision, editor);
    final id = uploadGalleryId(editor.uri);
    if (id == null || editor.isNew) {
      throw const UploadFailure(UploadFailureKind.restricted);
    }
    if (action == UploadGalleryAction.delete &&
        !unpublished(editor) &&
        editor.form.fields['category']?.value != '0') {
      throw const UploadFailure(UploadFailureKind.restricted,
          code: 'public_delete_forbidden',
          serverMessage:
              'Published public galleries cannot be deleted by the uploader.');
    }
    if (action == UploadGalleryAction.publish && !editor.canPublish) {
      throw const UploadFailure(UploadFailureKind.restricted,
          code: 'unavailable_action',
          serverMessage:
              'The website does not currently offer publication for this gallery.');
    }
    final doc = repository.protocol.document(response.body);
    final selectors = switch (action) {
      UploadGalleryAction.publish => '#publishbutton',
      UploadGalleryAction.clone => '#unlockbutton, td#d a',
      UploadGalleryAction.delete || UploadGalleryAction.disown => 'td#d a',
    };
    Uri? operation;
    for (final control in doc.querySelectorAll(selectors)) {
      if (control.attributes.containsKey('disabled')) continue;
      final uri = _controlUri(control, editor.uri);
      if (_matches(uri, id, action)) {
        operation = uri;
        break;
      }
    }
    if (operation == null && action != UploadGalleryAction.publish) {
      final manager = await repository.manager(accountId);
      _current(accountId, revision, editor);
      final rows = [...manager.galleries];
      for (final folder in manager.folders.where((f) => f.collapsed)) {
        rows.addAll(await repository.folder(accountId, manager, folder));
        _current(accountId, revision, editor);
      }
      for (final gallery
          in rows.where((g) => uploadGalleryId(g.managementUri) == id)) {
        for (final uri in gallery.actions.values) {
          if (_matches(uri, id, action)) operation = uri;
        }
      }
    }
    if (operation == null) {
      throw const UploadFailure(UploadFailureKind.restricted,
          code: 'unavailable_action',
          serverMessage:
              'The website does not currently offer this operation for this gallery.');
    }
    return PreparedUploadAction(
        accountId: accountId,
        action: action,
        editorUri: editor.uri,
        actionUri: operation,
        editor: editor,
        fingerprint: _fingerprint(editor, operation),
        revision: revision);
  }

  Future<UploadActionResult> perform(
          String accountId, PreparedUploadAction prepared,
          {required bool confirmed}) =>
      repository.exclusiveWrite(() async {
        if (!confirmed || prepared.accountId != accountId) {
          throw ArgumentError('Explicit confirmation required');
        }
        _current(accountId, prepared.revision, prepared.editor);
        final fresh =
            await prepare(accountId, prepared.editorUri, prepared.action);
        if (fresh.actionUri != prepared.actionUri ||
            fresh.fingerprint != prepared.fingerprint) {
          throw const UploadFailure(UploadFailureKind.restricted,
              code: 'gallery_changed',
              serverMessage:
                  'The gallery changed after review. Review the current state before confirming.');
        }
        await repository.beforeWrite?.call(fresh.editorUri);
        _current(accountId, prepared.revision, fresh.editor);
        final response = await repository.client.mutateGalleryAction(
            fresh.actionUri,
            expectedGalleryId: uploadGalleryId(fresh.editorUri)!,
            expectedAction: fresh.actionUri.queryParameters['act']!);
        _current(accountId, prepared.revision, fresh.editor, sent: true);
        try {
          if (prepared.action == UploadGalleryAction.delete) {
            final confirmation =
                _deleteConfirmation(response.body, response.uri, fresh);
            if (confirmation != null) {
              // This is the one observed confirmation step of the action the
              // user reviewed. Recheck before its destructive POST, without
              // re-entering beforeWrite (the operation is already journaled).
              final checked = await prepare(
                  accountId, fresh.editorUri, UploadGalleryAction.delete);
              _current(accountId, prepared.revision, checked.editor,
                  sent: true);
              if (checked.actionUri != fresh.actionUri ||
                  checked.fingerprint != fresh.fingerprint) {
                throw const UploadFailure(UploadFailureKind.resultUncertain,
                    serverMessage:
                        'The gallery changed before deletion was confirmed. Review it again.');
              }
              await repository.client.postForm(confirmation, const {});
              _current(accountId, prepared.revision, checked.editor,
                  sent: true);
            }
          }
          if (prepared.action == UploadGalleryAction.publish ||
              prepared.action == UploadGalleryAction.clone) {
            final editor = prepared.action == UploadGalleryAction.publish
                ? await repository.editor(accountId, fresh.editorUri)
                : repository.protocol.editor(response.body, response.uri);
            _current(accountId, prepared.revision, editor, sent: true);
            if (prepared.action == UploadGalleryAction.publish) {
              final publicUri = publicGallery(editor);
              if (uploadGalleryId(editor.uri) !=
                      uploadGalleryId(fresh.editorUri) ||
                  unpublished(editor) ||
                  publicUri == null) {
                throw const UploadFailure(UploadFailureKind.resultUncertain);
              }
              return UploadActionResult(prepared.action,
                  editor: editor, publicUri: publicUri);
            }
            final previous = uploadGalleryId(fresh.editorUri);
            final sameId = uploadGalleryId(editor.uri) == previous;
            final previousPublic = publicGallery(fresh.editor);
            final doc = repository.protocol.document(response.body);
            final parentLinks = doc
                .querySelectorAll('td#d tr')
                .where((row) =>
                    row
                        .querySelector('td.k')
                        ?.text
                        .toLowerCase()
                        .contains('parent gallery') ==
                    true)
                .expand((row) => row.querySelectorAll('td.v a[href]'))
                .map((a) => response.uri.resolve(a.attributes['href']!));
            final linked = parentLinks.any((uri) =>
                uploadGalleryId(uri) == previous || uri == previousPublic);
            // An editable page at the original URL is not evidence that this
            // request unlocked it. Match recovery's false-to-true requirement;
            // a distinct child still requires the observed parent link.
            if (!editor.canUpload ||
                (sameId ? fresh.editor.canUpload : !linked)) {
              throw const UploadFailure(UploadFailureKind.resultUncertain);
            }
            return UploadActionResult(prepared.action,
                editor: editor, publicUri: previousPublic);
          }
          // A confirmation form or a surviving row is not success. Never submit an
          // unfamiliar follow-up form automatically or repeat the mutating GET.
          final manager = await repository.manager(accountId);
          _current(accountId, prepared.revision, fresh.editor, sent: true);
          final rows = [...manager.galleries];
          for (final folder in manager.folders.where((f) => f.collapsed)) {
            final contents =
                await repository.folder(accountId, manager, folder);
            _current(accountId, prepared.revision, fresh.editor, sent: true);
            if (folder.galleryCount == null ||
                contents.length != folder.galleryCount) {
              throw const UploadFailure(UploadFailureKind.resultUncertain,
                  serverMessage:
                      'The complete managed-gallery list could not be verified.');
            }
            rows.addAll(contents);
          }
          _current(accountId, prepared.revision, fresh.editor, sent: true);
          if (rows.any((g) =>
              uploadGalleryId(g.managementUri) ==
              uploadGalleryId(fresh.editorUri))) {
            throw const UploadFailure(UploadFailureKind.resultUncertain);
          }
          return UploadActionResult(prepared.action,
              manager: manager, publicUri: publicGallery(fresh.editor));
        } on UploadFailure catch (error) {
          if (error.kind == UploadFailureKind.protocolChanged ||
              error.kind == UploadFailureKind.network ||
              error.kind == UploadFailureKind.sessionChanged) {
            throw const UploadFailure(UploadFailureKind.resultUncertain);
          }
          rethrow;
        }
      });

  /// Recognizes only the captured unpublished-gallery confirmation page.
  /// Unknown controls, identities or wording never authorize a follow-up POST.
  UploadForm? _deleteConfirmation(
      String body, Uri responseUri, PreparedUploadAction prepared) {
    final doc = html.parse(body);
    final forms = doc.querySelectorAll('form');
    if (forms.isEmpty) {
      return null; // A direct result still needs manager proof.
    }
    final id = uploadGalleryId(prepared.editorUri)!;
    if (!_matches(responseUri, id, UploadGalleryAction.delete) ||
        !unpublished(prepared.editor) ||
        forms.length != 1) {
      throw const UploadFailure(UploadFailureKind.resultUncertain);
    }
    repository.protocol.document(body); // Reject login or error-page forms.
    // The captured confirmation page has no apiuid/apikey declarations.
    // Ownership is established by the bound editor reads before and after it.
    final element = forms.single;
    final form = repository.protocol.form(element, responseUri);
    final container = element.parent;
    final titles = container?.querySelectorAll('strong') ?? <Element>[];
    final controls = element.children;
    final title = prepared.editor.form.fields['gname_en']?.value;
    if (!_matches(form.action, id, UploadGalleryAction.delete) ||
        form.action.queryParameters.keys
            .any((key) => !{'act', 'ulgid'}.contains(key)) ||
        form.multipart ||
        (element.attributes['enctype'] != null &&
            element.attributes['enctype'] !=
                'application/x-www-form-urlencoded') ||
        container?.localName != 'div' ||
        !container!.classes.contains('d') ||
        !container.text.contains(
            'Please confirm that you wish to delete this unpublished gallery.') ||
        !container.text.contains('This action cannot be undone.') ||
        titles.length != 1 ||
        title == null ||
        titles.single.text.trim() != title.trim() ||
        controls.length != 2 ||
        controls.any((control) =>
            control.localName != 'input' ||
            control.attributes.keys
                .any((key) => !{'type', 'name', 'value'}.contains(key))) ||
        form.fields.length != 2 ||
        form.fields['qa_cancel']?.type != 'submit' ||
        form.fields['qa_cancel']?.values.singleOrNull != 'Cancel' ||
        form.fields['qa_delete']?.type != 'submit' ||
        form.fields['qa_delete']?.values.singleOrNull != 'Delete') {
      throw const UploadFailure(UploadFailureKind.resultUncertain);
    }
    // Browser submitter semantics: only the chosen button is successful.
    return UploadForm(action: form.action, fields: {
      'qa_delete': UploadField(
          name: 'qa_delete',
          type: 'hidden',
          values: form.fields['qa_delete']!.values),
    });
  }

  Future<UploadStatsSnapshot> stats(String accountId, Uri editorUri) async {
    final revision = repository.client.cookies.sessionRevision;
    final page = await repository.client.get(editorUri);
    final editor = repository.protocol.editor(page.body, page.uri);
    _current(accountId, revision, editor);
    final doc = repository.protocol.document(page.body);
    Uri? destination;
    for (final control in doc.querySelectorAll('td#d a')) {
      if (!control.text.toLowerCase().contains('stats')) continue;
      destination = _controlUri(control, page.uri);
      if (destination != null) break;
    }
    if (destination == null) {
      throw const UploadFailure(UploadFailureKind.restricted,
          serverMessage:
              'The website does not currently offer gallery statistics.');
    }
    final gallery = publicGallery(editor);
    if (gallery == null ||
        destination.queryParameters['gid'] != gallery.pathSegments[1]) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final response = await repository.client.getStatistics(destination);
    _current(accountId, revision, editor);
    final statistics = repository.protocol.document(response.body);
    for (final node
        in statistics.querySelectorAll('script,style,nav,#nb,#lb')) {
      node.remove();
    }
    final tables = <List<List<String>>>[];
    for (final table in statistics.querySelectorAll('table')) {
      final rows = <List<String>>[];
      for (final row in table.querySelectorAll('tr').take(150)) {
        final values = row.children
            .where((e) => {'td', 'th'}.contains(e.localName))
            .take(12)
            .map((e) => e.text.replaceAll(RegExp(r'\s+'), ' ').trim())
            .toList();
        if (values.any((s) => s.isNotEmpty)) rows.add(values);
      }
      if (rows.isNotEmpty) tables.add(rows);
      if (tables.length >= 12) break;
    }
    final notes = statistics
        .querySelectorAll('p')
        .take(30)
        .map((e) => e.text.trim())
        .where((text) => text.isNotEmpty)
        .toList();
    if (tables.isEmpty && notes.isEmpty) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    return UploadStatsSnapshot(
        uri: response.uri,
        title: editor.form.fields['gname_en']?.value ?? '',
        tables: tables,
        notes: notes);
  }
}
