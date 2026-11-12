import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

final uploadOrigin = Uri.https('upld.e-hentai.org', '/');

enum UploadFailureKind {
  loginRequired,
  sessionChanged,
  network,
  restricted,
  protocolChanged,
  resultUncertain,
}

class UploadFailure implements Exception {
  final UploadFailureKind kind;
  final String? serverMessage;
  final String? code;
  const UploadFailure(this.kind, {this.serverMessage, this.code});

  // Deliberately omit response bodies, private gallery URLs and form secrets.
  @override
  String toString() => 'UploadFailure(${kind.name})';
}

bool isUploadUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == uploadOrigin.host &&
    uri.userInfo.isEmpty &&
    uri.port == 443;

Uri requireUploadUri(Uri uri) {
  if (!isUploadUri(uri)) {
    throw const UploadFailure(UploadFailureKind.protocolChanged);
  }
  return uri.removeFragment();
}

class UploadOption {
  final String value;
  final String label;
  final bool disabled;
  const UploadOption(this.value, this.label, {this.disabled = false});
}

/// A control from the current server form, not the reader's category model.
class UploadField {
  final String name;
  final String type;
  final List<String> values;
  final List<UploadOption> options;
  final bool disabled;
  final bool readOnly;
  final int? maxLength;

  const UploadField({
    required this.name,
    required this.type,
    this.values = const [],
    this.options = const [],
    this.disabled = false,
    this.readOnly = false,
    this.maxLength,
  });

  String get value => values.isEmpty ? '' : values.first;
  bool get canEdit => !disabled && !readOnly && type != 'hidden';
}

class UploadForm {
  final Uri action;
  final bool multipart;
  final Map<String, UploadField> fields;
  const UploadForm(
      {required this.action, required this.fields, this.multipart = false});

  /// Preserve unknown successful controls. Tokens stay in memory only.
  Map<String, List<String>> submission(Map<String, List<String>> edits) {
    final result = <String, List<String>>{};
    for (final field in fields.values) {
      if (field.disabled ||
          const {'file', 'submit', 'button', 'reset'}.contains(field.type)) {
        continue;
      }
      result[field.name] = List.of(field.values);
    }
    for (final entry in edits.entries) {
      final field = fields[entry.key];
      if (field == null || !field.canEdit) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
      if (field.maxLength != null &&
          entry.value.any((v) => v.runes.length > field.maxLength!)) {
        throw ArgumentError('Upload field exceeds its current server limit');
      }
      if (field.options.isNotEmpty &&
          entry.value.any((value) =>
              !field.options.any((o) => o.value == value && !o.disabled))) {
        throw ArgumentError('Upload option is not currently available');
      }
      if (field.type == 'checkbox' &&
          (entry.value.length > 1 ||
              entry.value.any((v) =>
                  v != field.value &&
                  !field.options.any((o) => o.value == v)))) {
        throw ArgumentError('Invalid checkbox value');
      }
      result[entry.key] = List.of(entry.value);
    }
    return result;
  }
}

class UploadApiSession {
  final int uid;
  final String key;
  const UploadApiSession(this.uid, this.key);

  Map<String, Object> request(String method, Map<String, Object> arguments) {
    if (key == 'local-receipt-key') {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    return {
      ...arguments,
      'method': method,
      'apiuid': uid,
      'apikey': key,
    };
  }

  @override
  String toString() => 'UploadApiSession(redacted)';
}

class UploadButton {
  final String label;
  final bool enabled;
  final String? reason;
  const UploadButton(this.label, this.enabled, this.reason);
}

class RemoteUploadImage {
  final int page;
  final String positionField;
  final int position;
  final String name;
  final Uri? thumbnail;
  final int? fileIndex;
  const RemoteUploadImage(
      {required this.page,
      required this.positionField,
      required this.position,
      required this.name,
      this.thumbnail,
      this.fileIndex});
}

class UploadEditorSnapshot {
  final Uri uri;
  final UploadForm form;
  final UploadForm? reorderForm;
  final UploadApiSession api;
  final Map<String, UploadButton> buttons;
  final List<RemoteUploadImage> images;
  final Map<String, String> metadata;
  final Map<String, Uri> links;
  const UploadEditorSnapshot(
      {required this.uri,
      required this.form,
      required this.api,
      required this.buttons,
      required this.images,
      required this.metadata,
      required this.links,
      this.reorderForm});

