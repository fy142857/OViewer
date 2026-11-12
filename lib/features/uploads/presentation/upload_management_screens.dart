import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../blocs/auth/auth_bloc.dart';
import '../../../blocs/auth/auth_state.dart';
import '../../../core/router/app_page_route.dart';
import '../data/upload_protocol.dart';
import '../data/upload_repository.dart';
import '../files/upload_asset_preparer.dart';
import '../files/upload_file_io.dart';
import '../rules/rule_notice.dart';
import '../rules/upload_rules.dart';
import '../upload_services.dart';
import 'upload_editor_screen.dart';
import 'upload_web_page.dart';

/// This displays the server snapshot fetched before the confirmation dialog.
class UploadVisibilitySummary extends StatelessWidget {
  final UploadVisibilityConsent consent;
  final Future<void> Function(Uri) onOpenSource;
  const UploadVisibilitySummary(
      {super.key, required this.consent, required this.onOpenSource});
  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String l(String cn, String en) => zh ? cn : en;
    final editor = consent.editor;
    final target = editor.form.fields['category']?.options
        .where((o) => o.value == consent.targetCategory)
        .firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(editor.form.fields['gname_en']?.value ?? '',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      Text(
          '${l('上传管理编号', 'Upload management ID')}: ${consent.uri.queryParameters['ulgid']}'),
      Text(l('私人／不公开列出 → ${target?.label ?? consent.targetCategory}',
          'Private / Unlisted → ${target?.label ?? consent.targetCategory}')),
      Text(
          '${l('站内图片数', 'Website images')}: ${editor.metadata['Uploaded Files'] ?? editor.images.length}'),
      if (editor.images.isNotEmpty) ...[
        Text('${l('首页', 'First')}: ${editor.images.first.name}'),
        Text('${l('末页', 'Last')}: ${editor.images.last.name}'),
      ],
      Text(l('此画廊已发布。保存为公开分类会使它公开列出；公开后不能再转回私人／不公开列出。',
          'This gallery is already published. Saving a public category makes it publicly listed. It cannot be made private or unlisted afterward.')),
      RuleNotices(
          location: UploadRuleLocation.visibility, onOpenSource: onOpenSource),
    ]);
  }
}

abstract class _AccountManagementState<T extends StatefulWidget>
    extends State<T> {
  String get accountId;
  UploadServices get services;
  late final AuthBloc _auth;
  late final int _generation;
  StreamSubscription<AuthState>? _authChanges;
  ModalRoute<dynamic>? _route;
  bool invalidated = false;
  bool busy = false;
  bool needsReconcile = false;
  bool _leaving = false;
  bool _openingWebsite = false;
  bool get hasUnsavedChanges => false;
  Future<void> Function()? get websiteRefresh => null;
  Object? error;
  bool get current =>
      mounted &&
      !invalidated &&
      _auth.state.isLoggedIn &&
      _auth.state.profile.memberId == accountId &&
      _auth.state.sessionGeneration == _generation;
  bool get zh => Localizations.localeOf(context).languageCode == 'zh';
  String l(String cn, String en) => zh ? cn : en;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthBloc>();
    _generation = _auth.state.sessionGeneration;
    _authChanges = _auth.stream.listen((_) {
      if (!current) _invalidate();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current) _invalidate();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  void _invalidate() {
    if (!mounted || invalidated) return;
    setState(() => invalidated = true);
    onInvalidated();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _route?.isActive != true) return;
      final navigator = Navigator.of(context);
      navigator.popUntil((route) => identical(route, _route) || route.isFirst);
      if (_route?.isCurrent == true && navigator.canPop()) navigator.pop();
    });
  }

  void onInvalidated() {}
  Future<void> run(Future<void> Function() action) async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (current) {
        setState(() {
          error = failure;
          if (failure is UploadFailure &&
              failure.kind == UploadFailureKind.resultUncertain) {
            needsReconcile = true;
          }
        });
      }
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> source(Uri uri) async {
    if (!current) return;
    if (uri.host != uploadOrigin.host) {
      await services.openExternal(uri);
      return;
    }
    if (_openingWebsite || busy) return;
    if (hasUnsavedChanges) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l('请先保存或撤销当前页面的修改，再进入官方网页。',
              'Save or undo this page’s changes before opening the official website.'))));
      return;
    }
    _openingWebsite = true;
    int? handoff;
    var returnToParent = false;
    final navigator = Navigator.of(context);
    try {
      await navigator.push<void>(AppPageRoute<void>(
          builder: (_) => UploadWebPage(
                url: uri,
                cookies: services.cookies,
                auth: _auth,
                beforeOpen: () async {
                  if (!current) {
                    throw const UploadFailure(UploadFailureKind.sessionChanged);
                  }
                  handoff = await services.prepareWebHandoff();
                },
                afterClose: () async {
                  try {
                    if (!current) return;
                    returnToParent = true;
                    final refresh = websiteRefresh;
                    if (refresh != null) {
                      setState(() => needsReconcile = true);
                      await refresh();
                      if (current && error == null) {
                        setState(() => needsReconcile = false);
                        returnToParent = false;
                      }
                    } else {
                      // Frozen batch/reconciliation screens must not reuse their old
                      // form snapshots after the user has edited through the website.
                      await services.repository.manager(accountId);
                    }
                  } finally {
                    if (handoff != null) {
                      await services.endWebHandoff(generation: handoff);
                    }
                  }
                },
              )));
      if (current && returnToParent && _route?.isActive == true) {
        navigator
            .popUntil((route) => identical(route, _route) || route.isFirst);
        if (_route?.isCurrent == true && navigator.canPop()) navigator.pop();
      }
    } finally {
      _openingWebsite = false;
    }
  }

  Widget rule(UploadRuleId id) =>
      RuleNotice(rule: UploadRules.byId(id), onOpenSource: source);
  Widget get status =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (needsReconcile)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l('上次操作结果待核对。请重新读取站点状态后再操作；读取成功后将用站内结果替换此页尚未保存的修改。',
                  'The previous result is uncertain. Reload website state before another action; a successful reload replaces unsaved edits on this page with the website result.'))),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(uploadFailureMessage(error!, zh))),
      ]);
  Widget guard(Widget page) => !current
      ? Scaffold(
          appBar: AppBar(),
          body:
              Center(child: Text(l('登录状态已改变。', 'The login session changed.'))))
      : PopScope(
          canPop: !busy && !hasUnsavedChanges,
          onPopInvoked: (didPop) {
            if (!didPop && busy) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(l('正在确认站点结果；完成后可返回。批量操作可停止尚未发送的项目。',
                      'Waiting for the website result. Return after it finishes; bulk actions can stop unsent items.'))));
            } else if (!didPop && hasUnsavedChanges) {
              _confirmLeave();
            }
          },
          child: page);
  Future<void> _confirmLeave() async {
    if (_leaving || !current) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    try {
      final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text(l('有未保存的修改', 'Unsaved changes')),
                content: Text(l('这些修改尚未提交站点。返回将放弃它们。',
                    'These changes have not reached the website. Leaving discards them.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(l('继续编辑', 'Keep editing'))),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l('放弃并返回', 'Discard and leave')))
                ],
              ));
      if (discard == true && current && _route?.isCurrent == true) {
        navigator.pop();
      }
    } finally {
      _leaving = false;
    }
  }

  @override
  void dispose() {
    _authChanges?.cancel();
    super.dispose();
  }
}

