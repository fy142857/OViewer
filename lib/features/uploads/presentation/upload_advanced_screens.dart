import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../blocs/auth/auth_bloc.dart';
import '../../../blocs/auth/auth_state.dart';
import '../data/upload_advanced_actions.dart';
import '../data/upload_protocol.dart';
import '../data/upload_store.dart';
import '../rules/rule_notice.dart';
import '../rules/upload_rules.dart';
import '../upload_services.dart';
import 'upload_editor_screen.dart' show uploadFailureMessage;

String uploadActionLabel(UploadGalleryAction action, bool zh) =>
    switch (action) {
      UploadGalleryAction.publish => zh ? '发布画廊' : 'Publish gallery',
      UploadGalleryAction.delete => zh ? '删除站内画廊' : 'Delete website gallery',
      UploadGalleryAction.disown => zh ? '放弃管理与署名' : 'Disown gallery',
      UploadGalleryAction.clone => zh ? '创建更新版本' : 'Create update draft',
    };

UploadRuleLocation _location(UploadGalleryAction action) => switch (action) {
      UploadGalleryAction.publish => UploadRuleLocation.publish,
      UploadGalleryAction.delete => UploadRuleLocation.delete,
      UploadGalleryAction.disown => UploadRuleLocation.disown,
      UploadGalleryAction.clone => UploadRuleLocation.update,
    };

bool _owner(AuthState state, String account, int generation) =>
    state.isLoggedIn &&
    state.profile.memberId == account &&
    state.sessionGeneration == generation;

Widget _summary(PreparedUploadAction prepared, bool zh) {
  final editor = prepared.editor;
  final category = editor.form.fields['category'];
  final options =
      category?.options.where((o) => o.value == category.value).toList() ?? [];
  final private = category?.value == '0';
  final images = editor.images;
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SelectableText(editor.form.fields['gname_en']?.value ?? '',
        style: const TextStyle(fontWeight: FontWeight.bold)),
    Text(
        '${zh ? '上传管理编号' : 'Upload management ID'}: ${uploadGalleryId(prepared.editorUri) ?? ''}'),
    Text(
        '${zh ? '分类' : 'Category'}: ${options.isEmpty ? category?.value ?? '' : options.first.label}'),
    Text(private
        ? (zh ? '私人／不公开列出' : 'Private / Unlisted')
        : (zh ? '公开分类' : 'Public category')),
    Text(
        '${zh ? '站内图片数' : 'Website images'}: ${editor.metadata['Uploaded Files'] ?? images.length}'),
    if (images.isNotEmpty) ...[
      Text('${zh ? '首页' : 'First'}: ${images.first.name}'),
      Text('${zh ? '末页' : 'Last'}: ${images.last.name}'),
    ],
  ]);
}

/// Fetch before asking. The exact reviewed snapshot is passed to perform, which
/// checks it again before sending the first state-changing request.
Future<UploadActionResult?> reviewUploadAction(
    BuildContext context,
    UploadServices services,
    UploadDraft draft,
    UploadGalleryAction action) async {
  final auth = context.read<AuthBloc>();
  final generation = auth.state.sessionGeneration;
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  PreparedUploadAction prepared;
  try {
    prepared = await services.prepareAdvanced(draft, action);
  } catch (error) {
    if (!context.mounted || !_owner(auth.state, draft.accountId, generation)) {
      return null;
    }
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: Text(uploadActionLabel(action, zh)),
              content: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    Text(uploadFailureMessage(error, zh)),
                    RuleNotices(
                        location: _location(action),
                        onOpenSource: services.openExternal),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(zh ? '关闭' : 'Close')),
              ],
            ));
    return null;
  }
  if (!context.mounted || !_owner(auth.state, draft.accountId, generation)) {
    return null;
  }
  final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => BlocBuilder<AuthBloc, AuthState>(
          bloc: auth,
          builder: (context, state) {
            if (!_owner(state, draft.accountId, generation)) {
              return AlertDialog(
                  title: Text(zh ? '登录状态已改变' : 'Login state changed'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: Text(zh ? '关闭' : 'Close')),
                  ]);
            }
            return AlertDialog(
                title: Text(uploadActionLabel(action, zh)),
                content: SizedBox(
                    width: 520,
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          _summary(prepared, zh),
                          const SizedBox(height: 12),
                          RuleNotices(
                              location: _location(action),
                              onOpenSource: services.openExternal),
                          if (prepared.editor.form.fields['category']?.value ==
                              '0')
                            RuleNotices(
                                location: UploadRuleLocation.visibility,
                                onOpenSource: services.openExternal),
                          if (action == UploadGalleryAction.delete ||
                              action == UploadGalleryAction.disown)
                            Text(zh
                                ? '这项操作针对站内画廊；本机复制件和原始文件不会随之删除。'
                                : 'This affects the website gallery; local copies and original files are retained.'),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(zh ? '取消' : 'Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(zh
                          ? '确认${uploadActionLabel(action, true)}'
                          : 'Confirm ${uploadActionLabel(action, false)}')),
                ]);
          }));
  if (confirmed != true ||
      !context.mounted ||
      !_owner(auth.state, draft.accountId, generation)) return null;
  return services.performAdvanced(draft, prepared, confirmed: true);
}

