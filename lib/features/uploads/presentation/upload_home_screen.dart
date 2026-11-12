import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../blocs/auth/auth_bloc.dart';
import '../../../blocs/auth/auth_state.dart';
import '../../../core/router/app_page_route.dart';
import '../data/upload_protocol.dart';
import '../data/upload_advanced_actions.dart';
import '../data/upload_store.dart';
import '../rules/rule_notice.dart';
import '../rules/upload_rules.dart';
import '../upload_services.dart';
import 'upload_editor_screen.dart';
import 'upload_management_screens.dart';
import 'upload_web_page.dart';
import 'upload_advanced_screens.dart';

class UploadHomeScreen extends StatefulWidget {
  final UploadServices? services;
  final int initialTab;
  const UploadHomeScreen({super.key, this.services, this.initialTab = 0})
      : assert(initialTab >= 0 && initialTab < 3);
  @override
  State<UploadHomeScreen> createState() => _UploadHomeScreenState();
}

class _UploadHomeScreenState extends State<UploadHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final UploadServices _services;
  late final AuthBloc _auth;
  late final TabController _tabs;
  StreamSubscription<AuthState>? _authChanges;
  StreamSubscription<void>? _draftChanges;
  Timer? _taskTimer;
  UploadStore? _store;
  UploadManagerSnapshot? _manager;
  List<ManagedUploadGallery> _galleries = [];
  List<UploadDraft> _drafts = [];
  List<Map<String, dynamic>>? _tasks;
  List<Map<String, dynamic>> _receipts = [];
  final _expandedFolders = <String>{};
  final _selected = <String, ManagedUploadGallery>{};
  String? _account;
  int _generation = -1;
  int _revision = 0;
  bool _managerLoading = false;
  bool _draftLoading = false;
  bool _taskLoading = false;
  bool _opening = false;
  bool _foreground = true;
  Object? _managerError;
  Object? _draftError;
  Object? _taskError;
  DateTime? _managerUpdatedAt;
  String _statusFilter = 'all';
  String _folderFilter = 'all';
  String _sort = 'dateDesc';

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _l(String cn, String en) => _zh ? cn : en;
  bool _current(int revision) =>
      mounted &&
      _revision == revision &&
      _auth.state.isLoggedIn &&
      _auth.state.profile.memberId == _account &&
      _auth.state.sessionGeneration == _generation;

  @override
  void initState() {
    super.initState();
    _services = widget.services ?? GetIt.I<UploadServices>();
    _auth = context.read<AuthBloc>();
    _tabs =
        TabController(length: 3, vsync: this, initialIndex: widget.initialTab)
          ..addListener(_tabChanged);
    WidgetsBinding.instance.addObserver(this);
    _authChanges = _auth.stream.listen(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _accountChanged(_auth.state);
    });
  }

  void _accountChanged(AuthState state) {
    if (!mounted) return;
    final account = state.isLoggedIn ? state.profile.memberId : null;
    if (account == _account && state.sessionGeneration == _generation) return;
    _draftChanges?.cancel();
    _draftChanges = null;
    _taskTimer?.cancel();
    setState(() {
      _revision++;
      _account = account;
      _generation = state.sessionGeneration;
      _manager = null;
      _galleries = [];
      _drafts = [];
      _tasks = null;
      _receipts = [];
      _store = null;
      _expandedFolders.clear();
      _selected.clear();
      _managerUpdatedAt = null;
      _statusFilter = _folderFilter = 'all';
      _sort = 'dateDesc';
      _managerError = _draftError = _taskError = null;
      _managerLoading = _draftLoading = _taskLoading = _opening = false;
    });
    if (account == null) return;
    _refreshManager();
    _openStore();
    _tabChanged();
  }

  Future<void> _refreshManager() async {
    if (_account == null || _managerLoading) return;
    final revision = _revision;
    setState(() {
      _managerLoading = true;
      _managerError = null;
    });
    try {
      final manager = await _services.repository.manager(_account!);
      if (!_current(revision)) return;
      setState(() {
        _manager = manager;
        _galleries = List.of(manager.galleries);
        _expandedFolders.clear();
        _selected.clear();
        final folders = {
          ...?manager.form.fields['folderid']?.options
              .map((option) => option.value),
          ...manager.folders.map((folder) => '${folder.folderId}'),
        };
        if (_folderFilter != 'all' && !folders.contains(_folderFilter)) {
          _folderFilter = 'all';
        }
        _managerUpdatedAt = DateTime.now();
      });
    } catch (error) {
      if (_current(revision)) setState(() => _managerError = error);
    } finally {
      if (_current(revision)) setState(() => _managerLoading = false);
    }
  }

  Future<void> _openStore() async {
    if (_account == null) return;
    final revision = _revision;
    setState(() {
      _draftLoading = true;
      _draftError = null;
    });
    try {
      final store = await _services.store;
      if (!_current(revision)) return;
      _store = store;
      _draftChanges?.cancel();
      _draftChanges = store.changes.listen((_) {
        if (_current(revision)) _refreshDrafts();
      });
      await _refreshDrafts();
    } catch (error) {
      if (_current(revision)) setState(() => _draftError = error);
    } finally {
      if (_current(revision)) setState(() => _draftLoading = false);
    }
  }

  Future<void> _refreshDrafts() async {
    if (_account == null || _store == null) return;
    final revision = _revision;
    try {
      final drafts = await _store!.drafts(_account!);
      if (_current(revision)) {
        setState(() {
          _drafts =
              drafts.where((draft) => draft.accountId == _account).toList();
          _draftError = null;
        });
      }
    } catch (error) {
      if (_current(revision)) setState(() => _draftError = error);
    }
  }

  void _tabChanged() {
    _taskTimer?.cancel();
    if (_tabs.index != 1 || _account == null || !_foreground) return;
    _refreshTasks();
    _taskTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) _refreshTasks();
    });
  }

  Future<void> _refreshTasks() async {
    if (_account == null || _taskLoading) return;
    final revision = _revision;
    setState(() {
      _taskLoading = true;
    });
    try {
      final snapshot = await _services.transferSnapshot();
      if (!_current(revision)) return;
      final raw = snapshot['tasks'];
      if (raw is! List || raw.any((task) => task is! Map)) {
        throw const FormatException('Invalid upload task snapshot');
      }
      final tasks = raw
          .cast<Map>()
          .map((task) => Map<String, dynamic>.from(task))
          .where((task) => task['accountId'] == _account)
          .toList();
      if (tasks.any(
          (task) => task['taskId'] is! String || task['state'] is! String)) {
        throw const FormatException('Invalid upload task identity');
      }
      setState(() {
        _tasks = tasks;
        _receipts = ((snapshot['receipts'] as List?) ?? const [])
            .whereType<Map>()
            .map((receipt) => Map<String, dynamic>.from(receipt))
            .where((receipt) => receipt['accountId'] == _account)
            .toList();
        _taskError = null;
      });
    } catch (error) {
      if (_current(revision)) setState(() => _taskError = error);
    } finally {
      if (_current(revision)) setState(() => _taskLoading = false);
    }
  }

  Future<void> _open(Future<UploadEditingSession> Function(String) load) async {
    if (_account == null || _opening) return;
    final revision = _revision;
    setState(() => _opening = true);
    try {
      final session = await load(_account!);
      if (!_current(revision)) return;
      if (session.draft.accountId != _account) {
        throw const UploadFailure(UploadFailureKind.sessionChanged);
      }
      if (!mounted) return;
      await Navigator.push(
          context,
          AppPageRoute(
              builder: (_) => UploadEditorScreen(
                    session: session,
                    services: _services,
                  )));
      if (!_current(revision)) return;
      await _refreshDrafts();
      await _refreshManager();
      if (_tabs.index == 1) await _refreshTasks();
    } catch (error) {
      if (_current(revision)) _showError(error);
    } finally {
      if (_current(revision)) setState(() => _opening = false);
    }
  }

  void _showError(Object error) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(uploadFailureMessage(error, _zh))));

  Future<void> _source(Uri uri) async {
    try {
      if (uri.host == uploadOrigin.host) {
        if (_opening) return;
        if (_account == null) {
          throw const UploadFailure(UploadFailureKind.loginRequired);
        }
        final revision = _revision;
        int? handoff;
        setState(() => _opening = true);
        try {
          await Navigator.push<void>(
              context,
              AppPageRoute<void>(
                  builder: (_) => UploadWebPage(
                        url: uri,
                        cookies: _services.cookies,
                        auth: _auth,
                        beforeOpen: () async {
                          if (!_current(revision)) {
                            throw const UploadFailure(
                                UploadFailureKind.sessionChanged);
                          }
                          handoff = await _services.prepareWebHandoff();
                        },
                        afterClose: () async {
                          try {
                            if (_current(revision)) {
                              await _refreshManager();
                              await _refreshDrafts();
                              await _refreshTasks();
                            }
                          } finally {
                            if (handoff != null) {
                              await _services.endWebHandoff(
                                  generation: handoff);
                            }
                          }
                        },
                      )));
        } finally {
          if (_current(revision)) setState(() => _opening = false);
        }
        return;
      }
      await _services.openExternal(uri);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _folder(UploadFolderSection folder) async {
    if (_manager == null || _account == null || _managerLoading) return;
    final key = '${folder.state}:${folder.folderId}';
    if (_expandedFolders.contains(key)) return;
    final revision = _revision;
    setState(() => _managerLoading = true);
    try {
      final galleries =
          await _services.repository.folder(_account!, _manager!, folder);
      if (!_current(revision)) return;
      final keys = _galleries.map(_galleryKey).toSet();
      setState(() {
        _galleries.addAll(
            galleries.where((gallery) => keys.add(_galleryKey(gallery))));
        _expandedFolders.add(key);
      });
    } catch (error) {
      if (_current(revision)) setState(() => _managerError = error);
    } finally {
      if (_current(revision)) setState(() => _managerLoading = false);
    }
  }

  String _galleryKey(ManagedUploadGallery gallery) =>
      gallery.actions.values.map((uri) => uri.toString()).join('|');
  List<ManagedUploadGallery> get _visibleGalleries {
    final result = _galleries.where((gallery) {
      if (_folderFilter != 'all' && '${gallery.folderId}' != _folderFilter) {
        return false;
      }
      return switch (_statusFilter) {
        'drafts' => gallery.publication == ManagedUploadPublication.unpublished,
        'published' =>
          gallery.publication == ManagedUploadPublication.published &&
              !gallery.isPrivate,
        'private' => gallery.isPrivate,
        'other' => gallery.publication == ManagedUploadPublication.unknown &&
            !gallery.isPrivate,
        _ => true,
      };
    }).toList();
    result.sort((a, b) {
      if (_sort.startsWith('title')) {
        final compared = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return _sort == 'titleAsc' ? compared : -compared;
      }
      final aDate = DateTime.tryParse(a.date);
      final bDate = DateTime.tryParse(b.date);
      if (aDate == null && bDate != null) return 1;
      if (bDate == null && aDate != null) return -1;
      final compared = aDate == null || bDate == null
          ? a.date.compareTo(b.date)
          : aDate.compareTo(bDate);
      return _sort == 'dateAsc' ? compared : -compared;
    });
    return result;
  }

  String _galleryStatus(ManagedUploadGallery gallery) {
    if (gallery.publication == ManagedUploadPublication.unpublished) {
      return gallery.isPrivate
          ? _l('未发布 · 私人／不公开列出', 'Unpublished · Private / Unlisted')
          : _l('未发布', 'Unpublished');
    }
    if (gallery.publication == ManagedUploadPublication.published) {
      return gallery.isPrivate
          ? _l('私人／不公开列出', 'Private / Unlisted')
          : _l('已发布（公开分类）', 'Published (public category)');
    }
    final label = gallery.sectionLabel?.isNotEmpty == true
        ? gallery.sectionLabel!
        : _l('状态未确认', 'Status unconfirmed');
    return gallery.isPrivate
        ? '${_l('私人／不公开列出', 'Private / Unlisted')} · $label'
        : label;
  }

  String _localTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _filters() {
    final folders = <String, String>{
      'all': _l('全部目录', 'All folders'),
      for (final option
          in _manager?.form.fields['folderid']?.options ?? <UploadOption>[])
        option.value: option.label,
      for (final folder in _manager?.folders ?? <UploadFolderSection>[])
        '${folder.folderId}': folder.label,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<String>(
          key: const ValueKey('upload-filter-status'),
          value: _statusFilter,
          isExpanded: true,
          decoration:
              InputDecoration(labelText: _l('状态（已加载）', 'Status (loaded)')),
          items: [
            for (final entry in <String, String>{
              'all': _l('全部状态', 'All statuses'),
              'drafts': _l('未发布', 'Unpublished'),
              'published': _l('已发布（公开分类）', 'Published (public category)'),
              'private': _l('私人／不公开列出', 'Private / Unlisted'),
              'other': _l('其他／未知', 'Other / unknown')
            }.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value))
          ],
          onChanged: (value) {
            if (value != null) setState(() => _statusFilter = value);
          }),
      DropdownButtonFormField<String>(
          key: const ValueKey('upload-filter-folder'),
          value: folders.containsKey(_folderFilter) ? _folderFilter : 'all',
          isExpanded: true,
          decoration:
              InputDecoration(labelText: _l('目录（已加载）', 'Folder (loaded)')),
          items: [
            for (final entry in folders.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value))
          ],
          onChanged: (value) {
            if (value != null) setState(() => _folderFilter = value);
          }),
      DropdownButtonFormField<String>(
          key: const ValueKey('upload-sort'),
          value: _sort,
          isExpanded: true,
          decoration: InputDecoration(labelText: _l('排序', 'Sort')),
          items: [
            for (final entry in <String, String>{
              'dateDesc': _l('添加时间：新到旧', 'Added: newest first'),
              'dateAsc': _l('添加时间：旧到新', 'Added: oldest first'),
              'titleAsc': _l('标题：升序', 'Title: ascending'),
              'titleDesc': _l('标题：降序', 'Title: descending')
            }.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value))
          ],
          onChanged: (value) {
            if (value != null) setState(() => _sort = value);
          }),
    ]);
  }

  Uri? _manageUri(ManagedUploadGallery gallery) {
    return gallery.managementUri;
  }

  Future<void> _manageFolders() async {
    if (_account == null || _opening) return;
    final revision = _revision;
    setState(() => _opening = true);
    try {
      await Navigator.push(
          context,
          AppPageRoute(
              builder: (_) => UploadFoldersScreen(
                  accountId: _account!, services: _services)));
      if (_current(revision)) await _refreshManager();
    } finally {
      if (_current(revision)) setState(() => _opening = false);
    }
  }

  Future<void> _bulk(bool category) async {
    if (_account == null || _manager == null || _selected.isEmpty || _opening) {
      return;
    }
    final revision = _revision;
    final targets = List<ManagedUploadGallery>.unmodifiable(_selected.values);
    setState(() => _opening = true);
    try {
      await Navigator.push(
          context,
          AppPageRoute(
              builder: (_) => UploadBulkScreen(
                  accountId: _account!,
                  manager: _manager!,
                  targets: targets,
                  category: category,
                  services: _services)));
      if (_current(revision)) await _refreshManager();
    } finally {
      if (_current(revision)) setState(() => _opening = false);
    }
  }

  Future<void> _bulkAdvanced(UploadGalleryAction action) async {
    if (_account == null || _selected.isEmpty || _opening) return;
    final revision = _revision;
    final targets = List<ManagedUploadGallery>.unmodifiable(_selected.values);
    setState(() => _opening = true);
    try {
      await Navigator.push(
          context,
          AppPageRoute(
              builder: (_) => UploadBulkAdvancedScreen(
                  services: _services,
                  accountId: _account!,
                  action: action,
                  targets: targets)));
      if (_current(revision)) await _refreshManager();
    } finally {
      if (_current(revision)) setState(() => _opening = false);
    }
  }

  void _selectGallery(ManagedUploadGallery gallery, bool selected) {
    if (!gallery.canSelect || _opening) return;
    setState(() {
      if (selected) {
        _selected[gallery.selectionKey] = gallery;
      } else {
        _selected.remove(gallery.selectionKey);
      }
    });
  }

  Future<void> _removeDraft(UploadDraft draft) async {
    final revision = _revision;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(_l('删除本地草稿', 'Delete local draft')),
              content: Text(_l('仅删除此草稿与不再使用的上传复制件，不删除站内画廊或原始文件。',
                  'Deletes this local draft and unused imported copies only, not the website gallery or original files.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(_l('取消', 'Cancel'))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(_l('删除本地草稿', 'Delete local draft'))),
              ],
            ));
    if (confirmed != true || !_current(revision)) return;
    try {
      await _services.removeLocal(draft);
      if (_current(revision)) await _refreshDrafts();
    } catch (error) {
      if (_current(revision)) _showError(error);
    }
  }

  Future<void> _taskAction(String action, String id) async {
    final revision = _revision;
    if (!_current(revision)) return;
    try {
      if (action == 'pause') await _services.pauseTask(id);
      if (action == 'resume') await _services.resumeTask(id);
      if (action == 'cancel') {
        if (!mounted || !_current(revision)) return;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: Text(_l('停止此上传任务', 'Stop this upload task')),
                  content: Text(_l('停止后不会撤销站点已接收的文件，也不会删除站内草稿。已发送但未确认的内容仍需核对。',
                      'Stopping does not remove files already received or delete the website draft. Sent but unconfirmed content still needs reconciliation.')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(_l('继续任务', 'Keep task'))),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(_l('停止', 'Stop'))),
                  ],
                ));
        if (confirmed != true || !_current(revision)) return;
        await _services.cancelTask(id);
      }
      if (_current(revision)) await _refreshTasks();
    } catch (error) {
      if (_current(revision)) _showError(error);
    }
  }

  Future<void> _reviewReceipt(String receiptId) async {
    if (_account == null || _opening) return;
    final revision = _revision;
    setState(() => _opening = true);
    try {
      await Navigator.push(
          context,
          AppPageRoute(
              builder: (_) => UploadReceiptReviewScreen(
                  accountId: _account!,
                  receiptId: receiptId,
                  services: _services)));
      if (_current(revision)) {
        await _refreshTasks();
        await _refreshDrafts();
      }
    } finally {
      if (_current(revision)) setState(() => _opening = false);
    }
  }

  void _rules() => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: .8,
            maxChildSize: .95,
            builder: (_, controller) => ListView.builder(
              controller: controller,
              padding: const EdgeInsets.all(16),
              itemCount: UploadRules.all.length,
              itemBuilder: (_, index) => RuleNotice(
                rule: UploadRules.all[index],
                onOpenSource: _source,
              ),
            ),
          ));

  Widget _error(Object error, Future<void> Function() retry) =>
      Column(children: [
        Text(uploadFailureMessage(error, _zh)),
        TextButton(onPressed: retry, child: Text(_l('重试', 'Retry'))),
      ]);

  Widget _galleryList() {
    final visible = _visibleGalleries;
    final visibleKeys = visible.map((gallery) => gallery.selectionKey).toSet();
    final hiddenSelected =
        _selected.keys.where((key) => !visibleKeys.contains(key)).length;
    return RefreshIndicator(
        onRefresh: _refreshManager,
        child: ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              RuleNotices(
                  location: UploadRuleLocation.account, onOpenSource: _source),
              if (_managerLoading) const LinearProgressIndicator(),
              if (_managerError != null)
                _error(_managerError!, _refreshManager),
              if (_manager != null) _filters(),
              if (_galleries.any((gallery) => gallery.canSelect)) ...[
                Text(_l('已选择 ${_selected.length} 个画廊',
                    '${_selected.length} galleries selected')),
                if (hiddenSelected > 0)
                  Text(_l('其中 $hiddenSelected 个不在当前筛选结果中。',
                      '$hiddenSelected selected galleries are outside the current filter.')),
                Wrap(spacing: 8, children: [
                  TextButton(
                      onPressed: _opening
                          ? null
                          : () => setState(() {
                                for (final gallery in visible
                                    .where((gallery) => gallery.canSelect)) {
                                  _selected[gallery.selectionKey] = gallery;
                                }
                              }),
                      child: Text(_l('全选已加载', 'Select loaded'))),
                  TextButton(
                      onPressed: _selected.isEmpty || _opening
                          ? null
                          : () => setState(_selected.clear),
                      child: Text(_l('清除选择', 'Clear selection'))),
                  OutlinedButton(
                      onPressed: _selected.isEmpty || _opening
                          ? null
                          : () => _bulk(false),
                      child: Text(_l('移动目录', 'Move to folder'))),
                  OutlinedButton(
                      onPressed: _selected.isEmpty || _opening
                          ? null
                          : () => _bulk(true),
                      child: Text(_l('修改分类', 'Change category'))),
                  for (final action in [
                    UploadGalleryAction.publish,
                    UploadGalleryAction.delete,
                    UploadGalleryAction.disown
                  ])
                    OutlinedButton(
                        onPressed: _selected.isEmpty || _opening
                            ? null
                            : () => _bulkAdvanced(action),
                        child: Text(uploadActionLabel(action, _zh))),
                ]),
              ],
              if (_managerUpdatedAt != null)
                Text(
                    _l('本地读取时间：${_localTime(_managerUpdatedAt!)}',
                        'Local read time: ${_localTime(_managerUpdatedAt!)}'),
                    style: Theme.of(context).textTheme.bodySmall),
              for (final folder in _manager?.folders ?? <UploadFolderSection>[])
                if ((_folderFilter == 'all' ||
                        '${folder.folderId}' == _folderFilter) &&
                    folder.collapsed &&
                    !_expandedFolders
                        .contains('${folder.state}:${folder.folderId}'))
                  ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(folder.label),
                      trailing: const Icon(Icons.expand_more),
                      onTap: _managerLoading ? null : () => _folder(folder)),
              if (_manager != null &&
                  visible.isEmpty &&
                  !_managerLoading &&
                  _managerError == null)
                Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_l('当前已加载范围没有画廊；有折叠目录时可展开查看。',
                        'There are no galleries in the loaded results. Expand any collapsed folders to view their contents.'))),
              for (final gallery in visible)
                Card(
                    child: ListTile(
                  leading: gallery.canSelect
                      ? Checkbox(
                          value: _selected.containsKey(gallery.selectionKey),
                          onChanged: _opening
                              ? null
                              : (value) =>
                                  _selectGallery(gallery, value == true))
                      : null,
                  title: Text(gallery.title),
                  subtitle: Text(
                      '${_galleryStatus(gallery)} · ${gallery.category} · ${gallery.fileCount} ${_l('张', 'images')}\n${_l('站点时间', 'Website time')}: ${gallery.date}'),
                  isThreeLine: true,
                  onTap: _opening || _manageUri(gallery) == null
                      ? null
                      : () => _open((account) =>
                          _services.openRemote(account, _manageUri(gallery)!)),
                  trailing: IconButton(
                      tooltip: _l('在官方页面管理', 'Manage on official page'),
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () => _source(_manageUri(gallery) ??
                          uploadOrigin.resolve('manage'))),
                )),
              RuleNotice(
                  rule: UploadRules.byId(UploadRuleId.webHandoff),
                  onOpenSource: _source),
              Text(_l('统计及其他暂不可用的操作可在官方管理页查看。',
                  'Statistics and other currently unavailable actions remain accessible in the official manager.')),
              TextButton(
                  onPressed: () => _source(uploadOrigin.resolve('manage')),
                  child: Text(_l('打开官方管理页', 'Open official manager'))),
            ]));
  }

  Widget _draftList() => RefreshIndicator(
      onRefresh: _store == null ? _openStore : _refreshDrafts,
      child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            RuleNotices(
                location: UploadRuleLocation.drafts, onOpenSource: _source),
            if (_draftLoading) const LinearProgressIndicator(),
            if (_draftError != null) _error(_draftError!, _openStore),
            if (_drafts.isEmpty && !_draftLoading && _draftError == null)
              Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_l('尚无本地草稿。', 'No local drafts yet.'))),
            for (final draft in _drafts)
              Card(
                  child: ListTile(
                title: Text(draft.title.isEmpty
                    ? _l('未命名画廊', 'Untitled gallery')
                    : draft.title),
                subtitle: Text(
                    '${draft.assets.length} ${_l('个本地文件', 'local files')} · ${_draftStatus(draft)}'),
                onTap: _opening
                    ? null
                    : () => _open(
                        (account) => _services.openDraft(account, draft.id)),
                trailing: IconButton(
                    tooltip: _l('删除本地草稿', 'Delete local draft'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _opening ? null : () => _removeDraft(draft)),
              )),
          ]));

  String _draftStatus(UploadDraft draft) => switch (draft.remoteState) {
        'deleted' =>
          _l('站内已删除 · 本地只读副本', 'Deleted from website · Read-only local copy'),
        'disowned' =>
          _l('已放弃管理 · 本地只读副本', 'Management disowned · Read-only local copy'),
        _ => draft.serverUri == null
            ? _l('仅在本机', 'Device only')
            : draft.dirty
                ? _l('有未同步修改', 'Unsynced changes')
                : _l('已保存到站点', 'Saved to website'),
      };

  String _taskState(String state) => switch (state) {
        'queued' => _l('等待上传', 'Queued'),
        'sending' => _l('正在发送', 'Sending'),
        'accepted' => _l('站点处理中／待核对', 'Processing / awaiting verification'),
        'confirmed' => _l('已确认接收', 'Receipt confirmed'),
        'completed' =>
          _l('上传已确认，尚不代表公开发布', 'Upload confirmed; not necessarily published'),
        'paused' => _l('已暂停', 'Paused'),
        'uncertain' => _l('结果待核对', 'Result uncertain'),
        'failed' => _l('上传失败', 'Failed'),
        'stopped' => _l('已停止', 'Stopped'),
        _ => _l('状态待核对', 'State needs review'),
      };

  Widget _taskList() => RefreshIndicator(
      onRefresh: _refreshTasks,
      child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_taskLoading && _tasks == null) const LinearProgressIndicator(),
            if (_taskError != null) _error(_taskError!, _refreshTasks),
            if (_tasks?.isEmpty == true && _taskError == null)
              Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_l('没有上传任务。', 'No upload tasks.'))),
            for (final task in _tasks ?? <Map<String, dynamic>>[])
              _taskCard(task),
            RuleNotices(
                location: UploadRuleLocation.tasks, onOpenSource: _source),
          ]));

  Widget _taskCard(Map<String, dynamic> task) {
    final id = task['taskId'] as String;
    final draftId = task['draftId'] is String ? task['draftId'] as String : id;
    final state = task['state'] as String;
    UploadDraft? draft;
    for (final candidate in _drafts) {
      if (candidate.id == draftId) draft = candidate;
    }
    final items = (task['items'] is List ? task['items'] as List : const [])
        .whereType<Map>()
        .toList();
    final confirmed =
        items.where((item) => item['state'] == 'confirmed').length;
    final currentDraft = draft;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                    draft?.title.isNotEmpty == true
                        ? draft!.title
                        : _l('上传任务', 'Upload task'),
                    style: Theme.of(context).textTheme.titleMedium),
                Text(_taskState(state)),
                Text(_l('已确认 $confirmed / ${items.length} 批',
                    '$confirmed / ${items.length} batches confirmed')),
                if (state != 'completed' && task['reason'] is String)
                  Text(uploadIssueMessage(task['reason'] as String, _zh)),
                Wrap(spacing: 8, children: [
                  for (final receipt in _receipts.where((receipt) =>
                      receipt['taskId'] == id &&
                      receipt['acknowledged'] != true &&
                      receipt['receiptId'] is String))
                    TextButton(
                        onPressed: _opening
                            ? null
                            : () =>
                                _reviewReceipt(receipt['receiptId'] as String),
                        child: Text(_l('核对站内结果', 'Review website result'))),
                  if (currentDraft != null)
                    TextButton(
                        onPressed: _opening
                            ? null
                            : () => _open((account) =>
                                _services.openDraft(account, currentDraft.id)),
                        child: Text(_l('查看草稿', 'View draft'))),
                  if (state == 'queued' || state == 'sending')
                    TextButton(
                        onPressed: () => _taskAction('pause', id),
                        child: Text(_l('暂停', 'Pause'))),
                  if (state == 'paused' || state == 'queued')
                    TextButton(
                        onPressed: () => _taskAction('resume', id),
                        child: Text(_l('继续', 'Resume'))),
                  if (state != 'completed' && state != 'stopped')
                    TextButton(
                        onPressed: () => _taskAction('cancel', id),
                        child: Text(_l('停止', 'Stop'))),
                ]),
              ],
            )));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(_l('上传', 'Uploads')),
            actions: [
              IconButton(
                  tooltip: _l('上传规则', 'Upload rules'),
                  onPressed: _rules,
                  icon: const Icon(Icons.help_outline)),
              PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'folders') {
                      _manageFolders();
                    } else {
                      _source(uploadOrigin.resolve('manage'));
                    }
                  },
                  itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'manager',
                            child: Text(_l('官方管理页', 'Official manager'))),
                        PopupMenuItem(
                            value: 'folders',
                            enabled: _account != null && !_opening,
                            child: Text(_l('目录管理', 'Manage folders'))),
                      ]),
            ],
            bottom: _account == null
                ? null
                : TabBar(controller: _tabs, tabs: [
                    Tab(text: _l('我的画廊', 'My galleries')),
                    Tab(text: _l('上传任务', 'Upload tasks')),
                    Tab(text: _l('本地草稿', 'Local drafts')),
                  ])),
        floatingActionButton: _account == null
            ? null
            : FloatingActionButton.extended(
                heroTag: 'gallery-upload-create',
                onPressed: _opening ? null : () => _open(_services.createDraft),
                icon: _opening
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add),
                label: Text(_l('新建画廊', 'New gallery'))),
        body: _account == null
            ? ListView(padding: const EdgeInsets.all(20), children: [
                RuleNotices(
                    location: UploadRuleLocation.account,
                    onOpenSource: _source),
                FilledButton(
                    onPressed: () => Navigator.pushNamed(context, '/login'),
                    child: Text(_l('登录后上传', 'Sign in to upload'))),
              ])
            : TabBarView(
                controller: _tabs,
                children: [_galleryList(), _taskList(), _draftList()]),
      );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _tabChanged();
  }

  @override
  void dispose() {
    _taskTimer?.cancel();
    _draftChanges?.cancel();
    _authChanges?.cancel();
    _tabs.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
