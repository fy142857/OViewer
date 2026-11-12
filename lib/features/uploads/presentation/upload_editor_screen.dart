import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../blocs/auth/auth_bloc.dart';
import '../../../blocs/auth/auth_state.dart';
import '../../../core/router/app_page_route.dart';
import '../data/upload_protocol.dart';
import '../data/upload_advanced_actions.dart';
import '../data/upload_repository.dart';
import '../data/upload_store.dart';
import '../files/upload_asset.dart';
import '../files/upload_asset_preparer.dart';
import '../files/upload_file_io.dart';
import '../rules/rule_notice.dart';
import '../rules/upload_rules.dart';
import '../upload_services.dart';
import 'upload_editor_form.dart';
import 'upload_management_screens.dart';
import 'upload_web_page.dart';
import 'upload_advanced_screens.dart';

String uploadFailureMessage(Object error, bool zh) {
  String l(String cn, String en) => zh ? cn : en;
  if (error is UploadFailure) {
    if (error.code == 'public_to_private_forbidden') {
      return l('已公开发布的画廊不能改为私人／不公开列出。此次分类修改未提交。',
          'A published public gallery cannot be made private or unlisted. This category change was not submitted.');
    }
    return switch (error.kind) {
      UploadFailureKind.loginRequired =>
        l('登录已失效，请重新登录后继续。', 'Your login expired. Sign in again to continue.'),
      UploadFailureKind.sessionChanged => l('账号或登录状态已改变，请重新进入上传页面。',
          'The account or session changed. Reopen the upload page.'),
      UploadFailureKind.network => l('无法连接上传站点，请检查当前网络和代理后重试。',
          'Cannot reach the upload website. Check the network and proxy, then retry.'),
      UploadFailureKind.restricted => error.serverMessage?.isNotEmpty == true
          ? '${l('站点说明', 'Website explanation')}: ${error.serverMessage}'
          : l('站点当前不允许此操作，请刷新并查看权限说明。',
              'The website currently restricts this action. Refresh and check the permissions.'),
      UploadFailureKind.protocolChanged => l('暂时无法识别站点返回的页面，已停止操作；请在官方网页核对。',
          'The website response could not be recognized. The action stopped; review it on the official website.'),
      UploadFailureKind.resultUncertain => l('站点可能已经处理请求，但结果尚未确认。请先核对，勿重复提交。',
          'The website may have processed the request, but the result is unconfirmed. Check before submitting again.'),
    };
  }
  if (error is UploadVisibilityConfirmationRequired) {
    return l('请重新核对将私人画廊转为公开分类的影响，再确认保存。',
        'Review and confirm making this private gallery public before saving.');
  }
  if (error is UploadCancelled) {
    return l('已取消本次文件准备。', 'File preparation was cancelled.');
  }
  if (error is UploadImportException) {
    return error.problems
        .map((problem) =>
            '${problem['displayName'] ?? ''}: ${uploadIssueMessage(problem['reason'] ?? problem['code'] ?? '', zh)}')
        .join('\n');
  }
  if (error is MissingPluginException) {
    return l('当前设备的上传服务不可用，任务状态尚未确认。',
        'The upload service is unavailable on this device. Task state is not confirmed.');
  }
  if (error is UploadFileException) return uploadIssueMessage(error.code, zh);
  if (error is PlatformException) return uploadIssueMessage(error.code, zh);
  return l('操作未完成，请重试。本地未提交内容会保留。',
      'The operation did not finish. Retry; unsubmitted local content is retained.');
}