class UploadFoldersScreen extends StatefulWidget {
  final String accountId;
  final UploadServices? services;
  const UploadFoldersScreen(
      {super.key, required this.accountId, this.services});
  @override
  State<UploadFoldersScreen> createState() => _UploadFoldersScreenState();
}

class _UploadFoldersScreenState
    extends _AccountManagementState<UploadFoldersScreen> {
  @override
  String get accountId => widget.accountId;
  late final UploadServices _services;
  @override
  UploadServices get services => _services;
  @override
  Future<void> Function()? get websiteRefresh => _load;
  UploadFoldersSnapshot? _snapshot;
  final _names = <int, TextEditingController>{};
  final _newName = TextEditingController();
  List<int> _order = [];
  @override
  bool get hasUnsavedChanges => _changed;

  @override
  void initState() {
    _services = widget.services ?? GetIt.I<UploadServices>();
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (current) _load();
    });
  }

  void _apply(UploadFoldersSnapshot value) {
    needsReconcile = false;
    for (final controller in _names.values) {
      controller.dispose();
    }
    _names.clear();
    _snapshot = value;
    final sorted = List<ManagedUploadFolder>.of(value.folders)
      ..sort((a, b) => (int.tryParse(a.position) ?? 0)
          .compareTo(int.tryParse(b.position) ?? 0));
    _order = sorted.map((folder) => folder.id).toList();
    for (final folder in value.folders) {
      _names[folder.id] = TextEditingController(text: folder.name);
    }
    _newName.clear();
  }

  bool get _changed =>
      _snapshot != null &&
      (_newName.text.trim().isNotEmpty ||
          _snapshot!.folders.any((folder) =>
              _names[folder.id]!.text.trim() != folder.name ||
              _order.indexOf(folder.id) + 1 != int.tryParse(folder.position)));
  bool get _valid =>
      _snapshot != null &&
      _snapshot!.folders.every((folder) {
        final name = _names[folder.id]!.text.trim();
        return name.isNotEmpty &&
            (folder.nameField.maxLength == null ||
                name.runes.length <= folder.nameField.maxLength!);
      }) &&
      (_snapshot!.form.fields['fname']!.maxLength == null ||
          _newName.text.trim().runes.length <=
              _snapshot!.form.fields['fname']!.maxLength!);
  Future<void> _load() => run(() async {
        final loaded = await services.repository.folders(accountId);
        if (current) setState(() => _apply(loaded));
      });
  Future<void> _save() => run(() async {
        final baseline = _snapshot!;
        final renamed = {
          for (final folder in baseline.folders)
            if (_names[folder.id]!.text.trim() != folder.name)
              folder.id: _names[folder.id]!.text.trim()
        };
        final orderChanged = baseline.folders.any((folder) =>
            _order.indexOf(folder.id) + 1 != int.tryParse(folder.position));
        final saved = await services.repository.saveFolders(accountId, baseline,
            renamed: renamed,
            orderedIds: orderChanged ? List.of(_order) : null,
            newName:
                _newName.text.trim().isEmpty ? null : _newName.text.trim());
        if (current) setState(() => _apply(saved));
      });
  Future<void> _delete(ManagedUploadFolder folder) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(l('删除空目录', 'Delete empty folder')),
              content: Text(
                  '${folder.name}\n${l('操作前会重新检查目录是否为空。请勿同时在其他设备移动画廊。', 'The folder is checked again before deletion. Do not move galleries from another device at the same time.')}'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l('取消', 'Cancel'))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l('删除空目录', 'Delete empty folder')))
              ],
            ));
    if (confirmed != true || !current) return;
    await run(() async {
      final saved =
          await services.repository.deleteEmptyFolder(accountId, folder.id);
      if (current) setState(() => _apply(saved));
    });
  }

  @override
  Widget build(BuildContext context) => guard(Scaffold(
        appBar: AppBar(title: Text(l('目录管理', 'Manage folders')), actions: [
          IconButton(
              tooltip: l('重新读取', 'Reload'),
              onPressed: busy || (_changed && !needsReconcile) ? null : _load,
              icon: const Icon(Icons.refresh)),
        ]),
        body: Column(children: [
          status,
          Expanded(
              child: _snapshot == null
                  ? Center(
                      child: TextButton(
                          onPressed: busy ? null : _load,
                          child: Text(l('读取目录', 'Load folders'))))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.all(16),
                      buildDefaultDragHandles: false,
                      header: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            rule(UploadRuleId.folders),
                            TextField(
                                key: const ValueKey('upload-folder-new'),
                                controller: _newName,
                                enabled: !busy &&
                                    !needsReconcile &&
                                    _snapshot!.form.fields['fname']!.canEdit,
                                maxLength:
                                    _snapshot!.form.fields['fname']!.maxLength,
                                decoration: InputDecoration(
                                    labelText: l('新目录名称', 'New folder name')),
                                onChanged: (_) => setState(() {})),
                            Text(l('拖动调整目录顺序；点击保存后才会修改站点。',
                                'Drag to reorder folders. Changes reach the website only when you save.')),
                            if (_changed)
                              Text(l('有未提交的目录修改；保存后再删除目录。',
                                  'There are unsaved folder changes. Save before deleting a folder.')),
                          ]),
                      itemCount: _order.length,
                      onReorder: (from, to) {
                        if (busy || needsReconcile) return;
                        if (to > from) to--;
                        setState(() {
                          final id = _order.removeAt(from);
                          _order.insert(to, id);
                        });
                      },
                      itemBuilder: (_, index) {
                        final id = _order[index];
                        final folder = _snapshot!.folders
                            .firstWhere((folder) => folder.id == id);
                        return Card(
                            key: ValueKey(id),
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(children: [
                                  Expanded(
                                      child: TextField(
                                          key: ValueKey(
                                              'upload-folder-name-$id'),
                                          controller: _names[id],
                                          enabled: !busy &&
                                              !needsReconcile &&
                                              folder.nameField.canEdit,
                                          maxLength: folder.nameField.maxLength,
                                          decoration: InputDecoration(
                                              labelText:
                                                  l('目录名称', 'Folder name')),
                                          onChanged: (_) => setState(() {}))),
                                  IconButton(
                                      tooltip:
                                          l('删除空目录', 'Delete empty folder'),
                                      onPressed: busy ||
                                              needsReconcile ||
                                              _changed ||
                                              !folder.canDelete
                                          ? null
                                          : () => _delete(folder),
                                      icon: const Icon(Icons.delete_outline)),
                                  if (!busy &&
                                      !needsReconcile &&
                                      folder.positionField.canEdit)
                                    ReorderableDragStartListener(
                                        index: index,
                                        child: const Icon(Icons.drag_handle)),
                                ])));
                      },
                    ))
        ]),
        bottomNavigationBar: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                    key: const ValueKey('upload-folders-save'),
                    onPressed: !busy && !needsReconcile && _changed && _valid
                        ? _save
                        : null,
                    child: Text(l('保存目录修改', 'Save folder changes'))))),
      ));
  @override
  void dispose() {
    _newName.dispose();
    for (final controller in _names.values) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// Selects an existing owned gallery explicitly; never guesses from a title.
class UploadGallerySelectionScreen extends StatefulWidget {
  final String accountId;
  final UploadServices? services;
  const UploadGallerySelectionScreen(
      {super.key, required this.accountId, this.services});
  @override
  State<UploadGallerySelectionScreen> createState() =>
      _UploadGallerySelectionScreenState();
}

class _UploadGallerySelectionScreenState
    extends _AccountManagementState<UploadGallerySelectionScreen> {
  @override
  String get accountId => widget.accountId;
  late final UploadServices _services;
  @override
  UploadServices get services => _services;
  @override
  Future<void> Function()? get websiteRefresh => _load;
  UploadManagerSnapshot? _manager;
  List<ManagedUploadGallery> _galleries = [];
  final _loadedFolders = <String>{};
  Uri? _selected;
  @override
  void initState() {
    _services = widget.services ?? GetIt.I<UploadServices>();
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (current) _load();
    });
  }

  Future<void> _load() => run(() async {
        final snapshot = await services.repository.manager(accountId);
        if (current) {
          setState(() {
            _manager = snapshot;
            _galleries = List.of(snapshot.galleries);
            _loadedFolders.clear();
            _selected = null;
          });
        }
      });
  Future<void> _folder(UploadFolderSection folder) => run(() async {
        final rows =
            await services.repository.folder(accountId, _manager!, folder);
        if (current) {
          setState(() {
            final known =
                _galleries.map((gallery) => gallery.managementUri).toSet();
            _galleries.addAll(rows.where((gallery) =>
                gallery.managementUri != null &&
                known.add(gallery.managementUri)));
            _loadedFolders.add('${folder.state}:${folder.folderId}');
          });
        }
      });
  @override
  Widget build(BuildContext context) => guard(Scaffold(
        appBar: AppBar(
            title: Text(l('选择对应的站内画廊', 'Choose the matching website gallery')),
            actions: [
              IconButton(
                  tooltip: l('刷新', 'Refresh'),
                  onPressed: busy ? null : _load,
                  icon: const Icon(Icons.refresh))
            ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          status,
          Text(l('不会根据同名自动关联。请核对标题、图片数、站点时间与画廊编号，选中上次操作对应的结果。',
              'Matching titles are not linked automatically. Check the title, image count, website time, and gallery ID, then select the result of your previous operation.')),
          for (final folder in _manager?.folders ?? <UploadFolderSection>[])
            if (folder.collapsed &&
                !_loadedFolders.contains('${folder.state}:${folder.folderId}'))
              ListTile(
                  title: Text(folder.label),
                  leading: const Icon(Icons.folder_outlined),
                  onTap: busy ? null : () => _folder(folder)),
          for (final gallery in _galleries)
            if (gallery.managementUri != null)
              RadioListTile<Uri>(
                  value: gallery.managementUri!,
                  groupValue: _selected,
                  title: Text(gallery.title),
                  subtitle: Text(
                      '${gallery.fileCount} ${l('张', 'images')} · GID ${gallery.managementUri!.queryParameters['ulgid']}\n${l('站点时间', 'Website time')}: ${gallery.date}'),
                  onChanged: busy
                      ? null
                      : (value) => setState(() => _selected = value)),
          if (_manager != null && _galleries.isEmpty && !busy)
            Text(l('已加载列表中没有画廊，可展开目录或刷新。',
                'No galleries in the loaded results. Expand a folder or refresh.')),
        ]),
        bottomNavigationBar: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                    key: const ValueKey('upload-pending-select-gallery'),
                    onPressed: !busy && _selected != null
                        ? () => Navigator.pop(context, _selected)
                        : null,
                    child: Text(l('核对选中的画廊', 'Review selected gallery'))))),
      ));
}