class UploadStatisticsScreen extends StatefulWidget {
  final UploadServices services;
  final UploadDraft draft;
  const UploadStatisticsScreen(
      {super.key, required this.services, required this.draft});
  @override
  State<UploadStatisticsScreen> createState() => _UploadStatisticsScreenState();
}

class _UploadStatisticsScreenState extends State<UploadStatisticsScreen> {
  late Future<UploadStatsSnapshot> _request;
  late int _generation;
  @override
  void initState() {
    super.initState();
    _generation = context.read<AuthBloc>().state.sessionGeneration;
    _request = widget.services.statistics(widget.draft);
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return BlocBuilder<AuthBloc, AuthState>(
        builder: (context, auth) => Scaffold(
              appBar: AppBar(title: Text(zh ? '画廊统计' : 'Gallery statistics')),
              body: !_owner(auth, widget.draft.accountId, _generation)
                  ? Center(
                      child: Text(zh
                          ? '登录状态已改变，请返回重新打开。'
                          : 'Login state changed. Reopen this page.'))
                  : FutureBuilder<UploadStatsSnapshot>(
                      future: _request,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        if (snapshot.hasError) {
                          return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(children: [
                                Text(uploadFailureMessage(snapshot.error!, zh)),
                                TextButton(
                                    onPressed: () => setState(() => _request =
                                        widget.services
                                            .statistics(widget.draft)),
                                    child: Text(zh ? '重新读取' : 'Reload')),
                                RuleNotices(
                                    location: UploadRuleLocation.statistics,
                                    onOpenSource: widget.services.openExternal),
                              ]));
                        }
                        final data = snapshot.data!;
                        return ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              SelectableText(data.title,
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              RuleNotices(
                                  location: UploadRuleLocation.statistics,
                                  onOpenSource: widget.services.openExternal),
                              for (final table in data.tables)
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Table(
                                            defaultColumnWidth:
                                                const IntrinsicColumnWidth(),
                                            border: TableBorder.all(
                                                color: Theme.of(context)
                                                    .dividerColor),
                                            children: [
                                              for (final row in table)
                                                TableRow(children: [
                                                  for (var i = 0;
                                                      i <
                                                          table
                                                              .map((r) =>
                                                                  r.length)
                                                              .reduce((a, b) =>
                                                                  a > b
                                                                      ? a
                                                                      : b);
                                                      i++)
                                                    Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .all(8),
                                                        child: SelectableText(
                                                            i < row.length
                                                                ? row[i]
                                                                : '')),
                                                ]),
                                            ]))),
                              for (final note in data.notes)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Text(note)),
                              TextButton(
                                  onPressed: () =>
                                      widget.services.openExternal(data.uri),
                                  child: Text(zh
                                      ? '在官方网站查看完整统计'
                                      : 'View full website statistics')),
                            ]);
                      }),
            ));
  }
}

class _BatchEntry {
  final ManagedUploadGallery gallery;
  UploadDraft? draft;
  PreparedUploadAction? prepared;
  String state = 'checking';
  Object? error;
  _BatchEntry(this.gallery);
}

class UploadBulkAdvancedScreen extends StatefulWidget {
  final UploadServices services;
  final String accountId;
  final UploadGalleryAction action;
  final List<ManagedUploadGallery> targets;
  UploadBulkAdvancedScreen(
      {super.key,
      required this.services,
      required this.accountId,
      required this.action,
      required List<ManagedUploadGallery> targets})
      : targets = List.unmodifiable(targets);
  @override
  State<UploadBulkAdvancedScreen> createState() =>
      _UploadBulkAdvancedScreenState();
}