String uploadIssueMessage(String code, bool zh) {
  const aliases = {
    'unsupported_image': 'unsupported_format',
    'image_dimensions': 'invalid_dimensions',
    'encrypted_archive': 'zip_encrypted',
    'unsupported_zip_method': 'unsupported_compression',
    'archive_checksum': 'corrupt_archive',
    'archive_header_mismatch': 'corrupt_archive',
    'archive_overlapping_entries': 'corrupt_archive',
    'corrupt_file': 'corrupt_image',
  };
  code = aliases[code] ?? code;
  const descriptions = <String, List<String>>{
    'waiting_wifi': [
      '任务等待可确认的 Wi-Fi 连接；连接后可继续。',
      'Waiting for a verified Wi-Fi connection. Resume after connecting.'
    ],
    'wifi_network_unknown': [
      '无法确认当前网络为 Wi-Fi，任务已暂停。部分旧系统的 VPN 不提供底层网络信息；可停止尚未发送的任务，再在草稿中关闭“仅 Wi-Fi”后重新提交。',
      'The current network cannot be verified as Wi-Fi, so this task is paused. Some older systems do not report the network under a VPN. Stop an unsent task, turn off Wi-Fi only in its draft, then submit again to use the current network.'
    ],
    'wifi_network_changed': [
      '发送前网络已改变，任务已暂停。确认 Wi-Fi 连接后再继续。',
      'The network changed before sending. The task is paused; verify Wi-Fi before resuming.'
    ],
    'wifi_changed_after_send': [
      '发送开始后网络条件发生变化，传输已停止。请先核对站内接收结果，不要直接重新上传。',
      'The network condition changed after sending began and the transfer stopped. Review the website result before sending anything again.'
    ],
    'redirect_requires_verification': [
      '站点响应尚不能确认接收。请核对站内结果，不要直接重新上传。',
      'The website response does not confirm receipt. Review the website result before sending anything again.'
    ],
    'unsupported_format': [
      '不支持此文件格式，请先转换为支持的图片格式。',
      'Unsupported file format. Convert it to a supported image format first.'
    ],
    'corrupt_image': ['图片损坏或不完整。', 'The image is corrupt or incomplete.'],
    'invalid_image': [
      '图片未通过上传检查。',
      'The image did not pass upload validation.'
    ],
    'invalid_image_metadata': [
      '图片的格式、尺寸或容量不符合要求。',
      'The image format, dimensions, or size do not meet the requirements.'
    ],
    'image_too_large': [
      '图片超过该格式的单文件大小上限。',
      'The image exceeds the size limit for its format.'
    ],
    'invalid_dimensions': [
      '图片尺寸超出允许范围。',
      'The image dimensions are outside the allowed range.'
    ],
    'minimum_dimensions_server_check': [
      '图片接近最小尺寸，仍需站点确认能否接收。',
      'The image is near the minimum dimensions; website acceptance still needs confirmation.'
    ],
    'apng_display_support': [
      'APNG 动画在站点默认展示中可能无法保留。',
      'APNG animation may not be preserved in the website’s default view.'
    ],
    'gallery_too_many_images': [
      '画廊图片总数超过上限。',
      'The gallery contains too many images.'
    ],
    'gallery_too_large': [
      '画廊图片总容量超过上限。',
      'The gallery total exceeds its size limit.'
    ],
    'duplicate_image': [
      '发现相同内容，请检查是否需要保留重复图片。',
      'Identical content found. Review whether the duplicate should remain.'
    ],
    'file_missing': [
      '文件复制件已不存在，请重新导入。',
      'The imported copy is missing. Import it again.'
    ],
    'file_changed': [
      '文件在准备期间发生变化，请重新导入并检查。',
      'The file changed during preparation. Import and review it again.'
    ],
    'insufficient_space': [
      '设备可用空间不足，请释放空间后重试。',
      'Not enough free storage. Free space and retry.'
    ],
    'not_enough_space': [
      '设备可用空间不足，请释放空间后重试。',
      'Not enough free storage. Free space and retry.'
    ],
    'zip_encrypted': [
      '不支持加密 ZIP，请解密后重新导入。',
      'Encrypted ZIPs are unsupported. Decrypt before importing.'
    ],
    'unsupported_compression': [
      '不支持此 ZIP 压缩方法，请先解压后选择图片。',
      'Unsupported ZIP compression. Extract it and select the images.'
    ],
    'corrupt_archive': [
      '压缩包损坏或校验失败，请重新取得完整文件。',
      'The archive is corrupt or failed verification. Obtain a complete copy.'
    ],
    'split_archive': [
      '不支持分卷压缩包，请先合并解压后导入图片。',
      'Split archives are unsupported. Extract the complete set and import the images.'
    ],
    'nested_archive': [
      '不会递归展开嵌套压缩包，请单独解压后导入图片。',
      'Nested archives are not recursively expanded. Extract them separately and import the images.'
    ],
    'unsupported_archive_entry': [
      '包内此项目不是支持的图片，未加入上传清单。',
      'This archive entry is not a supported image and was not added to the upload list.'
    ],
    'archive_has_no_images': [
      '压缩包中没有可导入的图片。',
      'The archive contains no importable images.'
    ],
    'archive_expanded_too_large': [
      '压缩包展开后超过容量上限，请拆分后导入。',
      'Expanded archive contents exceed the size limit. Split them before importing.'
    ],
    'archive_too_many_entries': [
      '压缩包条目过多，请拆分后导入。',
      'The archive has too many entries. Split it before importing.'
    ],
    'archive_filename_encoding': [
      '无法可靠识别压缩包文件名，请先解压并检查名称。',
      'Archive filenames could not be decoded reliably. Extract and check them first.'
    ],
    'archive_special_file': [
      '压缩包包含链接或特殊文件，不能作为图片导入。',
      'The archive contains links or special files that cannot be imported as images.'
    ],
    'unsupported_conversion': [
      '此设备不支持该格式的静态图片转换，请使用其他工具转换后导入。',
      'This device cannot convert that still-image format. Convert it with another tool before importing.'
    ],
    'animated_image': [
      '检测到动画或多帧内容，不会将其转换成单帧 PNG。',
      'Animation or multiple frames were detected. They will not be flattened to a single PNG.'
    ],
    'unsafe_path': [
      '压缩包包含不安全路径，已停止导入。',
      'The archive contains an unsafe path. Import stopped.'
    ],
    'verification_required': [
      '先核对站点是否收到上一批文件，再决定是否重试。',
      'Check whether the website received the previous batch before retrying.'
    ],
    'foreground_required': [
      '请保持应用在前台，重新开始本次上传。',
      'Keep the app in the foreground to start this upload.'
    ],
    'stale_session': [
      '登录状态已改变，请重新进入上传页面。',
      'The login session changed. Reopen the upload page.'
    ],
    'proxy_unsupported': [
      '当前后台上传不支持此代理配置，未改为直连。',
      'This proxy configuration is unsupported for background upload. No direct connection was attempted.'
    ],
    'photos_denied': [
      '未获相册访问权限，可从文件导入或在系统设置中授权。',
      'Photo access was not granted. Import from Files or allow access in system settings.'
    ],
    'busy': [
      '另一个上传操作仍在进行，请稍后再试。',
      'Another upload operation is still running. Try again shortly.'
    ],
  };
  final value = descriptions[code];
  return value == null
      ? (zh
          ? '此项目未完成，请检查文件或在官方网页核对后重试。'
          : 'This item did not complete. Check the file or the official website before retrying.')
      : value[zh ? 0 : 1];
}

String uploadBytes(int bytes) => bytes >= 1000000000
    ? '${(bytes / 1000000000).toStringAsFixed(2)} GB'
    : bytes >= 1000000
        ? '${(bytes / 1000000).toStringAsFixed(2)} MB'
        : '${(bytes / 1000).toStringAsFixed(1)} KB';

class _RecoveryChoice {
  final Uri? selectedEditor;
  final bool noEffect;
  const _RecoveryChoice({this.selectedEditor, this.noEffect = false});
}

class UploadEditorScreen extends StatefulWidget {
  final UploadEditingSession session;
  final UploadServices? services;
  const UploadEditorScreen({super.key, required this.session, this.services});

  @override
  State<UploadEditorScreen> createState() => _UploadEditorScreenState();
}

class _UploadEditorScreenState extends State<UploadEditorScreen> {
  late final UploadServices _services;
  late UploadEditingSession _session;
  late UploadDraft _draft;
  int _formEpoch = 0;
  late final AuthBloc _auth;
  late final int _generation;
  StreamSubscription<AuthState>? _authChanges;
  ModalRoute<dynamic>? _route;
  Timer? _saveTimer;
  Future<void> _saveQueue = Future<void>.value();
  Directory? _root;
  bool _invalidated = false;
  bool _savingLocal = false;
  bool _wifiOnly = false;
  bool _transferLocked = false;
  List<UploadAssetProgress> _assetProgress = [];
  bool _transferReady = false;
  bool _leaving = false;
  String? _busy;
  Object? _error;
  Object? _localError;
  Object? _transferError;
  PendingUploadWrite? _pendingWrite;
  Object? _pendingError;
  bool _pendingChecked = false;
  List<Map<String, String>> _importProblems = [];

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _l(String cn, String en) => _zh ? cn : en;
  bool get _current =>
      mounted &&
      !_invalidated &&
      _auth.state.isLoggedIn &&
      _auth.state.profile.memberId == _draft.accountId &&
      _auth.state.sessionGeneration == _generation;
  bool get _terminal => {'deleted', 'disowned'}.contains(_draft.remoteState);
  bool get _filesEditable =>
      _busy == null &&
      !_transferLocked &&
      !_terminal &&
      (_session.editor.canUpload || _session.localOnly);

  @override
  void initState() {
    super.initState();
    _services = widget.services ?? GetIt.I<UploadServices>();
    _session = widget.session;
    _draft = _session.draft;
    _auth = context.read<AuthBloc>();
    _generation = _auth.state.sessionGeneration;
    _authChanges = _auth.stream.listen((state) {
      if (!state.isLoggedIn ||
          state.profile.memberId != _draft.accountId ||
          state.sessionGeneration != _generation) _invalidate();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_current) {
        _invalidate();
        return;
      }
      _loadRoot();
      _checkTransfer();
      _loadPending();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _saveTimer?.cancel();
    setState(() => _invalidated = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = _route;
      final navigator = Navigator.of(context);
      if (route == null || !route.isActive) return;
      navigator.popUntil(
          (candidate) => identical(candidate, route) || candidate.isFirst);
      if (route.isCurrent && navigator.canPop()) navigator.pop();
    });
  }