class UploadBulkScreen extends StatefulWidget {
  final String accountId;
  final UploadManagerSnapshot manager;
  final List<ManagedUploadGallery> targets;
  final bool category;
  final UploadServices? services;
  UploadBulkScreen(
      {super.key,
      required this.accountId,
      required this.manager,
      required List<ManagedUploadGallery> targets,
      required this.category,
      this.services})
      : targets = List.unmodifiable(targets);
  @override
  State<UploadBulkScreen> createState() => _UploadBulkScreenState();
}

class _UploadBulkScreenState extends _AccountManagementState<UploadBulkScreen> {
  @override
  String get accountId => widget.accountId;
  late final UploadServices _services;
  @override
  UploadServices get services => _services;
  String? _destination;
  bool _cancelled = false;
  UploadBulkResult? _result;
  @override
  void initState() {
    _services = widget.services ?? GetIt.I<UploadServices>();
    super.initState();
  }

  @override
  void onInvalidated() {
    _cancelled = true;
  }

  Future<void> _execute() async {
    if (_destination == null || busy || _result != null) return;
    final destination = _destination!;
    final choice = widget.manager.form
        .fields[widget.category ? 'publiccat' : 'folderid']!.options
        .firstWhere((option) => option.value == destination);
    await run(() async {
      final consents = widget.category
          ? await services.prepareBulkVisibilityChange(
              accountId, widget.targets, destination)
          : const <UploadVisibilityConsent>[];
      if (!mounted || !current || _cancelled) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text(l('确认批量操作', 'Confirm bulk action')),
                content: SizedBox(
                    width: double.maxFinite,
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          Text(l(
                              '${widget.targets.length} 个画廊 → ${choice.label}',
                              '${widget.targets.length} galleries → ${choice.label}')),
                          for (final target in widget.targets)
                            Text(target.title),
                          for (final consent in consents)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: UploadVisibilitySummary(
                                    consent: consent,
                                    onOpenSource: services.openExternal)),
                          rule(UploadRuleId.bulkActions),
                          if (widget.category)
                            rule(UploadRuleId.privateGallery),
                          if (widget.category &&
                              destination != '0' &&
                              widget.targets.any((target) => target.category
                                  .toLowerCase()
                                  .contains('private')))
                            rule(UploadRuleId.publication),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(l('取消', 'Cancel'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l('确认执行', 'Confirm')))
                ],
              ));
      if (confirmed != true || !current || _cancelled) return;
      final result = widget.category
          ? await services.bulkModifyWithVisibility(accountId, widget.targets,
              categoryValue: destination,
              consents: consents,
              isCancelled: () => _cancelled || !current)
          : await services.repository.bulkModify(accountId, widget.targets,
              folderId: int.parse(destination),
              isCancelled: () => _cancelled || !current);
      if (current) setState(() => _result = result);
    });
  }

  String _status(UploadBulkStatus status) => switch (status) {
        UploadBulkStatus.completed => l('成功', 'Completed'),
        UploadBulkStatus.skipped => l('已跳过', 'Skipped'),
        UploadBulkStatus.failed => l('失败', 'Failed'),
        UploadBulkStatus.uncertain => l('结果待核对', 'Result uncertain'),
        UploadBulkStatus.notExecuted => l('未执行', 'Not executed'),
      };
  @override
  Widget build(BuildContext context) {
    if (_result != null) {
      return guard(Scaffold(
        appBar: AppBar(title: Text(l('批量操作结果', 'Bulk action results'))),
        body: ListView(
            key: const ValueKey('upload-bulk-results'),
            padding: const EdgeInsets.all(16),
            children: [
              for (final status in UploadBulkStatus.values)
                if (_result!.items.any((item) => item.status == status))
                  Text(
                      '${_status(status)}: ${_result!.items.where((item) => item.status == status).length}'),
              for (final item in _result!.items)
                ListTile(
                    title: Text(item.target.title),
                    subtitle: Text(
                        '${_status(item.status)}${item.reason == null ? '' : '\n${item.reason}'}')),
              rule(UploadRuleId.bulkActions),
            ]),
        bottomNavigationBar: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                    onPressed: () => Navigator.maybePop(context),
                    child: Text(l('返回画廊列表', 'Back to galleries'))))),
      ));
    }
    final field =
        widget.manager.form.fields[widget.category ? 'publiccat' : 'folderid'];
    return guard(Scaffold(
      appBar: AppBar(
          title: Text(widget.category
              ? l('批量修改分类', 'Change categories')
              : l('批量移动目录', 'Move to folder'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        status,
        rule(UploadRuleId.bulkActions),
        if (widget.category)
          rule(UploadRuleId.editing)
        else
          rule(UploadRuleId.folders),
        Text(l('已冻结 ${widget.targets.length} 个目标；不会自动加入其他画廊。',
            '${widget.targets.length} targets are frozen; other galleries will not be added.')),
        if (field != null)
          DropdownButtonFormField<String>(
              key: const ValueKey('upload-bulk-destination'),
              value: _destination,
              isExpanded: true,
              decoration: InputDecoration(labelText: l('目标', 'Destination')),
              hint: Text(l('请选择', 'Choose an option')),
              items: [
                for (final option in field.options)
                  DropdownMenuItem(
                      value: option.value,
                      enabled: !option.disabled,
                      child:
                          Text(option.label, overflow: TextOverflow.ellipsis))
              ],
              onChanged: busy || _result != null || !field.canEdit
                  ? null
                  : (value) => setState(() => _destination = value)),
        for (final target in widget.targets)
          ListTile(title: Text(target.title), subtitle: Text(target.category)),
        if (_result != null) ...[
          Text(l('执行结果', 'Results'),
              style: Theme.of(context).textTheme.titleLarge),
          for (final result in _result!.items)
            ListTile(
                title: Text(result.target.title),
                subtitle: Text(
                    '${_status(result.status)}${result.reason == null ? '' : '\n${result.reason}'}')),
        ],
      ]),
      bottomNavigationBar: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: busy
                  ? OutlinedButton(
                      onPressed: _cancelled
                          ? null
                          : () => setState(() => _cancelled = true),
                      child: Text(l('停止尚未发送的项目', 'Stop unsent items')))
                  : FilledButton(
                      key: const ValueKey('upload-bulk-execute'),
                      onPressed: _destination != null && _result == null
                          ? _execute
                          : null,
                      child: Text(l('核对并执行', 'Review and execute'))))),
    ));
  }
}