class _UploadBulkAdvancedScreenState extends State<UploadBulkAdvancedScreen> {
  late final List<_BatchEntry> _entries;
  late int _generation;
  bool _checking = true;
  bool _running = false;
  bool _stop = false;
  bool _finished = false;
  bool get _current =>
      mounted &&
      _owner(context.read<AuthBloc>().state, widget.accountId, _generation);
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  @override
  void initState() {
    super.initState();
    _generation = context.read<AuthBloc>().state.sessionGeneration;
    _entries = widget.targets.map(_BatchEntry.new).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    _stop = true;
    super.dispose();
  }

  Future<void> _prepare() async {
    for (final entry in _entries) {
      if (!_current || _stop) break;
      try {
        final uri = entry.gallery.managementUri;
        if (uri == null) {
          throw const UploadFailure(UploadFailureKind.protocolChanged);
        }
        final editing = await widget.services.openRemote(widget.accountId, uri);
        if (!_current) return;
        entry.draft = editing.draft;
        entry.prepared =
            await widget.services.prepareAdvanced(editing.draft, widget.action);
        if (!_current) return;
        entry.state = 'ready';
      } catch (error) {
        entry.error = error;
        final skip = _canSkip(error);
        entry.state = skip ? 'skipped' : 'failed';
        if (!skip) {
          _stop = true;
          // A site/session/network failure stops the entire review. Do not
          // execute earlier entries against an incompletely checked batch.
          for (final ready in _entries.where((e) => e.state == 'ready')) {
            ready.state = 'not_executed';
          }
        }
      }
      if (_current) setState(() {});
    }
    if (_current) {
      setState(() {
        _checking = false;
        for (final entry in _entries.where((e) => e.state == 'checking')) {
          entry.state = 'not_executed';
        }
      });
    }
  }

  bool _canSkip(Object error) =>
      error is UploadFailure &&
      error.kind == UploadFailureKind.restricted &&
      {'unavailable_action', 'public_delete_forbidden', 'gallery_changed'}
          .contains(error.code);