  Future<void> _loadRoot() async {
    try {
      final store = await _services.store;
      if (_current) setState(() => _root = store.root);
    } catch (error) {
      if (_current) setState(() => _localError = error);
    }
  }

  Future<void> _loadPending() async {
    try {
      final pending = await _services.pendingWrite(_draft);
      if (_current) {
        setState(() {
          _pendingWrite = pending;
          _pendingChecked = true;
          _pendingError = null;
        });
      }
    } catch (error) {
      if (_current) {
        setState(() {
          _pendingError = error;
          _pendingChecked = false;
        });
      }
    }
  }

  Future<void> _checkTransfer() async {
    try {
      final snapshot = await _services.transferSnapshot();
      if (!_current) return;
      final tasks = snapshot['tasks'];
      if (tasks is! List || tasks.any((task) => task is! Map)) {
        throw const FormatException('Invalid upload task snapshot');
      }
      final progress =
          await _services.assetProgress(_draft, snapshot: snapshot);
      if (!_current) return;
      final active = tasks
          .whereType<Map>()
          .where((task) =>
              task['accountId'] == _draft.accountId &&
              (task['draftId'] ?? task['taskId']) == _draft.id &&
              (task['blocksEditing'] == true ||
                  (task['blocksEditing'] != false &&
                      (task['reconciliationRequired'] == true ||
                          !{
                            'cancelled',
                            'removed',
                            'completed',
                            'stopped',
                            'failed'
                          }.contains(task['state']) ||
                          ((task['items'] as List?) ?? const [])
                              .whereType<Map>()
                              .any((item) => {
                                    'sending',
                                    'accepted',
                                    'uncertain'
                                  }.contains(item['state']))))))
          .toList();
      setState(() {
        _transferReady = true;
        _transferError = null;
        _transferLocked = active.isNotEmpty;
        _assetProgress = progress;
      });
    } catch (error) {
      if (_current) {
        setState(() {
          _transferError = error;
          _transferReady = false;
        });
      }
    }
  }

  bool _sameFields(Map<String, List<String>> a, Map<String, List<String>> b) =>
      a.length == b.length &&
      a.keys.every((key) =>
          b.containsKey(key) &&
          a[key]!.length == b[key]!.length &&
          Iterable<int>.generate(a[key]!.length)
              .every((i) => a[key]![i] == b[key]![i]));

  void _changed(Map<String, List<String>> values) {
    if (!_current || _busy != null) return;
    final merged = {..._draft.fields, ...values};
    if (_sameFields(merged, _draft.fields)) return;
    setState(() {
      _draft = _draft.copyWith(fields: merged, dirty: true);
      _localError = null;
      _savingLocal = true;
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () => _flushLocal());
  }

  Future<void> _flushLocal() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final captured = _draft;
    final next = _saveQueue.then((_) async {
      if (!_current) return;
      try {
        final saved = await _services.saveLocal(captured);
        if (_current && identical(_draft, captured)) {
          setState(() {
            _draft = saved;
            _savingLocal = false;
            _localError = null;
          });
        }
      } catch (error) {
        if (_current) {
          setState(() {
            _localError = error;
            _savingLocal = false;
          });
        }
      }
    });
    _saveQueue = next;
    return next;
  }

  Future<void> _run(String kind, Future<void> Function() work) async {
    if (!_current || _busy != null) return;
    if ({'save', 'upload', 'publish', 'delete', 'disown', 'clone'}
            .contains(kind) &&
        (!_pendingChecked || _pendingWrite != null)) return;
    setState(() {
      _busy = kind;
      _error = null;
    });
    try {
      await _flushLocal();
      if (!_current || _localError != null) return;
      await work();
    } on UploadImportException catch (error) {
      if (_current) {
        setState(() {
          _draft = error.draft;
          _importProblems = error.problems;
        });
      }
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (_current &&
          {'upload', 'import', 'refresh', 'reconcile', 'website'}
              .contains(kind)) {
        await _checkTransfer();
      }
      if (_current &&
          {
            'save',
            'upload',
            'publish',
            'delete',
            'disown',
            'clone',
            'refresh',
            'reconcile',
            'website'
          }.contains(kind)) {
        await _loadPending();
      }
      if (_current) setState(() => _busy = null);
    }
  }