class UploadReceiptReviewScreen extends StatefulWidget {
  final String accountId;
  final String receiptId;
  final UploadServices? services;
  const UploadReceiptReviewScreen(
      {super.key,
      required this.accountId,
      required this.receiptId,
      this.services});
  @override
  State<UploadReceiptReviewScreen> createState() =>
      _UploadReceiptReviewScreenState();
}

class _UploadReceiptReviewScreenState
    extends _AccountManagementState<UploadReceiptReviewScreen> {
  @override
  String get accountId => widget.accountId;
  late final UploadServices _services;
  @override
  UploadServices get services => _services;
  @override
  Future<void> Function()? get websiteRefresh => _load;
  UploadReceiptReview? _review;
  bool _accepted = false;
  bool _acceptedManually = false;
  @override
  void initState() {
    _services = widget.services ?? GetIt.I<UploadServices>();
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (current) _load();
    });
  }

  Future<void> _load() => run(() async {
        final review = await services.reviewReceipt(widget.receiptId);
        if (current) {
          setState(() {
            _review = review;
            needsReconcile = false;
          });
        }
      });
  Future<void> _preview() => run(() async {
        final snapshot =
            await services.repository.editor(accountId, _review!.galleryUri);
        if (!mounted || !current) return;
        await Navigator.push(
            context,
            MaterialPageRoute<void>(
                builder: (_) => RemoteUploadImagesScreen(
                    accountId: accountId,
                    initial: snapshot,
                    services: services,
                    readOnly: true)));
      });
  Future<void> _accept() async {
    final review = _review;
    if (review == null ||
        review.ambiguousNames.isNotEmpty ||
        busy ||
        _accepted) {
      return;
    }
    final partial = review.missingNames.isNotEmpty;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(partial
                  ? l('确认部分结果并停止旧任务',
                      'Confirm partial receipt and stop the old task')
                  : l('确认本批已接收', 'Confirm receipt of this batch')),
              content: Text(partial
                  ? l('将保留找到的 ${review.matchedFiles.length} 个文件记录并停止旧任务。未确认的图片留在本地，之后可重新准备，不会重传已经确认的图片。',
                      'Keeps ${review.matchedFiles.length} matched file records and stops the old task. Unconfirmed images remain local for a new preparation; confirmed images are not resent.')
                  : l('请确认这些站内条目对应本次上传。确认后会记录已接收状态，并可继续后续批次；不会公开发布画廊。',
                      'Confirm these website entries belong to this upload. Receipt will be recorded and later batches may continue; the gallery will not be published.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l('继续核对', 'Keep reviewing'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l('确认核对结果', 'Confirm reviewed result')))
              ],
            ));
    if (confirmed != true || !current) return;
    await run(() async {
      await services.acceptReceiptReview(review,
          confirmed: true, stopRemaining: partial);
      if (current) setState(() => _accepted = true);
    });
  }

  Future<void> _manual() async {
    if (_review == null || busy || _accepted || !current) return;
    final accepted = await Navigator.push<bool>(
        context,
        MaterialPageRoute<bool>(
            builder: (_) => _ManualReceiptMappingScreen(
                accountId: accountId, review: _review!, services: services)));
    if (current && accepted == true) {
      setState(() {
        _accepted = true;
        _acceptedManually = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) => guard(Scaffold(
        appBar:
            AppBar(title: Text(l('核对上传结果', 'Review upload receipt')), actions: [
          IconButton(
              tooltip: l('重新核对', 'Recheck'),
              onPressed: busy || _accepted ? null : _load,
              icon: const Icon(Icons.refresh)),
        ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          status,
          if (_accepted)
            Text(l('核对结果已记录。返回任务页查看后续状态。',
                'The reviewed result was recorded. Return to tasks for the next state.')),
          if (_review != null) ...[
            Text('GID ${_review!.galleryUri.queryParameters['ulgid']}'),
            Text(l(
                '本批预期 ${_review!.expectedNames.length} 个文件，找到 ${_review!.matchedFiles.length} 个匹配条目。',
                '${_review!.expectedNames.length} files expected in this batch; ${_review!.matchedFiles.length} matching entries found.')),
            if (!_accepted && _review!.ambiguousNames.isNotEmpty)
              Text(l('存在同名或身份不明的条目，当前不能确认接收。请先检查图片并重新核对，不能凭名称认定成功。',
                  'Some entries have ambiguous names or identity. Receipt cannot be confirmed yet. Inspect the images and recheck instead of assuming success from names.')),
            for (final name in _review!.expectedNames)
              ListTile(
                  title: Text(name),
                  subtitle: Text(_accepted
                      ? _acceptedManually
                          ? l('此项人工核对结果已记录',
                              'Manual review recorded for this item')
                          : _review!.matchedFiles.containsKey(name)
                              ? l('已记录接收结果', 'Receipt recorded')
                              : l('未确认接收，图片保留在本地',
                                  'Receipt not confirmed; image retained locally')
                      : _review!.ambiguousNames.contains(name)
                          ? l('有歧义，未确认', 'Ambiguous, not confirmed')
                          : _review!.matchedFiles.containsKey(name)
                              ? l('找到匹配条目，待你核对',
                                  'Matching entry found, awaiting your review')
                              : l('尚未找到', 'Not found'))),
            OutlinedButton(
                onPressed: busy ? null : _preview,
                child: Text(l('查看站内图片核对', 'Inspect website images'))),
            if (_review!.ambiguousNames.isNotEmpty ||
                _review!.missingNames.isNotEmpty)
              OutlinedButton(
                  key: const ValueKey('upload-receipt-manual'),
                  onPressed: busy || _accepted ? null : _manual,
                  child:
                      Text(l('逐项核对与关联', 'Review and link individual images'))),
          ],
          rule(UploadRuleId.recovery),
        ]),
        bottomNavigationBar: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: _accepted
                    ? FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(l('返回任务页', 'Back to tasks')))
                    : FilledButton(
                        key: const ValueKey('upload-receipt-confirm'),
                        onPressed: !busy &&
                                _review != null &&
                                _review!.ambiguousNames.isEmpty
                            ? _accept
                            : null,
                        child: Text(l('核对后确认', 'Confirm after review'))))),
      ));
}