  Future<void> _execute() async {
    if (!_current || _checking || _running || _finished) return;
    final ready = _entries.where((e) => e.state == 'ready').toList();
    if (ready.isEmpty) return;
    final authBloc = context.read<AuthBloc>();
    final publishing = widget.action == UploadGalleryAction.publish;
    var agreedTerms = false;
    Object? termsLinkError;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => BlocBuilder<AuthBloc, AuthState>(
                bloc: authBloc,
                builder: (_, auth) {
                  if (!_owner(auth, widget.accountId, _generation)) {
                    return AlertDialog(
                        title: Text(_zh ? '登录状态已改变' : 'Login state changed'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(_zh ? '关闭' : 'Close')),
                        ]);
                  }
                  return AlertDialog(
                      title: Text(_zh
                          ? '确认批量${uploadActionLabel(widget.action, true)}'
                          : 'Confirm batch action'),
                      content: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            Text(_zh
                                ? '仅执行下列 ${ready.length} 项；结果可能部分成功，停止不会撤回已经发送的请求。'
                                : 'Only these ${ready.length} targets will run. Partial success is possible; stopping does not undo sent requests.'),
                            for (final entry in ready)
                              Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: _summary(entry.prepared!, _zh)),
                            RuleNotices(
                                location: _location(widget.action),
                                onOpenSource: widget.services.openExternal),
                            if (ready.any((entry) =>
                                entry.prepared!.editor.form.fields['category']
                                    ?.value ==
                                '0'))
                              RuleNotices(
                                  location: UploadRuleLocation.visibility,
                                  onOpenSource: widget.services.openExternal),
                            if (publishing) ...[
                              TextButton(
                                  onPressed: () async {
                                    try {
                                      await widget.services.openExternal(
                                          Uri.parse(
                                              'https://e-hentai.org/tos.php'));
                                    } catch (error) {
                                      if (ctx.mounted && _current) {
                                        update(() => termsLinkError = error);
                                      }
                                    }
                                  },
                                  child: Text(_zh
                                      ? '阅读 E-Hentai 服务条款'
                                      : 'Read E-Hentai Terms of Service')),
                              if (termsLinkError != null)
                                Text(
                                    uploadFailureMessage(termsLinkError!, _zh)),
                              CheckboxListTile(
                                  key: const ValueKey(
                                      'upload-batch-publication-terms'),
                                  contentPadding: EdgeInsets.zero,
                                  value: agreedTerms,
                                  onChanged: (value) =>
                                      update(() => agreedTerms = value == true),
                                  title: Text(_zh
                                      ? '我已阅读并同意服务条款，仅授权本次清单中的画廊发布'
                                      : 'I have read and agree to the Terms of Service for publishing only the galleries in this reviewed list')),
                            ],
                          ])),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(_zh ? '取消' : 'Cancel')),
                        FilledButton(
                            onPressed: !publishing || agreedTerms
                                ? () => Navigator.pop(ctx, true)
                                : null,
                            child: Text(
                                _zh ? '确认执行以上清单' : 'Confirm listed targets')),
                      ]);
                })));
    if (confirmed != true || !_current || (publishing && !agreedTerms)) return;
    setState(() {
      _running = true;
      _stop = false;
    });
    UploadPublicationTermsConsent? terms;
    try {
      if (publishing) {
        terms = await widget.services.acceptPublicationTerms(
            ready.map((entry) => entry.prepared!).toList(),
            confirmed: true);
      }
    } catch (error) {
      if (_current) {
        setState(() {
          for (final entry in ready) {
            entry.state = 'not_executed';
          }
          ready.first.state = 'failed';
          ready.first.error = error;
          _running = false;
          _finished = true;
        });
      }
      return;
    }
    for (final entry in ready) {
      if (!_current || _stop) break;
      setState(() => entry.state = 'running');
      try {
        if (terms == null) {
          await widget.services
              .performAdvanced(entry.draft!, entry.prepared!, confirmed: true);
        } else {
          await widget.services.performAdvanced(entry.draft!, entry.prepared!,
              confirmed: true, publicationTerms: terms);
        }
        entry.state = 'success';
      } catch (error) {
        entry.error = error;
        final skip = _canSkip(error);
        entry.state = error is UploadFailure &&
                error.kind == UploadFailureKind.resultUncertain
            ? 'uncertain'
            : skip
                ? 'skipped'
                : 'failed';
        if (!skip) _stop = true;
      }
      if (_current) setState(() {});
    }
    if (_current) {
      setState(() {
        _running = false;
        _finished = true;
        for (final entry in _entries.where((e) => e.state == 'ready')) {
          entry.state = 'not_executed';
        }
      });
    }
  }

  String _state(String value) => _zh
      ? const {
            'checking': '正在检查',
            'ready': '等待确认',
            'running': '正在执行',
            'success': '已确认完成',
            'failed': '失败',
            'skipped': '已跳过',
            'uncertain': '结果待核对',
            'not_executed': '未执行',
          }[value] ??
          value
      : value.replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) => BlocBuilder<AuthBloc, AuthState>(
      builder: (context, auth) => PopScope(
          canPop: !_running || !_owner(auth, widget.accountId, _generation),
          onPopInvoked: (popped) {
            if (!popped && _running) setState(() => _stop = true);
          },
          child: Scaffold(
            appBar: AppBar(
                title: Text(_zh
                    ? '批量${uploadActionLabel(widget.action, true)}'
                    : 'Batch ${uploadActionLabel(widget.action, false)}')),
            body: !_owner(auth, widget.accountId, _generation)
                ? Center(
                    child: Text(
                        _zh ? '登录状态已改变，请返回。' : 'Login state changed. Go back.'))
                : ListView(padding: const EdgeInsets.all(16), children: [
                    RuleNotices(
                        location: UploadRuleLocation.bulk,
                        onOpenSource: widget.services.openExternal),
                    if (_checking || _running) const LinearProgressIndicator(),
                    for (final entry in _entries)
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(entry.gallery.title),
                                    Text(_state(entry.state)),
                                    if (entry.error != null)
                                      Text(uploadFailureMessage(
                                          entry.error!, _zh)),
                                  ]))),
                    if (!_checking &&
                        !_running &&
                        !_finished &&
                        _entries.any((e) => e.state == 'ready'))
                      FilledButton(
                          onPressed: _execute,
                          child:
                              Text(_zh ? '核对清单并确认执行' : 'Review and confirm')),
                    if (_running)
                      OutlinedButton(
                          onPressed:
                              _stop ? null : () => setState(() => _stop = true),
                          child: Text(_zh
                              ? (_stop ? '当前请求完成后停止' : '停止后续操作')
                              : (_stop
                                  ? 'Stopping after current request'
                                  : 'Stop remaining actions'))),
                    if (_finished)
                      Text(_zh
                          ? '不会自动重试失败或待核对项。返回管理列表查看最新状态；未决请求可在对应本地草稿中核对。'
                          : 'Failed and uncertain actions are not retried automatically. Refresh the manager; review pending requests in their local drafts.'),
                  ]),
          )));
}