  Future<void> _saveRemote() => _run('save', () async {
        final submitted = _draft;
        final consent = await _services.prepareVisibilityChange(submitted);
        if (!mounted || !_current) return;
        if (consent != null) {
          final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                    key: const ValueKey('upload-visibility-dialog'),
                    title: Text(
                        _l('确认公开私人画廊', 'Confirm making this gallery public')),
                    content: SingleChildScrollView(
                        child: UploadVisibilitySummary(
                            consent: consent,
                            onOpenSource: _services.openExternal)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(_l('取消', 'Cancel'))),
                      FilledButton(
                          key: const ValueKey('upload-visibility-confirm'),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(_l('确认公开并保存', 'Make public and save'))),
                    ],
                  ));
          if (confirmed != true || !_current) return;
        }
        final session = consent == null
            ? await _services.saveRemote(submitted)
            : await _services.saveRemoteWithVisibility(submitted, consent);
        if (_current) {
          setState(() {
            _session = session;
            _draft = session.draft;
            if (!session.draft.dirty) _formEpoch++;
          });
        }
      });

  Future<void> _import(bool photos) async {
    if (!_filesEditable) return;
    await _run('import', () async {
      if (_transferLocked) return;
      final draft = await _services.importFiles(_draft,
          photos: photos, language: _zh ? 'zh' : 'en');
      if (_current) {
        setState(() {
          _draft = draft;
          _importProblems = [];
        });
      }
    });
  }

  Future<void> _refresh() => _run('refresh', () async {
        final refreshed =
            await _services.openDraft(_draft.accountId, _draft.id);
        if (!_current) return;
        setState(() {
          _draft = refreshed.draft;
          _session = refreshed;
        });
        await _checkTransfer();
      });

  Future<void> _openSource(Uri uri) async {
    if (!_current) return;
    if (uri.host == uploadOrigin.host) return _openWebsite(uri);
    await _services.openExternal(uri);
  }

  Future<void> _associatePending() => _run('reconcile', () async {
        final pending = _pendingWrite;
        if (pending == null) return;
        final selected = pending.serverUri ??
            await Navigator.push<Uri>(
                context,
                AppPageRoute<Uri>(
                    builder: (_) => UploadGallerySelectionScreen(
                        accountId: _draft.accountId, services: _services)));
        if (selected == null || !_current) return;
        final fresh =
            await _services.repository.editor(_draft.accountId, selected);
        if (!mounted || !_current) return;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title:
                      Text(_l('确认关联此画廊', 'Confirm this gallery association')),
                  content: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(fresh.form.fields['gname_en']?.value ?? ''),
                        Text(
                            'GID ${selected.queryParameters['ulgid']} · ${fresh.metadata['Uploaded Files'] ?? fresh.images.length} ${_l('张', 'images')}'),
                        Text(_l('请确认这是上次请求对应的站内结果。关联会保留本地文件与后来修改，不会发布或删除画廊。',
                            'Confirm this is the website result of the previous request. Linking retains local files and later edits; it does not publish or delete the gallery.')),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(_l('取消', 'Cancel'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child:
                            Text(_l('确认关联并继续编辑', 'Link and continue editing')))
                  ],
                ));
        if (confirmed != true || !_current) return;
        final linked = await _services.associatePendingGallery(_draft, selected,
            expectedOperationId: pending.operationId);
        if (_current) {
          setState(() {
            _session = linked;
            _draft = linked.draft;
            _pendingWrite = null;
          });
        }
      });

  Future<void> _confirmNoChange() async {
    if (!_current || _busy != null || _pendingWrite == null) return;
    final operationId = _pendingWrite!.operationId;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(_l('确认已核对未生效', 'Confirm the request had no effect')),
              content: Text(_l(
                  '只有已在站点核对上次请求没有创建画廊或保存修改时，才可解除待核对状态。判断错误后重试可能创建重复画廊或重复提交。此按钮本身不会重试。',
                  'Clear this state only after checking that the previous request did not create a gallery or save changes. An incorrect decision can cause duplicate creation or submission on retry. This button does not retry by itself.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(_l('继续核对', 'Keep reviewing'))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(_l('已核对未生效', 'Verified no effect')))
              ],
            ));
    if (confirmed != true || !_current) return;
    await _run('reconcile', () async {
      await _services.retryAfterVerifiedNoChange(_draft,
          confirmed: true, expectedOperationId: operationId);
      if (_current) setState(() => _pendingWrite = null);
    });
  }

  bool get _hasAdvancedPending => {
        'publish',
        'delete',
        'disown',
        'clone',
        'unlock'
      }.contains(_pendingWrite?.kind);

  Future<void> _reviewAdvancedPending() => _run('reconcile', () async {
        final pending = _pendingWrite;
        if (pending == null || !_hasAdvancedPending) return;
        final reviewedDraft = _draft;
        final review = await _services.prepareAdvancedRecovery(reviewedDraft);
        if (!mounted || !_current) return;
        if (review.operationId != pending.operationId) {
          throw const UploadFailure(UploadFailureKind.resultUncertain);
        }
        Uri? selected;
        var checkedNoEffect = false;
        final choice = await showDialog<_RecoveryChoice>(
            context: context,
            builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
                  final observed = review.confirmedResult != null;
                  final candidates = review.candidates;
                  final canFinish = observed ||
                      selected != null ||
                      (review.canMarkNoEffect && checkedNoEffect);
                  return AlertDialog(
                    key: const ValueKey('upload-advanced-recovery-dialog'),
                    title: Text(_l(
                        '核对${uploadActionLabel(review.kind, true)}结果',
                        'Review ${uploadActionLabel(review.kind, false)} result')),
                    content: SizedBox(
                        width: 520,
                        child: SingleChildScrollView(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                              Text(
                                  '${_l('提交时的主标题', 'Submitted title')}: ${pending.fields['gname_en']?.firstOrNull ?? ''}'),
                              if (review.editor != null) ...[
                                Text(
                                    '${_l('站点当前标题', 'Current website title')}: ${review.editor!.form.fields['gname_en']?.value ?? ''}'),
                                Text(
                                    '${_l('上传管理编号', 'Upload management ID')}: ${uploadGalleryId(review.editor!.uri)}'),
                              ],
                              if (observed)
                                Text(_l('当前站点状态已确认这项操作的结果。确认后只更新本地记录，不会重新发送操作。',
                                    'The current website state confirms the result. Confirmation updates local records without sending the action again.')),
                              if (observed &&
                                  review.kind == UploadGalleryAction.disown)
                                Text(_l('已不再拥有此画廊的管理权；署名移除可能仍有等待期。本机文件保留。',
                                    'You no longer manage this gallery. Name removal may still take time. Local files are retained.')),
                              if (candidates.isNotEmpty) ...[
                                Text(_l(
                                    '以下候选的父画廊链接已核对。请选择此次操作对应的更新版本；相同标题本身不能证明关联。',
                                    'These candidates have verified parent-gallery links. Select the update version corresponding to this operation; a matching title alone is not evidence.')),
                                for (final candidate in candidates)
                                  RadioListTile<Uri>(
                                      key: ValueKey(
                                          'upload-recovery-candidate-${uploadGalleryId(candidate.uri)}'),
                                      value: candidate.uri,
                                      groupValue: selected,
                                      title: Text(candidate
                                              .form.fields['gname_en']?.value ??
                                          ''),
                                      subtitle: Text(
                                          '${_l('上传管理编号', 'Upload management ID')}: ${uploadGalleryId(candidate.uri)} · ${candidate.metadata['Uploaded Files'] ?? candidate.images.length} ${_l('张', 'images')}'),
                                      onChanged: (value) =>
                                          update(() => selected = value)),
                                Text(_l(
                                    '关联只记录你核对的站内结果；不会再次创建版本。尚未上传的本地图片会保留到关联的子稿。',
                                    'Linking records the website result you reviewed and does not create another version. Pending local images are retained in the linked child draft.')),
                              ],
                              if (!observed &&
                                  candidates.isEmpty &&
                                  review.canMarkNoEffect) ...[
                                Text(review.kind == UploadGalleryAction.clone
                                    ? _l(
                                        '原画廊仍可管理且保持锁定；完整管理清单中尚未找到具有对应父链接的更新版本。站点结果仍可能延迟，请先在官方管理页核对。',
                                        'The original gallery remains managed and locked. No matching parent-linked update version was found in the complete manager list. Results may still be delayed; check the official manager first.')
                                    : _l(
                                        '当前站点仍显示操作前的状态。请确认已在站点核对上次操作没有生效；结果仍可能延迟。',
                                        'The website still shows the preceding state. Confirm that you checked the previous action had no effect; results may still be delayed.')),
                                Text(_l(
                                    '人工解除不代表站点保证从未处理请求，也不会自动重试。判断错误后再次操作可能产生重复结果。',
                                    'Manual clearance does not guarantee that the website never processed the request and does not retry it. Retrying after an incorrect decision may duplicate the result.')),
                                CheckboxListTile(
                                    key: const ValueKey(
                                        'upload-recovery-no-effect-check'),
                                    contentPadding: EdgeInsets.zero,
                                    value: checkedNoEffect,
                                    title: Text(_l('我已核对官方管理页与完整清单，确认此次操作未生效',
                                        'I checked the official manager and complete list and found no effect from this operation')),
                                    onChanged: (value) => update(
                                        () => checkedNoEffect = value == true)),
                              ],
                              if (!observed &&
                                  candidates.isEmpty &&
                                  !review.canMarkNoEffect)
                                Text(_l('现有信息不足以确认结果或解除未决状态。请在官方网页继续核对，稍后重新读取。',
                                    'The current evidence cannot confirm or clear this operation. Continue checking the official website and reload later.')),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(_l('继续核对', 'Keep reviewing'))),
                      FilledButton(
                          key: const ValueKey('upload-recovery-confirm'),
                          onPressed: canFinish
                              ? () => Navigator.pop(
                                  ctx,
                                  _RecoveryChoice(
                                      selectedEditor: selected,
                                      noEffect: !observed &&
                                          selected == null &&
                                          checkedNoEffect))
                              : null,
                          child: Text(observed
                              ? _l('确认当前结果', 'Confirm current result')
                              : candidates.isNotEmpty
                                  ? _l('关联选中的更新版本',
                                      'Link selected update version')
                                  : _l('解除待核对状态', 'Clear pending review'))),
                    ],
                  );
                }));
        if (choice == null || !_current) return;
        final result = await _services.resolveAdvancedRecovery(
            reviewedDraft, review,
            selectedEditor: choice.selectedEditor,
            confirmedNoEffect: choice.noEffect);
        if (!_current) return;
        if (result != null) {
          final editing = await _services.openDraft(
              reviewedDraft.accountId, result.localDraftId ?? reviewedDraft.id);
          if (!_current) return;
          setState(() {
            _session = editing;
            _draft = editing.draft;
            _formEpoch++;
          });
        }
        if (!mounted || !_current) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result == null
                ? _l('已记录人工核对并解除未决状态；没有重试操作。',
                    'Manual review was recorded and the pending state cleared. The operation was not retried.')
                : _l('当前站点结果已核对并记录。',
                    'The current website result was verified and recorded.'))));
      });

  Future<void> _openOfficial() => _openWebsite(_terminal
      ? uploadOrigin.resolve('manage')
      : _draft.serverUri ?? uploadOrigin.resolve('manage'));

  Future<void> _openWebsite(Uri uri) => _run('website', () async {
        final draft = _draft;
        int? handoff;
        await Navigator.push<void>(
            context,
            AppPageRoute<void>(
                builder: (_) => UploadWebPage(
                      url: uri,
                      cookies: _services.cookies,
                      auth: _auth,
                      beforeOpen: () async {
                        if (!_current) {
                          throw const UploadFailure(
                              UploadFailureKind.sessionChanged);
                        }
                        handoff =
                            await _services.prepareWebHandoff(draft: draft);
                      },
                      afterClose: () async {
                        if (handoff == null) return;
                        final refreshed = await _services
                            .finishWebHandoff(draft, generation: handoff);
                        if (_current) {
                          setState(() {
                            _session = refreshed;
                            _draft = refreshed.draft;
                            // A clean store snapshot acknowledges earlier edits,
                            // even if the old form still remembers them as dirty.
                            if (!refreshed.draft.dirty) _formEpoch++;
                          });
                        }
                      },
                    )));
      });

  Future<void> _upload() => _run('upload', () async {
        final pending = await _services.pendingAssets(_draft);
        if (!mounted || !_current) return;
        if (pending.isEmpty) {
          throw const UploadFailure(UploadFailureKind.restricted,
              serverMessage:
                  'There are no unconfirmed local images to upload.');
        }
        final count = pending.length;
        final bytes = pending.fold<int>(0, (sum, asset) => sum + asset.size);
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title:
                      Text(_l('确认上传到站内草稿', 'Confirm upload to website draft')),
                  content: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(_draft.title),
                        Text(_l('$count 张图片，共 ${uploadBytes(bytes)}。',
                            '$count images, ${uploadBytes(bytes)} in total.')),
                        Text(_wifiOnly
                            ? _l('仅使用 Wi-Fi。', 'Wi-Fi only.')
                            : _l('跟随当前网络，可能使用移动数据。',
                                'Uses the current network, including mobile data.')),
                        Text(_l('上传完成不会自动公开；你仍需核对内容后手动发布。',
                            'This does not publish automatically. Review the received content before publishing manually.')),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(_l('取消', 'Cancel'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(_l('开始上传', 'Start upload'))),
                  ],
                ));
        if (confirmed != true || !_current) return;
        await _services.startUpload(_draft,
            wifiOnly: _wifiOnly, language: _zh ? 'zh' : 'en');
        if (!_current) return;
        final store = await _services.store;
        final latest = await store.draft(_draft.accountId, _draft.id);
        if (!_current) return;
        setState(() {
          if (latest != null) _draft = latest;
          _transferLocked = true;
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_l('上传任务已提交，可返回上传任务页查看。',
                'The upload task was submitted. View it in Upload tasks.'))));
      });

  Future<void> _publish() => _advanced(UploadGalleryAction.publish);

  Future<void> _advanced(UploadGalleryAction action) =>
      _run(action.name, () async {
        if (_terminal || _session.localOnly) return;
        final result =
            await reviewUploadAction(context, _services, _draft, action);
        if (result == null || !_current) return;
        final editing = result.localDraftId != null
            ? await _services.openDraft(_draft.accountId, result.localDraftId!)
            : await _services.openDraft(_draft.accountId, _draft.id);
        if (!_current) return;
        setState(() {
          _session = editing;
          _draft = editing.draft;
          _formEpoch++;
        });
        await _checkTransfer();
        await _loadPending();
        if (!mounted || !_current) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_l('${uploadActionLabel(action, true)}：站点结果已确认。',
                '${uploadActionLabel(action, false)}: website result confirmed.'))));
      });

  Future<void> _statistics() => _run('statistics', () async {
        await Navigator.push(
            context,
            AppPageRoute(
                builder: (_) => UploadStatisticsScreen(
                    services: _services, draft: _draft)));
      });

  Future<void> _reviewFiles() async {
    if (!_current || _root == null) return;
    await Navigator.push(
        context,
        AppPageRoute(
            builder: (_) => _UploadAssetReview(
                  root: _root!,
                  assets: _draft.assets,
                  confirmedPaths: _assetProgress
                      .where((progress) =>
                          progress.state == UploadAssetState.confirmed)
                      .map((progress) => progress.asset.relativePath)
                      .toSet(),
                  firstSequence: _session.editor.images.length + 1,
                  onConvert: (asset) async {
                    if (!_current || !_filesEditable) {
                      throw const UploadFailure(UploadFailureKind.restricted);
                    }
                    final converted =
                        await _services.convertAsset(_draft, asset);
                    if (!_current) {
                      throw const UploadFailure(
                          UploadFailureKind.sessionChanged);
                    }
                    setState(() => _draft = converted);
                    await _checkTransfer();
                    return converted.assets;
                  },
                  editable: _filesEditable,
                  isCurrent: () => _current,
                  onChanged: (assets) {
                    if (!_current || !_filesEditable) return;
                    setState(() {
                      _draft = _draft.copyWith(assets: assets, dirty: true);
                      _savingLocal = true;
                    });
                    _flushLocal();
                  },
                  onOpenSource: _openSource,
                )));
  }

  Future<void> _reviewRemoteImages() => _run('images', () async {
        if (!mounted || !_current) return;
        await Navigator.push(
            context,
            AppPageRoute(
                builder: (_) => RemoteUploadImagesScreen(
                    accountId: _draft.accountId,
                    initial: _session.editor,
                    services: _services)));
        if (!_current) return;
        final refreshed =
            await _services.openDraft(_draft.accountId, _draft.id);
        if (_current) {
          setState(() {
            _session = refreshed;
            _draft = refreshed.draft;
          });
        }
      });

  Future<bool> _leave() async {
    if (_invalidated) return true;
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      FocusScope.of(context).unfocus();
      return false;
    }
    await _flushLocal();
    if (!_current) return true;
    if (!mounted) return true;
    if (_localError != null) {
      return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                    title: Text(_l('本地保存未完成', 'Local save did not finish')),
                    content: Text(_l('离开可能丢失尚未保存的修改。',
                        'Leaving may lose edits that have not been saved.')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(_l('保留页面', 'Stay'))),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(
                              _l('放弃未保存修改并离开', 'Leave without unsaved edits'))),
                    ],
                  )) ??
          false;
    }
    return true;
  }

  Future<void> _requestLeave() async {
    if (_leaving) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    try {
      if (await _leave() && mounted && _route?.isCurrent == true) {
        navigator.pop();
      }
    } finally {
      _leaving = false;
    }
  }

  Widget _fileSection() {
    final assets = _draft.assets;
    final issues = const UploadAssetPreparer().validateGallery(assets);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_l('图片与上传准备', 'Images and upload preparation'),
          style: Theme.of(context).textTheme.titleLarge),
      Text(_l(
          '本地 ${assets.length} 张 · ${uploadBytes(assets.fold(0, (sum, asset) => sum + asset.size))}',
          '${assets.length} local images · ${uploadBytes(assets.fold(0, (sum, asset) => sum + asset.size))}')),
      if (!_filesEditable)
        Text(_l('文件已进入上传流程，先在任务页核对状态。站内图片修改需使用对应管理操作。',
            'These files are in an upload workflow. Check the task state first; changing remote images requires the corresponding management action.')),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
            key: const ValueKey('upload-import-files'),
            onPressed: _filesEditable ? () => _import(false) : null,
            icon: const Icon(Icons.attach_file),
            label: Text(_l('从文件导入', 'From files'))),
        OutlinedButton.icon(
            key: const ValueKey('upload-import-photos'),
            onPressed: _filesEditable ? () => _import(true) : null,
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(_l('从相册导入', 'From photos'))),
        OutlinedButton.icon(
            key: const ValueKey('upload-review-files'),
            onPressed: assets.isNotEmpty && _root != null ? _reviewFiles : null,
            icon: const Icon(Icons.view_list),
            label: Text(_l('预览、排序与检查', 'Preview, order, and review'))),
      ]),
      if (_busy == 'import' || _busy == 'upload')
        TextButton(
            onPressed: () => _services.cancelPreparation(),
            child: Text(_l('取消文件准备', 'Cancel preparation'))),
      for (final problem in _importProblems)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
                '${problem['displayName'] ?? problem['name'] ?? ''}: ${uploadIssueMessage(problem['reason'] ?? problem['code'] ?? '', _zh)}')),
      for (final issue in issues.take(5))
        Text(
            '${issue.displayName ?? ''} ${uploadIssueMessage(issue.code, _zh)}'),
      if (issues.length > 5)
        Text(_l('还有 ${issues.length - 5} 项提示，请打开文件检查页查看。',
            '${issues.length - 5} more notices. Open the file review to inspect them.')),
      RuleNotices(
          location: UploadRuleLocation.files, onOpenSource: _openSource),
      RuleNotices(
          location: UploadRuleLocation.archive, onOpenSource: _openSource),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_l('仅 Wi-Fi 上传', 'Upload on Wi-Fi only')),
          value: _wifiOnly,
          onChanged: _busy == null && !_transferLocked
              ? (value) => setState(() => _wifiOnly = value)
              : null),
      RuleNotices(
          location: UploadRuleLocation.network, onOpenSource: _openSource),
      RuleNotice(
          rule: UploadRules.byId(UploadRuleId.background),
          onOpenSource: _openSource),
      if (_transferError != null) ...[
        Text(uploadFailureMessage(_transferError!, _zh)),
        TextButton(
            onPressed: _checkTransfer,
            child: Text(_l('重试任务状态', 'Retry task status'))),
      ],
      if (_session.editor.images.isNotEmpty) ...[
        Text(_l('站内已显示 ${_session.editor.images.length} 个图片条目。',
            '${_session.editor.images.length} image entries are shown on the website.')),
        TextButton(
            onPressed: _busy == null ? _reviewRemoteImages : null,
            child: Text(_l('预览与管理站内图片', 'Preview and manage website images'))),
      ],
    ]);
  }

  Widget _pendingPanel() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_pendingError != null) ...[
          Text(uploadFailureMessage(_pendingError!, _zh)),
          TextButton(
              onPressed: _busy == null ? _loadPending : null,
              child: Text(_l('重试确认保存状态', 'Retry saved-operation status'))),
        ],
        if (_pendingWrite != null) ...[
          Text(
              _pendingWrite!.kind == 'create'
                  ? _l('上次创建结果待核对', 'Previous creation needs reconciliation')
                  : _hasAdvancedPending
                      ? _l('上次画廊操作结果待核对',
                          'Previous gallery action needs reconciliation')
                      : _l('上次保存结果待核对', 'Previous save needs reconciliation'),
              style: Theme.of(context).textTheme.titleMedium),
          Text(
              '${_l('提交时的主标题', 'Submitted title')}: ${_pendingWrite!.fields['gname_en']?.firstOrNull ?? ''}'),
          Text(_l('未核对前不会重复提交。相同标题不能证明是同一个画廊，请核对对应结果。',
              'The request will not be repeated before review. A matching title does not prove identity; check the corresponding result.')),
          if (_hasAdvancedPending)
            OutlinedButton(
                key: const ValueKey('upload-pending-advanced-review'),
                onPressed: _busy == null ? _reviewAdvancedPending : null,
                child: Text(
                    _l('读取当前状态并核对结果', 'Read current state and review result')))
          else
            Wrap(spacing: 8, children: [
              OutlinedButton(
                  key: const ValueKey('upload-pending-associate'),
                  onPressed: _busy == null ? _associatePending : null,
                  child: Text(
                      _l('选择站内结果并继续', 'Choose website result and continue'))),
              TextButton(
                  key: const ValueKey('upload-pending-no-change'),
                  onPressed: _busy == null ? _confirmNoChange : null,
                  child: Text(_l(
                      '我已核对，操作未生效', 'I checked: the request had no effect'))),
            ]),
          RuleNotice(
              rule: UploadRules.byId(UploadRuleId.recovery),
              onOpenSource: _openSource),
        ],
      ]);

  @override
  Widget build(BuildContext context) {
    if (_invalidated || !_current) {
      return Scaffold(
          appBar: AppBar(),
          body: Center(
              child: Text(_l('登录状态已改变，正在退出此画廊。',
                  'The session changed. Leaving this gallery.'))));
    }
    final canUpload = _transferReady &&
        _pendingChecked &&
        _pendingWrite == null &&
        !_transferLocked &&
        _assetProgress
            .any((progress) => progress.state != UploadAssetState.confirmed) &&
        !const UploadAssetPreparer()
            .validateGallery(_draft.assets)
            .any((issue) => issue.severity == UploadIssueSeverity.error);
    return PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) _requestLeave();
        },
        child: Scaffold(
          appBar: AppBar(title: Text(_l('编辑画廊', 'Edit gallery')), actions: [
            if (_draft.serverUri != null && !_terminal)
              PopupMenuButton<String>(
                tooltip: _l('画廊管理操作', 'Gallery management'),
                enabled: _busy == null && !_session.localOnly,
                onSelected: (value) {
                  if (value == 'statistics') {
                    _statistics();
                  } else {
                    _advanced(UploadGalleryAction.values
                        .firstWhere((a) => a.name == value));
                  }
                },
                itemBuilder: (_) => [
                  for (final action in UploadGalleryAction.values)
                    PopupMenuItem(
                        value: action.name,
                        enabled: _pendingChecked &&
                            _pendingWrite == null &&
                            _transferReady &&
                            !_transferLocked,
                        child: Text(uploadActionLabel(action, _zh))),
                  PopupMenuItem(
                      value: 'statistics',
                      child: Text(_l('查看统计', 'View statistics'))),
                ],
              ),
            IconButton(
                tooltip: _l('刷新站内状态', 'Refresh website state'),
                onPressed: _busy == null ? _refresh : null,
                icon: const Icon(Icons.refresh)),
            IconButton(
                tooltip: _l('官方管理页', 'Official manager'),
                onPressed: _busy == null ? _openOfficial : null,
                icon: const Icon(Icons.open_in_new))
          ]),
          body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      _terminal
                          ? _l('本地只读副本。', 'Read-only local copy.')
                          : _savingLocal
                              ? _l('正在保存到本机…', 'Saving on this device…')
                              : _draft.serverUri == null
                                  ? _l('仅保存在本机，尚未创建站内画廊。',
                                      'Stored on this device; no website gallery has been created.')
                                  : _draft.dirty
                                      ? _l('本地有未保存到站点的修改。',
                                          'Local changes have not been saved to the website.')
                                      : _l('已保存到站点。', 'Saved to the website.'),
                      key: const ValueKey('upload-save-status')),
                  _pendingPanel(),
                  if (_localError != null) ...[
                    Text(uploadFailureMessage(_localError!, _zh)),
                    TextButton(
                        onPressed: _flushLocal,
                        child: Text(_l('重试本地保存', 'Retry local save'))),
                  ],
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(uploadFailureMessage(_error!, _zh),
                            key: const ValueKey('upload-editor-error'))),
                  if (_busy != null) const LinearProgressIndicator(),
                  if (_terminal)
                    Text(_l(
                        _draft.remoteState == 'deleted'
                            ? '站内画廊已删除，当前为保留的本地只读副本。'
                            : '已放弃站内管理权，当前为保留的本地只读副本；内容仍可能在站点存在。',
                        'Website management has ended. This retained local copy is read-only.')),
                  if (!_terminal &&
                      !_session.localOnly &&
                      !_session.editor.canUpload)
                    Text(_l('当前画廊的图片已锁定。需要增删或调整图片时，请从管理菜单创建更新版本。',
                        'The website has locked image editing. Create an update draft from the management menu to change images.')),
                  const SizedBox(height: 16),
                  UploadEditorForm(
                      key: ValueKey('upload-form-${_draft.id}-$_formEpoch'),
                      snapshot: _session.editor,
                      initialValues: _draft.fields,
                      onChanged: _changed,
                      busy: _busy != null || _terminal,
                      onOpenSource: _openSource,
                      onSave: !_terminal &&
                              !_session.localOnly &&
                              !_transferLocked &&
                              _pendingChecked &&
                              _pendingWrite == null
                          ? _saveRemote
                          : null,
                      onUpload: canUpload ? _upload : null,
                      onPublish: _services.supportsNativePublication &&
                              !_terminal &&
                              !_session.localOnly &&
                              _pendingChecked &&
                              _pendingWrite == null &&
                              !_draft.dirty &&
                              !_transferLocked &&
                              _assetProgress.every(
                                  (p) => p.state == UploadAssetState.confirmed)
                          ? _publish
                          : null,
                      files: _fileSection()),
                  if (_draft.dirty ||
                      _assetProgress
                          .any((p) => p.state != UploadAssetState.confirmed))
                    Text(_l('发布前请先保存站点修改，并完成所有本地图片的上传和结果核对。',
                        'Before publishing, save website changes and finish uploading and verifying every local image.')),
                ],
              )),
        ));
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _authChanges?.cancel();
    super.dispose();
  }
}