class _ManualReceiptMappingScreen extends StatefulWidget {
  final String accountId;
  final UploadReceiptReview review;
  final UploadServices services;
  const _ManualReceiptMappingScreen(
      {required this.accountId, required this.review, required this.services});
  @override
  State<_ManualReceiptMappingScreen> createState() =>
      _ManualReceiptMappingScreenState();
}

class _ManualReceiptMappingScreenState
    extends _AccountManagementState<_ManualReceiptMappingScreen> {
  @override
  String get accountId => widget.accountId;
  @override
  UploadServices get services => widget.services;
  late final Map<String, RemoteUploadImage> _selected;
  final _notReceived = <String>{};
  final _thumbnails = <int, _ThumbnailRead>{};
  @override
  void initState() {
    super.initState();
    _selected = {};
    for (final entry in widget.review.matchedFiles.entries) {
      final matches = widget.review.remoteFiles
          .where((image) =>
              image.fileIndex == entry.value && image.name == entry.key)
          .toList();
      if (matches.length == 1) _selected[entry.key] = matches.single;
    }
  }

  bool get _decided => widget.review.ambiguousNames.every(
      (name) => _selected.containsKey(name) || _notReceived.contains(name));
  Future<Uint8List> _thumbnail(RemoteUploadImage image) {
    final key = image.page;
    final old = _thumbnails.remove(key);
    if (old != null) {
      _thumbnails[key] = old;
      return old.result;
    }
    final token = CancelToken();
    final future = image.thumbnail == null
        ? Future<Uint8List>.error(
            const UploadFailure(UploadFailureKind.protocolChanged))
        : services.repository.client
            .readImage(image.thumbnail!, cancelToken: token, maxBytes: 2000000);
    _thumbnails[key] = _ThumbnailRead(token, future);
    while (_thumbnails.length > 24) {
      _thumbnails.remove(_thumbnails.keys.first)!.token.cancel();
    }
    return future;
  }

  Future<void> _choose(String name) async {
    final chosen = await showModalBottomSheet<RemoteUploadImage>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
          child: SizedBox(
              height: MediaQuery.of(ctx).size.height * .8,
              child: Column(children: [
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                        '$name\n${l('选择你已核对的站内图片', 'Choose the website image you have reviewed')}')),
                Expanded(
                    child: ListView.builder(
                        itemCount: widget.review.remoteFiles.length,
                        itemBuilder: (_, index) {
                          final image = widget.review.remoteFiles[index];
                          final usedBy = _selected.entries
                              .where((entry) =>
                                  entry.key != name &&
                                  entry.value.page == image.page)
                              .firstOrNull
                              ?.key;
                          return ListTile(
                              key: ValueKey(
                                  'upload-manual-remote-${image.page}'),
                              title: Text('${image.page}. ${image.name}'),
                              subtitle: usedBy == null
                                  ? null
                                  : Text(l('已关联到 $usedBy',
                                      'Already linked to $usedBy')),
                              leading: SizedBox(
                                  width: 48,
                                  height: 64,
                                  child: FutureBuilder<Uint8List>(
                                      future: _thumbnail(image),
                                      builder: (_, snapshot) => snapshot.hasData
                                          ? Image.memory(snapshot.data!,
                                              cacheWidth: 144,
                                              cacheHeight: 192,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(Icons
                                                      .broken_image_outlined))
                                          : const Icon(Icons.image_outlined))),
                              enabled: image.fileIndex != null &&
                                  image.fileIndex! > 0 &&
                                  usedBy == null,
                              onTap: image.fileIndex == null ||
                                      image.fileIndex! <= 0 ||
                                      usedBy != null
                                  ? null
                                  : () => Navigator.pop(ctx, image));
                        })),
              ]))),
    );
    if (chosen != null && current) {
      setState(() {
        _selected[name] = chosen;
        _notReceived.remove(name);
      });
    }
  }

  Future<void> _local(String name) async {
    try {
      final store = await services.store;
      final draft = await store.draft(accountId, widget.review.draftId);
      if (!mounted || !current) return;
      final matches =
          draft?.assets.where((asset) => asset.uploadName == name).toList() ??
              [];
      if (matches.length != 1) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'The local source is no longer uniquely available. Review the original file before deciding.');
      }
      final asset = matches.single;
      final file = await resolveUploadFile(store.root, asset.relativePath);
      if (!mounted || !current) return;
      await showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(asset.displayName)),
                Flexible(
                    child: InteractiveViewer(
                        child: Image.file(file,
                            cacheWidth: 1600,
                            errorBuilder: (_, __, ___) => Text(l('无法预览本地副本。',
                                'Cannot preview the local copy.'))))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(l('关闭', 'Close'))),
              ])));
    } catch (failure) {
      if (current) setState(() => error = failure);
    }
  }

  Future<void> _confirm() async {
    if (!_decided || busy || (_selected.isEmpty && _notReceived.isEmpty)) {
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(l('确认人工核对结果', 'Confirm your manual review')),
              content: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(l(
                        '将关联 ${_selected.length} 项，并将 ${_notReceived.length} 项明确标为未收到；旧任务会停止。这记录的是你核对的站内已有图片，不会把原请求自动标为上传成功。未关联的内容继续保留在本地。',
                        '${_selected.length} items will be linked and ${_notReceived.length} explicitly marked not received. The old task will stop. This records your review of existing website images, not automatic success of the original request. Unlinked content stays local.')),
                    Text(l('每份本地图片必须关联不同的站内条目；相同内容编号不能证明保留了多份。',
                        'Each local image must link to a different website entry. A shared content ID does not prove multiple copies were retained.')),
                    for (final entry in _selected.entries)
                      Text(
                          '${entry.key} → ${entry.value.page}. ${entry.value.name}'),
                    for (final name in _notReceived)
                      Text('$name → ${l('明确未收到', 'explicitly not received')}'),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l('继续核对', 'Keep reviewing'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(
                        l('确认人工结果并停止旧任务', 'Confirm review and stop old task')))
              ],
            ));
    if (confirmed != true || !current) return;
    await run(() async {
      await services.acceptManualReceiptMapping(widget.review,
          selectedEntries: Map.of(_selected),
          notReceivedNames: Set.of(_notReceived),
          confirmed: true);
      if (mounted && current) Navigator.pop(context, true);
    });
  }

  @override
  Widget build(BuildContext context) => guard(Scaffold(
        appBar: AppBar(title: Text(l('逐项人工核对', 'Review images individually'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          status,
          Text(l('唯一匹配项已列出，可修改；歧义项必须明确选择站内图片或标为未收到。不会仅凭同名自动确认。',
              'Unique matches are listed and can be changed. Every ambiguous item needs an explicit image choice or a not-received decision. Matching names alone do not confirm receipt.')),
          for (final name in widget.review.expectedNames)
            Card(
                key: ValueKey('upload-manual-item-$name'),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                          title: Text(name),
                          subtitle: Text(_notReceived.contains(name)
                              ? l('明确未收到', 'Explicitly not received')
                              : _selected.containsKey(name)
                                  ? '${l('选择的站内图片', 'Selected website image')}: ${_selected[name]!.page}. ${_selected[name]!.name}'
                                  : l('未决定', 'Undecided'))),
                      Wrap(spacing: 4, children: [
                        TextButton(
                            onPressed: busy ? null : () => _local(name),
                            child: Text(l('查看本地副本', 'View local copy'))),
                        TextButton(
                            key: ValueKey('upload-manual-choose-$name'),
                            onPressed: busy ? null : () => _choose(name),
                            child: Text(l('选择站内图片', 'Choose website image'))),
                        TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                      _selected.remove(name);
                                      _notReceived.add(name);
                                    }),
                            child: Text(l('明确未收到', 'Mark not received'))),
                        TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                      _selected.remove(name);
                                      _notReceived.remove(name);
                                    }),
                            child: Text(l('暂不决定', 'Leave undecided'))),
                      ]),
                    ])),
        ]),
        bottomNavigationBar: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                    key: const ValueKey('upload-receipt-manual-confirm'),
                    onPressed: !busy &&
                            _decided &&
                            (_selected.isNotEmpty || _notReceived.isNotEmpty)
                        ? _confirm
                        : null,
                    child: Text(l('复核并确认', 'Review and confirm'))))),
      ));
  @override
  void onInvalidated() {
    for (final read in _thumbnails.values) {
      read.token.cancel();
    }
    _thumbnails.clear();
  }

  @override
  void dispose() {
    onInvalidated();
    super.dispose();
  }
}