  bool get isNew => uri.queryParameters['act'] == 'new';
  bool get canUpload => buttons['uploadbutton']?.enabled == true;
  bool get canPublish => buttons['publishbutton']?.enabled == true;
}

enum ManagedUploadPublication { unpublished, published, unknown }

class ManagedUploadGallery {
  final String title;
  final String date;
  final String category;
  final int fileCount;
  final String section;
  final Map<String, Uri> actions;
  final String? selectionName;
  final String? selectionValue;
  final bool selectionEnabled;
  final int? folderId;
  final String? sectionLabel;
  const ManagedUploadGallery(
      {required this.title,
      required this.date,
      required this.category,
      required this.fileCount,
      required this.section,
      required this.actions,
      this.selectionName,
      this.selectionValue,
      this.selectionEnabled = true,
      this.folderId,
      this.sectionLabel});

  Uri? get managementUri {
    for (final uri in actions.values) {
      if (isUploadUri(uri) &&
          uri.path == '/managegallery' &&
          !uri.queryParameters.containsKey('act')) return uri;
    }
    return null;
  }

  bool get canSelect =>
      selectionEnabled &&
      selectionName != null &&
      selectionValue != null &&
      managementUri != null;
  String get selectionKey => '$selectionName:$selectionValue';
  bool get isPrivate => {'private', 'private/unlisted', '(private/unlisted)'}
      .contains(category.toLowerCase().replaceAll(RegExp(r'\s+'), ''));
  ManagedUploadPublication get publication {
    final label = sectionLabel?.trim().toLowerCase();
    if (label == 'unpublished galleries' ||
        ((label == null || label.isEmpty) && section == 'u')) {
      return ManagedUploadPublication.unpublished;
    }
    if (label == 'published galleries') {
      return ManagedUploadPublication.published;
    }
    return ManagedUploadPublication.unknown;
  }
}

class UploadFolderSection {
  final String state;
  final int folderId;
  final String label;
  final bool collapsed;
  final int? galleryCount;
  const UploadFolderSection(
      this.state, this.folderId, this.label, this.collapsed,
      {this.galleryCount});
}

class ManagedUploadFolder {
  final int id;
  final String name;
  final String position;
  final UploadField nameField;
  final UploadField positionField;
  final bool canDelete;
  const ManagedUploadFolder(
      {required this.id,
      required this.name,
      required this.position,
      required this.nameField,
      required this.positionField,
      required this.canDelete});
}

class UploadFoldersSnapshot {
  final UploadForm form;
  final List<ManagedUploadFolder> folders;
  final String? accountId;
  final int? sessionRevision;
  const UploadFoldersSnapshot(
      {required this.form,
      required this.folders,
      this.accountId,
      this.sessionRevision});
}

enum UploadBulkStatus { completed, skipped, failed, uncertain, notExecuted }

class UploadBulkItemResult {
  final ManagedUploadGallery target;
  final UploadBulkStatus status;
  final String? reason;
  const UploadBulkItemResult(this.target, this.status, {this.reason});
}

class UploadBulkResult {
  final List<UploadBulkItemResult> items;
  UploadBulkResult(List<UploadBulkItemResult> items)
      : items = List.unmodifiable(items);
}

class UploadManagerSnapshot {
  final UploadForm form;
  final UploadApiSession api;
  final List<ManagedUploadGallery> galleries;
  final List<UploadFolderSection> folders;
  final String sort;
  final String direction;
  final Map<String, String> sectionLabels;
  const UploadManagerSnapshot(
      {required this.form,
      required this.api,
      required this.galleries,
      required this.folders,
      required this.sort,
      required this.direction,
      this.sectionLabels = const {}});
}

class UploadProtocol {
  const UploadProtocol();