class _UploadAssetReview extends StatefulWidget {
  final Directory root;
  final List<PreparedUploadAsset> assets;
  final bool editable;
  final Set<String> confirmedPaths;
  final int firstSequence;
  final Future<List<PreparedUploadAsset>> Function(PreparedUploadAsset)
      onConvert;
  final bool Function() isCurrent;
  final ValueChanged<List<PreparedUploadAsset>> onChanged;
  final FutureOr<void> Function(Uri) onOpenSource;
  const _UploadAssetReview(
      {required this.root,
      required this.assets,
      required this.editable,
      required this.confirmedPaths,
      required this.firstSequence,
      required this.onConvert,
      required this.isCurrent,
      required this.onChanged,
      required this.onOpenSource});
  @override
  State<_UploadAssetReview> createState() => _UploadAssetReviewState();
}

class _UploadAssetReviewState extends State<_UploadAssetReview> {
  late List<PreparedUploadAsset> _assets;
  final _files = <String, Future<File>>{};
  bool _converting = false;
  Object? _conversionError;
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _l(String cn, String en) => _zh ? cn : en;
  @override
  void initState() {
    super.initState();
    _assets = [
      ...widget.assets
          .where((asset) => widget.confirmedPaths.contains(asset.relativePath)),
      ...widget.assets.where(
          (asset) => !widget.confirmedPaths.contains(asset.relativePath)),
    ];
  }