class RemoteUploadImagesScreen extends StatefulWidget {
  final String accountId;
  final UploadEditorSnapshot initial;
  final UploadServices? services;
  final bool readOnly;
  const RemoteUploadImagesScreen(
      {super.key,
      required this.accountId,
      required this.initial,
      this.services,
      this.readOnly = false});
  @override
  State<RemoteUploadImagesScreen> createState() =>
      _RemoteUploadImagesScreenState();
}

class _ThumbnailRead {
  final CancelToken token;
  final Future<Uint8List> result;
  _ThumbnailRead(this.token, this.result);
}

class _RemoteUploadImagesScreenState
    extends _AccountManagementState<RemoteUploadImagesScreen> {
  @override
  String get accountId => widget.accountId;
  late final UploadServices _services;
  @override
  UploadServices get services => _services;
  @override
  Future<void> Function()? get websiteRefresh => _refresh;
  late UploadEditorSnapshot _snapshot;
  late List<RemoteUploadImage> _order;
  final _thumbnails = <int, _ThumbnailRead>{};
  CancelToken? _previewToken;
  bool _changed = false;
  @override
  bool get hasUnsavedChanges => _changed;
  bool get _editable =>
      !busy &&
      !widget.readOnly &&
      !needsReconcile &&
      _snapshot.buttons['reorder_manual']?.enabled == true;
  @override
  void initState() {
    _services = widget.services ?? GetIt.I<UploadServices>();
    _snapshot = widget.initial;
    _order = List.of(_snapshot.images);
    super.initState();
  }

  void _clearImages() {
    for (final read in _thumbnails.values) {
      read.token.cancel();
    }
    _thumbnails.clear();
    _previewToken?.cancel();
  }

  @override
  void onInvalidated() {
    _clearImages();
  }

  void _apply(UploadEditorSnapshot next) {
    needsReconcile = false;
    _clearImages();
    _snapshot = next;
    _order = List.of(next.images);
    _changed = false;
  }

  Future<void> _refresh() => run(() async {
        final fresh =
            await services.repository.editor(accountId, _snapshot.uri);
        if (current) setState(() => _apply(fresh));
      });
  Future<Uint8List> _thumbnail(RemoteUploadImage image) {
    final existing = _thumbnails.remove(image.page);
    if (existing != null) {
      _thumbnails[image.page] = existing;
      return existing.result;
    }
    final token = CancelToken();
    final future = image.thumbnail == null
        ? Future<Uint8List>.error(
            const UploadFailure(UploadFailureKind.protocolChanged))
        : services.repository.client
            .readImage(image.thumbnail!, cancelToken: token, maxBytes: 2000000);
    _thumbnails[image.page] = _ThumbnailRead(token, future);
    while (_thumbnails.length > 24) {
      _thumbnails.remove(_thumbnails.keys.first)!.token.cancel();
    }
    return future;
  }

  Future<void> _preview(RemoteUploadImage image) async {
    if (!current || busy) return;
    final token = CancelToken();
    _previewToken?.cancel();
    _previewToken = token;
    final result = () async {
      final fresh = await services.repository.editor(accountId, _snapshot.uri);
      if (!current || token.isCancelled) {
        throw const UploadFailure(UploadFailureKind.sessionChanged);
      }
      final match = fresh.images
          .where((candidate) =>
              candidate.fileIndex == image.fileIndex &&
              candidate.name == image.name)
          .firstOrNull;
      if (match == null) {
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'The image list changed. Refresh before previewing.');
      }
      final uri = await services.repository.imageUri(accountId, fresh, match);
      if (!current || token.isCancelled) {
        throw const UploadFailure(UploadFailureKind.sessionChanged);
      }
      return services.repository.client.readImage(uri, cancelToken: token);
    }();
    result.ignore(); // The dialog may not build before an immediate read error.
    await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                  padding: const EdgeInsets.all(12), child: Text(image.name)),
              Flexible(
                  child: FutureBuilder<Uint8List>(
                      future: result,
                      builder: (_, snapshot) {
                        if (snapshot.hasError) {
                          return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                  uploadFailureMessage(snapshot.error!, zh)));
                        }
                        if (!snapshot.hasData) {
                          return const Padding(
                              padding: EdgeInsets.all(24),
                              child: CircularProgressIndicator());
                        }
                        return InteractiveViewer(
                            child: Image.memory(snapshot.data!,
                                cacheWidth: 1600,
                                errorBuilder: (_, __, ___) => Text(l(
                                    '无法解码此图片。', 'Cannot decode this image.'))));
                      })),
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l('关闭', 'Close'))),
            ])));
    token.cancel();
  }

  Future<void> _save() async {
    final removed = _snapshot.images.length - _order.length;
    if (removed > 0) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text(l('确认移除站内图片', 'Confirm removal of remote images')),
                content: Text(l('将从当前站内草稿或更新版本移除 $removed 张图片，不删除本地原始文件。',
                    'Removes $removed images from the current website draft or update version, without deleting original local files.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(l('取消', 'Cancel'))),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l('保存这些变更', 'Save these changes')))
                ],
              ));
      if (confirmed != true || !current) return;
    }
    await run(() async {
      final positions = {
        for (final image in _snapshot.images) image.positionField: 0
      };
      for (var i = 0; i < _order.length; i++) {
        positions[_order[i].positionField] = i + 1;
      }
      final saved = await services.repository
          .reorderImages(accountId, _snapshot, positions);
      if (current) setState(() => _apply(saved));
    });
  }

  Future<void> _dedupe() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(
                  l('由站点移除完全重复图片', 'Remove exact duplicates on the website')),
              content: Text(l('站点将立即处理并保存去重结果。不会按相似缩略图或相同文件名去重。',
                  'The website will process and save deduplication immediately. This does not remove files merely for similar thumbnails or matching names.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l('取消', 'Cancel'))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l('确认去重', 'Remove duplicates')))
              ],
            ));
    if (confirmed != true || !current) return;
    await run(() async {
      final saved = await services.repository
          .autoSortImages(accountId, _snapshot, 'dedupe');
      if (current) setState(() => _apply(saved));
    });
  }

  @override
  Widget build(BuildContext context) => guard(Scaffold(
        appBar: AppBar(title: Text(l('站内图片管理', 'Website images')), actions: [
          IconButton(
              tooltip: l('重新读取', 'Reload'),
              onPressed:
                  busy || (_changed && !needsReconcile) ? null : _refresh,
              icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
              enabled: _editable,
              onSelected: (value) {
                if (value == 'dedupe') {
                  _dedupe();
                  return;
                }
                setState(() {
                  _order.sort((a, b) => value == 'natural'
                      ? compareNaturalUploadNames(a.name, b.name)
                      : a.name.compareTo(b.name));
                  _changed = true;
                });
              },
              itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'natural',
                        child: Text(l('自然排序（待保存）', 'Natural sort (unsaved)'))),
                    PopupMenuItem(
                        value: 'lexical',
                        child: Text(l('字典排序（待保存）', 'Lexical sort (unsaved)'))),
                    PopupMenuItem(
                        value: 'dedupe',
                        enabled: !_changed &&
                            _snapshot.buttons['reorder_auto']?.enabled == true,
                        child:
                            Text(l('站点精确去重', 'Website exact deduplication'))),
                  ]),
        ]),
        body: Column(children: [
          status,
          Expanded(
              child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _order.length,
            header: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(l(
                          '当前 ${_order.length} 张，${_snapshot.images.length - _order.length} 张待移除。',
                          '${_order.length} images retained; ${_snapshot.images.length - _order.length} pending removal.')),
                      rule(UploadRuleId.ordering),
                      rule(UploadRuleId.cloneUpdate),
                      if (!_editable && !busy)
                        Text(widget.readOnly
                            ? l('此页仅供核对，不会修改站内图片。',
                                'This page is for review only; it cannot change website images.')
                            : l('站点当前不允许修改图片；已发布画廊通常需先创建更新版本。',
                                'The website does not currently allow image changes. Published galleries generally need an update version first.')),
                    ])),
            onReorder: (from, to) {
              if (!_editable) return;
              if (to > from) to--;
              setState(() {
                final image = _order.removeAt(from);
                _order.insert(to, image);
                _changed = true;
              });
            },
            itemBuilder: (_, index) {
              final image = _order[index];
              return Card(
                  key: ValueKey(image.positionField),
                  child: ListTile(
                    onTap: () => _preview(image),
                    title: Text('${index + 1}. ${image.name}'),
                    leading: SizedBox(
                        width: 48,
                        height: 64,
                        child: FutureBuilder<Uint8List>(
                            future: _thumbnail(image),
                            builder: (_, snapshot) => snapshot.hasData
                                ? Image.memory(snapshot.data!,
                                    cacheWidth: 144,
                                    cacheHeight: 192,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.broken_image_outlined))
                                : const Icon(Icons.image_outlined))),
                    trailing: _editable
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                                tooltip:
                                    l('标记移除，保存后生效', 'Mark for removal on save'),
                                onPressed: () => setState(() {
                                      _order.removeAt(index);
                                      _changed = true;
                                    }),
                                icon: const Icon(Icons.remove_circle_outline)),
                            ReorderableDragStartListener(
                                index: index,
                                child: const Icon(Icons.drag_handle)),
                          ])
                        : null,
                  ));
            },
          ))
        ]),
        bottomNavigationBar: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  if (_changed)
                    TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                  _order = List.of(_snapshot.images);
                                  _changed = false;
                                }),
                        child: Text(l('还原', 'Revert'))),
                  Expanded(
                      child: FilledButton(
                          key: const ValueKey('upload-remote-images-save'),
                          onPressed: _editable && _changed ? _save : null,
                          child: Text(
                              l('保存站内图片变更', 'Save website image changes')))),
                ]))),
      ));
  @override
  void dispose() {
    _clearImages();
    super.dispose();
  }
}