  Document document(String source) {
    final doc = html.parse(source);
    final title = doc.querySelector('title')?.text ?? '';
    if (title.contains('E-Hentai.org Login') ||
        doc.querySelector('input[type="password"]') != null) {
      throw const UploadFailure(UploadFailureKind.loginRequired);
    }
    final errors = doc
        .querySelectorAll('#e, p.e')
        .map((e) => e.text.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (errors.isNotEmpty) {
      throw UploadFailure(UploadFailureKind.restricted,
          serverMessage: errors.join('\n'));
    }
    return doc;
  }

  UploadApiSession api(Document doc) {
    final scripts =
        doc.querySelectorAll('script').map((e) => e.text).join('\n');
    final uid = RegExp(r'\bvar\s+apiuid\s*=\s*(\d+)\s*;').firstMatch(scripts);
    final key = RegExp(r'''\bvar\s+apikey\s*=\s*["']([^"']+)["']\s*;''')
        .firstMatch(scripts);
    if (uid == null || key == null || key[1]!.contains('[REDACTED]')) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    return UploadApiSession(int.parse(uid[1]!), key[1]!);
  }

  UploadForm form(Element element, Uri current) {
    if ((element.attributes['method'] ?? 'get').toLowerCase() != 'post') {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final action =
        requireUploadUri(current.resolve(element.attributes['action'] ?? ''));
    final grouped = <String, List<Element>>{};
    for (final control in element.querySelectorAll(
        'input[name],select[name],textarea[name],button[name]')) {
      final name = control.attributes['name']!;
      grouped.putIfAbsent(name, () => []).add(control);
    }
    final fields = <String, UploadField>{};
    for (final group in grouped.entries) {
      final first = group.value.first;
      final type = first.localName == 'input'
          ? (first.attributes['type'] ?? 'text').toLowerCase()
          : first.localName!;
      final disabled =
          group.value.every((e) => e.attributes.containsKey('disabled'));
      final options = <UploadOption>[];
      final values = <String>[];
      for (final e in group.value) {
        final off = e.attributes.containsKey('disabled');
        if (type == 'select') {
          final choices = e.querySelectorAll('option');
          for (final option in choices) {
            final value = option.attributes['value'] ?? option.text;
            final disabledOption = option.attributes.containsKey('disabled') ||
                (option.parent?.localName == 'optgroup' &&
                    option.parent!.attributes.containsKey('disabled'));
            options.add(UploadOption(value, option.text.trim(),
                disabled: disabledOption));
            if (option.attributes.containsKey('selected')) values.add(value);
          }
          if (values.isEmpty && !e.attributes.containsKey('multiple')) {
            final available = options.where((o) => !o.disabled);
            if (available.isNotEmpty) values.add(available.first.value);
          }
        } else if (type == 'checkbox' || type == 'radio') {
          final value = e.attributes['value'] ?? 'on';
          options.add(
              UploadOption(value, e.parent?.text.trim() ?? '', disabled: off));
          if (e.attributes.containsKey('checked')) values.add(value);
        } else if (type != 'file') {
          values.add(type == 'textarea' ? e.text : e.attributes['value'] ?? '');
        }
      }
      fields[group.key] = UploadField(
          name: group.key,
          type: type,
          values: List.unmodifiable(values),
          options: List.unmodifiable(options),
          disabled: disabled,
          readOnly: first.attributes.containsKey('readonly'),
          maxLength: int.tryParse(first.attributes['maxlength'] ?? ''));
    }
    return UploadForm(
        action: action,
        fields: Map.unmodifiable(fields),
        multipart: element.attributes['enctype'] == 'multipart/form-data');
  }

  UploadEditorSnapshot editor(String source, Uri current) {
    requireUploadUri(current);
    final doc = document(source);
    final upload = doc.querySelector('form#uploadform');
    if (upload == null) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final parsed = form(upload, current);
    final editorAction = parsed.action.queryParameters['act'];
    if (editorAction != null &&
        editorAction.isNotEmpty &&
        editorAction != 'new') {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    for (final field in ['gname_en', 'category', 'ulcomment', 'do_save']) {
      if (!parsed.fields.containsKey(field)) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
    }
    final buttons = <String, UploadButton>{};
    for (final id in [
      'savebutton',
      'uploadbutton',
      'publishbutton',
      'unlockbutton',
      'reorder_manual',
      'reorder_auto',
      'reorder_revert',
    ]) {
      final button = doc.getElementById(id);
      if (button != null) {
        buttons[id] = UploadButton(
            button.attributes['value'] ?? button.text,
            !button.attributes.containsKey('disabled'),
            button.attributes['title']);
      }
    }
    final metadata = <String, String>{};
    for (final row in doc.querySelectorAll('td#d tr')) {
      final key = row.querySelector('td.k');
      final value = row.querySelector('td.v');
      if (key != null && value != null) {
        metadata[key.text.trim().replaceFirst(RegExp(r':$'), '')] =
            value.text.trim();
      }
    }
    final images = <RemoteUploadImage>[];
    for (final input
        in doc.querySelectorAll('#reorderform input[id^="pagesel_"]')) {
      final page = int.tryParse(input.id.substring('pagesel_'.length));
      final position = int.tryParse(input.attributes['value'] ?? '');
      final name = input.attributes['name'];
      if (page == null || position == null || name == null) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
      final cell = doc.getElementById('cell_$page');
      final thumb = doc.getElementById('thumb_$page');
      final preview =
          RegExp(r'view_image_init\(\s*\d+\s*,\s*\d+\s*,\s*(\d+)\s*\)')
              .firstMatch(thumb?.attributes['onclick'] ?? '');
      final uri = Uri.tryParse(thumb?.attributes['src'] ?? '');
      images.add(RemoteUploadImage(
          page: page,
          positionField: name,
          position: position,
          name: cell?.querySelector('div.n')?.text.trim() ?? '',
          thumbnail: uri?.scheme == 'https' ? uri : null,
          fileIndex: preview == null ? null : int.parse(preview[1]!)));
    }
    final reorder = doc.querySelector('form#reorderform');
    return UploadEditorSnapshot(
        uri: parsed.action,
        form: parsed,
        api: api(doc),
        reorderForm: reorder == null ? null : form(reorder, current),
        buttons: Map.unmodifiable(buttons),
        images: List.unmodifiable(images),
        metadata: Map.unmodifiable(metadata),
        links: _links(doc.querySelector('td#d'), current));
  }

  UploadManagerSnapshot manager(String source) {
    final current = uploadOrigin.resolve('manage');
    final doc = document(source);
    final forms = doc.querySelectorAll('#m form').where(
        (e) => current.resolve(e.attributes['action'] ?? '').path == '/manage');
    if (forms.length != 1 ||
        doc.querySelector('#lb a[href*="managegallery"]') == null) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final galleries = <ManagedUploadGallery>[];
    final folders = <UploadFolderSection>[];
    final labels = <String, String>{};
    for (final table in doc.querySelectorAll('table[id^="gtable"]')) {
      final state = table.id.substring('gtable'.length);
      if (!RegExp(r'^[a-z]+$').hasMatch(state)) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
      int? currentFolder;
      final label = table.parent?.querySelector('div.h div.l')?.text.trim();
      if (label != null && label.isNotEmpty) labels[state] = label;
      for (final row in table.querySelectorAll('tr')) {
        final folder = RegExp(r'^frow_([a-z]+)_(\d+)$').firstMatch(row.id);
        if (folder != null) {
          final id = int.parse(folder[2]!);
          currentFolder = id;
          folders.add(UploadFolderSection(
              state,
              id,
              row.querySelector('td.l span')?.text.trim() ?? row.text.trim(),
              doc.getElementById('ft_${state}_$id')?.text.trim() == '[+]',
              galleryCount: int.tryParse(
                  row.querySelector('td.l strong')?.text.trim() ?? '')));
        } else if (row.querySelector('td.gtc1') != null) {
          galleries.add(galleryRow(row, state, current,
              folderId: currentFolder, sectionLabel: label));
        }
      }
    }
    final script = doc.querySelectorAll('script').map((e) => e.text).join('\n');
    String variable(String name, String fallback) =>
        RegExp('var\\s+$name\\s*=\\s*["\']([a-z])["\']')
            .firstMatch(script)?[1] ??
        fallback;
    return UploadManagerSnapshot(
        form: form(forms.single, current),
        api: api(doc),
        galleries: List.unmodifiable(galleries),
        folders: List.unmodifiable(folders),
        sort: variable('ss', 'd'),
        direction: variable('sd', 'a'),
        sectionLabels: Map.unmodifiable(labels));
  }

  ManagedUploadGallery galleryRow(Element row, String section, Uri current,
      {int? folderId, String? sectionLabel}) {
    final actions = _links(row.querySelector('td.gtc5'), current);
    final title = row.querySelector('td.gtc1')?.text.trim();
    final count = int.tryParse(
        row.querySelector('td.gtc3')?.text.trim().replaceAll(',', '') ?? '');
    if (title == null || count == null || actions.isEmpty) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final checkbox = row.querySelector('input[type="checkbox"][name]');
    return ManagedUploadGallery(
        title: title,
        date: row.querySelector('td.gtc2')?.text.trim() ?? '',
        category: row.querySelector('td.gtc4')?.text.trim() ?? '',
        fileCount: count,
        section: section,
        actions: actions,
        selectionName: checkbox?.attributes['name'],
        selectionValue: checkbox?.attributes['value'],
        selectionEnabled:
            checkbox != null && !checkbox.attributes.containsKey('disabled'),
        folderId: folderId,
        sectionLabel: sectionLabel);
  }

  UploadFoldersSnapshot folders(String source) {
    final current = uploadOrigin.resolve('managefolders');
    final doc = document(source);
    final element = doc.querySelector('form#folderform');
    if (element == null) {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final parsed = form(element, current);
    if (parsed.action != current ||
        !['do_save', 'do_delete', 'do_autosort']
            .every((name) => parsed.fields[name]?.type == 'hidden') ||
        parsed.fields['fname']?.type != 'text') {
      throw const UploadFailure(UploadFailureKind.protocolChanged);
    }
    final deletable = <int>{};
    for (final link in element.querySelectorAll('a[onclick]')) {
      final match = RegExp(r'\bfolder_delete\(\s*(\d+)\s*\)')
          .firstMatch(link.attributes['onclick']!);
      if (match != null) deletable.add(int.parse(match[1]!));
    }
    final folders = <ManagedUploadFolder>[];
    for (final field in parsed.fields.values) {
      final match = RegExp(r'^fn(\d+)$').firstMatch(field.name);
      if (match == null) continue;
      final id = int.parse(match[1]!);
      final order = parsed.fields['fs$id'];
      if (id <= 0 ||
          field.type != 'text' ||
          order?.type != 'select' ||
          field.values.length != 1 ||
          order!.values.length != 1) {
        throw const UploadFailure(UploadFailureKind.protocolChanged);
      }
      folders.add(ManagedUploadFolder(
          id: id,
          name: field.value,
          position: order.value,
          nameField: field,
          positionField: order,
          canDelete: deletable.contains(id)));
    }
    return UploadFoldersSnapshot(
        form: parsed, folders: List.unmodifiable(folders));
  }

  Map<String, Uri> _links(Element? root, Uri current) {
    final links = <String, Uri>{};
    for (final link in root?.querySelectorAll('a[href]') ?? <Element>[]) {
      final uri = current.resolve(link.attributes['href']!);
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443 ||
          !{uploadOrigin.host, 'e-hentai.org', 'exhentai.org'}
              .contains(uri.host)) continue;
      final label = link.text.trim();
      if (label.isNotEmpty) links[label] = uri;
    }
    return Map.unmodifiable(links);
  }
}