  Future<File> _file(PreparedUploadAsset asset) => _files.putIfAbsent(
      asset.relativePath,
      () => resolveUploadFile(widget.root, asset.relativePath));
  void _change(List<PreparedUploadAsset> assets) {
    if (!widget.editable || !widget.isCurrent() || _converting) return;
    setState(() => _assets = assets);
    widget.onChanged(List.unmodifiable(assets));
  }

  Future<void> _convert(PreparedUploadAsset asset) async {
    if (!widget.editable ||
        !widget.isCurrent() ||
        _converting ||
        asset.format != null) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(_l('尝试转换为 PNG', 'Try converting to PNG')),
              content: Text(_l(
                  '仅转换静态图片，保持像素尺寸并保留原文件。PNG 可能明显变大；不会把视频或动画静默改成单帧。设备不支持此格式时会停止转换。',
                  'Converts still images only, preserving pixel dimensions and the original file. PNG may be much larger. Videos and animations will not silently become a single frame. Conversion stops if this device does not support the format.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(_l('取消', 'Cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(_l('确认尝试转换', 'Try conversion')))
              ],
            ));
    if (confirmed != true || !mounted || !widget.isCurrent()) return;
    setState(() {
      _converting = true;
      _conversionError = null;
    });
    try {
      final assets = await widget.onConvert(asset);
      if (mounted && widget.isCurrent()) {
        setState(() => _assets = [
              ...assets.where((asset) =>
                  widget.confirmedPaths.contains(asset.relativePath)),
              ...assets.where((asset) =>
                  !widget.confirmedPaths.contains(asset.relativePath)),
            ]);
      }
    } catch (error) {
      if (mounted && widget.isCurrent()) {
        setState(() => _conversionError = error);
      }
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _preview(PreparedUploadAsset asset) async {
    if (!widget.isCurrent()) return;
    await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(asset.displayName)),
                Flexible(
                    child: FutureBuilder<File>(
                        future: _file(asset),
                        builder: (_, snapshot) => snapshot.hasData &&
                                asset.isValid
                            ? InteractiveViewer(
                                child: Image.file(snapshot.data!,
                                    cacheWidth: 1600,
                                    errorBuilder: (_, __, ___) => Text(_l(
                                        '无法预览此图片。',
                                        'Cannot preview this image.'))))
                            : Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(_l('此文件暂不可预览，请查看检查结果。',
                                    'This file cannot be previewed. Review its validation results.'))))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(_l('关闭', 'Close'))),
              ]),
            ));
  }

  List<PreparedUploadAsset> _names() {
    try {
      final pending = const UploadAssetPreparer().freezeNames(
          _assets
              .where((asset) =>
                  !widget.confirmedPaths.contains(asset.relativePath))
              .toList(),
          firstSequence: widget.firstSequence);
      final names = {for (final asset in pending) asset.relativePath: asset};
      return _assets
          .map((asset) => names[asset.relativePath] ?? asset)
          .toList();
    } catch (_) {
      return _assets;
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = _names();
    return Scaffold(
        appBar: AppBar(
            title: Text(_l('图片预览与排序', 'Preview and order images')),
            actions: [
              PopupMenuButton<String>(
                  enabled: widget.editable && !_converting,
                  onSelected: (value) {
                    if (value == 'natural' || value == 'lexical') {
                      _change([
                        ..._assets.where((asset) =>
                            widget.confirmedPaths.contains(asset.relativePath)),
                        ...const UploadAssetPreparer().sorted(
                            _assets
                                .where((asset) => !widget.confirmedPaths
                                    .contains(asset.relativePath))
                                .toList(),
                            natural: value == 'natural'),
                      ]);
                    }
                  },
                  itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'natural',
                            child: Text(_l('自然排序', 'Natural sort'))),
                        PopupMenuItem(
                            value: 'lexical',
                            child: Text(_l('字典排序', 'Lexical sort'))),
                      ])
            ]),
        body: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          header: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_converting) const LinearProgressIndicator(),
                    if (_conversionError != null)
                      Text(uploadFailureMessage(_conversionError!, _zh)),
                    if (widget.confirmedPaths.isNotEmpty)
                      Text(_l('已确认接收的图片不会再次上传；其站内顺序与删除请在站内图片管理页处理。',
                          'Confirmed images will not be uploaded again. Manage their website order or removal on the website-image page.')),
                    RuleNotice(
                        rule: UploadRules.byId(UploadRuleId.ordering),
                        onOpenSource: widget.onOpenSource),
                  ])),
          itemCount: _assets.length,
          onReorder: (oldIndex, newIndex) {
            final fixed = _assets
                .where((asset) =>
                    widget.confirmedPaths.contains(asset.relativePath))
                .length;
            if (oldIndex < fixed || _converting) return;
            if (newIndex > oldIndex) newIndex--;
            if (newIndex < fixed) newIndex = fixed;
            final copy = List<PreparedUploadAsset>.of(_assets);
            final item = copy.removeAt(oldIndex);
            copy.insert(newIndex, item);
            _change(copy);
          },
          itemBuilder: (ctx, index) {
            final asset = _assets[index];
            final confirmed =
                widget.confirmedPaths.contains(asset.relativePath);
            return Card(
                key: ObjectKey(asset),
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                          onTap: () => _preview(asset),
                          leading: SizedBox(
                              width: 48,
                              height: 64,
                              child: FutureBuilder<File>(
                                  future: _file(asset),
                                  builder: (_, snapshot) => snapshot.hasData &&
                                          asset.isValid
                                      ? Image.file(snapshot.data!,
                                          cacheWidth: 144,
                                          cacheHeight: 192,
                                          fit: BoxFit.contain,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(
                                                  Icons.broken_image_outlined))
                                      : const Icon(Icons.image_outlined))),
                          title: Text('${index + 1}. ${asset.displayName}'),
                          subtitle: Text(
                              '${confirmed ? _l('已确认接收', 'Receipt confirmed') : _l('待上传', 'Not yet uploaded')} · ${names[index].uploadName ?? _l('待处理', 'Needs attention')}\n${uploadBytes(asset.size)} · ${asset.width ?? '?'}×${asset.height ?? '?'}'),
                          trailing:
                              widget.editable && !confirmed && !_converting
                                  ? ReorderableDragStartListener(
                                      index: index,
                                      child: const Icon(Icons.drag_handle))
                                  : null),
                      for (final issue in asset.issues)
                        Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: Text(uploadIssueMessage(issue.code, _zh))),
                      if (widget.editable && !confirmed && asset.format == null)
                        TextButton(
                            onPressed:
                                _converting ? null : () => _convert(asset),
                            child:
                                Text(_l('尝试转换为 PNG', 'Try converting to PNG'))),
                      if (widget.editable && !confirmed)
                        Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: TextButton.icon(
                                onPressed: _converting
                                    ? null
                                    : () {
                                        final copy =
                                            List<PreparedUploadAsset>.of(
                                                _assets)
                                              ..removeAt(index);
                                        _change(copy);
                                      },
                                icon: const Icon(Icons.remove_circle_outline),
                                label: Text(_l('从本地上传清单移除',
                                    'Remove from local upload list')))),
                    ]));
          },
        ));
  }
}
