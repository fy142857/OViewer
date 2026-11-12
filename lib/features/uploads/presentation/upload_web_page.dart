import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get_it/get_it.dart';

import '../../../blocs/auth/auth_bloc.dart';
import '../../../blocs/auth/auth_state.dart';
import '../../../core/network/cookie_manager.dart' as app;
import '../../../core/network/network_preparation.dart';
import '../../../core/network/network_proxy_io.dart';
import '../../../core/services/floating_back_keyboard.dart';
import '../../../core/storage/reader_index_cache.dart';
import '../platform/upload_platform.dart';
import '../rules/rule_notice.dart';
import '../rules/upload_rules.dart';

class UploadWebPolicy {
  static const hosts = {
    'upld.e-hentai.org',
    'e-hentai.org',
    'exhentai.org',
    'forums.e-hentai.org',
  };

  static bool official(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      hosts.contains(uri.host);

  /// Only these GET entries can be loaded by the app itself. Website actions
  /// remain user-controlled inside the browser and are never replayed on retry.
  static bool safeEntry(Uri uri) {
    if (!official(uri) || uri.host != 'upld.e-hentai.org') return false;
    if (uri.queryParametersAll.values.any((values) => values.length != 1)) {
      return false;
    }
    final actions = uri.queryParametersAll['act'];
    if (actions != null && actions.length != 1) return false;
    final action = actions?.single;
    if (uri.path == '/manage') {
      return uri.queryParametersAll.keys.every({'ss', 'sd'}.contains);
    }
    if (uri.path == '/managefolders') return uri.queryParametersAll.isEmpty;
    if (uri.path != '/managegallery') return false;
    if (!uri.queryParametersAll.keys.every({'ulgid', 'act'}.contains)) {
      return false;
    }
    final ids = uri.queryParametersAll['ulgid'];
    if (action == 'new') return ids == null;
    return (action == null || action.isEmpty) &&
        ids?.length == 1 &&
        RegExp(r'^[1-9]\d*$').hasMatch(ids!.single);
  }

  static bool login(Uri? uri) =>
      official(uri) &&
      ((uri!.host == 'forums.e-hentai.org' &&
              uri.path == '/index.php' &&
              uri.queryParameters['act']?.toLowerCase() == 'login') ||
          uri.path == '/login.php');
}

/// Uses the existing system WebView route only after a confirmed native lease.
/// The vendored iOS plugin has no app-proxy override; choosing system networking
/// on iOS is explicit when an app proxy is configured.
class UploadWebProxy {
  static const channel = MethodChannel('oviewer/upload_web_proxy');
  Future<bool> begin(String id, String? proxy) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return proxy == null;
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel
              .invokeMethod<bool>('begin', {'id': id, 'proxy': proxy}) ==
          true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> check(String id) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return true;
    try {
      return await channel.invokeMethod<bool>('check', {'id': id}) == true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> close(String id) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return;
    await channel.invokeMethod<void>('close', {'id': id});
  }
}

class UploadWebPage extends StatefulWidget {
  final Uri url;
  final Future<void> Function() beforeOpen;
  final Future<void> Function() afterClose;
  final app.CookieManager? cookies;
  final AuthBloc? auth;
  final NetworkPreparation? network;
  final UploadWebProxy? proxy;

  const UploadWebPage({
    super.key,
    required this.url,
    required this.beforeOpen,
    required this.afterClose,
    this.cookies,
    this.auth,
    this.network,
    this.proxy,
  });

  @override
  State<UploadWebPage> createState() => _UploadWebPageState();
}

class _UploadWebFrame {
  final String id;
  final int? windowId;
  final Uri? entry;
  final String observerNonce;
  InAppWebViewController? controller;
  Uri? url;
  int progress = 0;
  bool failed = false;
  bool submitting = false;
  bool dirty = false;
  bool discardOnNextNavigation = false;
  _UploadWebFrame(this.id, this.windowId, this.entry, this.observerNonce)
      : url = entry;
}

class _UploadWebPageState extends State<UploadWebPage>
    with WidgetsBindingObserver {
  late app.CookieManager _cookies;
  late AuthBloc _auth;
  late UploadWebProxy _proxy;
  NetworkPreparation? _network;
  StreamSubscription<AuthState>? _authSubscription;
  final List<_UploadWebFrame> _frames = [];
  int? _revision;
  int _authGeneration = 0;
  int _generation = 0;
  int _backRequest = 0;
  int? _networkRevision;
  bool _initialized = false;
  bool _disposed = false;
  bool _preparing = false;
  bool _closing = false;
  bool _expired = false;
  bool _handoff = false;
  bool get _dirty => _frames.any((frame) => frame.dirty || frame.submitting);
  bool _forceExit = false;
  bool _systemNetwork = false;
  bool _offerSystem = false;
  bool _visitedReaderSettings = false;
  String? _leaseId;
  String? _failure;
  String? _configuredProxy;
  Map<String, String> _identity = const {};
  final Set<String> _verifiedOrigins = {};
  late Uri _safeUrl;
  Future<void>? _teardown;
  Future<void>? _handoffFinish;
  Future<void>? _handoffReady;
  Future<void>? _uploadSessionReset;
  DialogRoute<Object?>? _dialogRoute;
  Completer<Object?>? _dialogDecision;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _l(String zh, String en) => _zh ? zh : en;
  bool get _current =>
      mounted &&
      !_disposed &&
      !_expired &&
      _revision == _cookies.sessionRevision &&
      _auth.state.isLoggedIn &&
      _auth.state.sessionGeneration == _authGeneration;
  bool _owns(int generation) =>
      _current && generation == _generation && !_closing;
  String _nonce() =>
      base64UrlEncode(List.generate(18, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _cookies = widget.cookies ?? GetIt.I<app.CookieManager>();
    _auth = widget.auth ?? context.read<AuthBloc>();
    _proxy = widget.proxy ?? UploadWebProxy();
    _network = widget.network ??
        (GetIt.I.isRegistered<NetworkPreparation>()
            ? GetIt.I<NetworkPreparation>()
            : null);
    _revision = _cookies.sessionRevision;
    _authGeneration = _auth.state.sessionGeneration;
    _safeUrl = widget.url;
    _authSubscription = _auth.stream.listen((state) {
      if (!state.isLoggedIn ||
          state.sessionGeneration != _authGeneration ||
          _revision != _cookies.sessionRevision) {
        _invalidate(session: true);
      }
    });
    _network?.addListener(_networkChanged);
    WidgetsBinding.instance.addObserver(this);
    if (!_auth.state.isLoggedIn) {
      _expired = true;
      _failure = 'session';
      return;
    }
    unawaited(_prepare());
  }

  void _networkChanged() {
    if ((_leaseId != null || _frames.isNotEmpty) &&
        ((_network != null && _network?.revision != _networkRevision) ||
            NetworkProxy.currentProxy != _configuredProxy)) {
      _invalidate(session: false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_initialized || _closing) return;
    if (!_current) {
      _invalidate(session: true);
      return;
    }
    _networkChanged();
    final id = _leaseId;
    final generation = _generation;
    if (id != null && _frames.isNotEmpty) {
      unawaited(_proxy.check(id).then((ready) {
        if (_owns(generation) && !ready) _invalidate(session: false);
      }).catchError((Object _) {
        if (_owns(generation)) _invalidate(session: false);
      }));
    }
  }

  Future<void> _prepare() async {
    if (_preparing || _closing || _expired) return;
    if (!UploadWebPolicy.safeEntry(widget.url)) {
      setState(() => _failure = 'entry');
      return;
    }
    final generation = ++_generation;
    setState(() {
      _preparing = true;
      _failure = null;
      _offerSystem = false;
    });
    try {
      await _destroyViews();
      await NetworkProxy.waitUntilReady();
      if (!_owns(generation)) return;
      _configuredProxy = NetworkProxy.currentProxy;
      _networkRevision = _network?.revision;
      final route = _systemNetwork ? null : _configuredProxy;
      final id = _nonce();
      _leaseId = id;
      final available =
          await _proxy.begin(id, route).timeout(const Duration(seconds: 15));
      if (!_owns(generation)) {
        await _closeLease(id);
        return;
      }
      if (!available) {
        await _closeLease(id);
        setState(() {
          _failure = 'network';
          _offerSystem = !_systemNetwork && _configuredProxy != null;
        });
        return;
      }
      if (!_handoff) {
        final ready = _handoffReady ??= Future<void>.sync(widget.beforeOpen);
        try {
          await ready;
          _handoff = true;
        } catch (_) {
          if (identical(_handoffReady, ready)) _handoffReady = null;
          rethrow;
        }
      }
      if (!_owns(generation)) return;
      final header = await _cookies.getUploadCookieHeader();
      _identity = _loginPair(header);
      final member = _auth.state.profile.memberId;
      if (_identity.length != 2 ||
          (member != null && member != _identity['ipb_member_id'])) {
        _invalidate(session: true);
        return;
      }
      final reset = _uploadSessionReset ??= _resetUploadBrowserSession();
      try {
        await reset;
      } catch (_) {
        if (identical(_uploadSessionReset, reset)) _uploadSessionReset = null;
        rethrow;
      }
      if (!_owns(generation)) return;
      await _cookies.syncToWebView(_safeUrl);
      if (!_owns(generation)) return;
      // Synchronization can leave a differently scoped host-only cookie behind.
      // Verify a unique account pair before the browser's very first request.
      await _checkBrowserIdentity(_safeUrl);
      if (!_owns(generation)) return;
      _verifiedOrigins
        ..clear()
        ..add(_safeUrl.origin);
      if (_network?.revision != _networkRevision ||
          NetworkProxy.currentProxy != _configuredProxy) {
        _invalidate(session: false);
        return;
      }
      setState(() =>
          _frames.add(_UploadWebFrame(_nonce(), null, _safeUrl, _nonce())));
    } catch (_) {
      if (_owns(generation)) setState(() => _failure = 'prepare');
      final id = _leaseId;
      if (id != null) {
        try {
          await _closeLease(id);
        } catch (_) {
          if (mounted) setState(() => _failure = 'cleanup');
        }
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  static Map<String, String> _loginPair(String header) {
    final result = <String, String>{};
    for (final cookie in header.split(';')) {
      final split = cookie.indexOf('=');
      if (split < 1) continue;
      final name = cookie.substring(0, split).trim();
      if (name == 'ipb_member_id' || name == 'ipb_pass_hash') {
        result[name] = cookie.substring(split + 1).trim();
      }
    }
    result.removeWhere((_, value) => value.isEmpty);
    return result;
  }

  Future<void> _checkBrowserIdentity(Uri target) async {
    final generation = _generation;
    final cookies = await _browserCookiesFor(target);
    if (!_owns(generation)) return;
    for (final pair in _identity.entries) {
      final values = cookies
          .where((cookie) => cookie.name == pair.key)
          .map((cookie) => cookie.value)
          .toSet();
      if (values.length != 1 || values.single != pair.value) {
        _invalidate(session: true);
        return;
      }
    }
  }

  Future<List<Cookie>> _browserCookiesFor(Uri target) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return CookieManager.instance().getCookies(url: target);
    }
    // The vendored iOS getCookies method ignores cookie paths. Match the
    // native store explicitly, including the host-only/domain distinction.
    return (await IOSCookieManager.instance().getAllCookies()).where((cookie) {
      if (cookie.expiresDate != null &&
          cookie.expiresDate! <= DateTime.now().millisecondsSinceEpoch) {
        return false;
      }
      final domain = cookie.domain?.toLowerCase();
      if (domain == null) return false;
      final host = domain.replaceFirst(RegExp(r'^\.'), '');
      if (target.host != host &&
          !(domain.startsWith('.') && target.host.endsWith('.$host'))) {
        return false;
      }
      final path = cookie.path ?? '/';
      return target.path == path ||
          (target.path.startsWith(path) &&
              (path.endsWith('/') ||
                  target.path.substring(path.length).startsWith('/')));
    }).toList();
  }

  Future<void> _resetUploadBrowserSession() async {
    final manager = CookieManager.instance();
    final origin = Uri.https('upld.e-hentai.org', '/');
    // PHPSESSID is a separate host-scoped upload session. It must not survive
    // an account handoff, and must not be reset on subsequent page navigation.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (final cookie in await IOSCookieManager.instance().getAllCookies()) {
        if (cookie.name == 'PHPSESSID' &&
            {'upld.e-hentai.org', '.upld.e-hentai.org'}
                .contains(cookie.domain?.toLowerCase())) {
          await manager.deleteCookie(
              url: origin,
              name: 'PHPSESSID',
              domain: cookie.domain,
              path: cookie.path ?? '/');
        }
      }
    } else {
      for (final domain in <String?>[
        null,
        'upld.e-hentai.org',
        '.upld.e-hentai.org'
      ]) {
        await manager.deleteCookie(
            url: origin, name: 'PHPSESSID', domain: domain, path: '/');
      }
    }
    for (final path in [
      '/manage',
      '/managegallery',
      '/managefolders',
      '/api'
    ]) {
      final remaining =
          await _browserCookiesFor(Uri.https('upld.e-hentai.org', path));
      if (remaining.any((cookie) => cookie.name == 'PHPSESSID')) {
        throw StateError('Upload browser session cleanup incomplete');
      }
    }
  }

  Future<bool> _prepareDestination(Uri target) async {
    final generation = _generation;
    try {
      await _cookies.syncToWebView(target);
      if (!_owns(generation)) return false;
      await _checkBrowserIdentity(target);
      if (_owns(generation)) _verifiedOrigins.add(target.origin);
      return _owns(generation);
    } catch (_) {
      if (mounted && !_disposed && generation == _generation) {
        _invalidate(session: true);
      }
      return false;
    }
  }

  void _invalidate({required bool session}) {
    if (!mounted || _disposed || _closing || _expired) return;
    ++_generation;
    _cancelDialog();
    setState(() {
      if (session) _expired = true;
      _failure = session ? 'session' : 'changed';
      _systemNetwork = false;
      _offerSystem = false;
    });
    unawaited(_destroyViews().then((_) async {
      if (session) {
        try {
          await _finishHandoff();
        } catch (_) {}
      }
    }).catchError((Object _) {
      if (mounted && !_disposed) setState(() => _failure = 'cleanup');
    }));
  }

  Future<void> _closeLease(String id) async {
    await _proxy.close(id).timeout(const Duration(seconds: 15));
    if (_leaseId == id) _leaseId = null;
  }

  Future<void> _destroyViews() {
    final existing = _teardown;
    if (existing != null) return existing;
    final frames = List<_UploadWebFrame>.of(_frames);
    final id = _leaseId;
    final reset = _uploadSessionReset;
    final task = () async {
      // A late native deletion must finish before another browser can acquire
      // the route and establish its own PHP session.
      try {
        await reset;
      } catch (_) {}
      for (final frame in frames.reversed) {
        final controller = frame.controller;
        if (controller == null) continue;
        try {
          await controller.stopLoading().timeout(const Duration(seconds: 2));
          await controller
              .loadUrl(urlRequest: URLRequest(url: Uri.parse('about:blank')))
              .timeout(const Duration(seconds: 2));
        } catch (_) {/* The platform view may already have been disposed. */}
      }
      if (mounted && !_disposed) {
        setState(_frames.clear);
      } else {
        _frames.clear();
      }
      if (frames.isNotEmpty) {
        try {
          await WidgetsBinding.instance.endOfFrame
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      if (id != null) await _closeLease(id);
    }();
    _teardown = task;
    return task.whenComplete(() {
      if (identical(_teardown, task)) _teardown = null;
    });
  }

  Future<void> _finishHandoff() => _handoffFinish ??= () async {
        try {
          await _handoffReady;
        } catch (_) {}
        // This browser normally has no reader-cache effects. A real visit to
        // the site's reader settings has the same exit semantics as the
        // existing dedicated SiteSettingsWebView.
        if (_visitedReaderSettings) ReaderIndexCache.shared.clear();
        if (_handoff) await widget.afterClose();
      }();

  Future<T?> _dialog<T>(WidgetBuilder builder) async {
    if (!mounted || _dialogRoute != null) return null;
    final decision = Completer<Object?>();
    final route = DialogRoute<Object?>(context: context, builder: builder);
    _dialogRoute = route;
    _dialogDecision = decision;
    unawaited(Navigator.of(context).push(route).then((value) {
      if (!decision.isCompleted) decision.complete(value);
      if (identical(_dialogRoute, route)) {
        _dialogRoute = null;
        _dialogDecision = null;
      }
    }));
    return (await decision.future) as T?;
  }

  void _cancelDialog() {
    final route = _dialogRoute;
    final decision = _dialogDecision;
    _dialogRoute = null;
    _dialogDecision = null;
    if (decision != null && !decision.isCompleted) decision.complete(null);
    if (route?.isActive == true) {
      final navigator = route!.navigator;
      if (_disposed) {
        scheduleMicrotask(() {
          if (navigator?.mounted == true && route.isActive) {
            navigator!.removeRoute(route);
          }
        });
      } else {
        navigator?.removeRoute(route);
      }
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await _dialog<bool>((ctx) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(child: Text(message)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(_l('取消', 'Cancel'))),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(_l('确认', 'Confirm'))),
            ],
          )) ==
      true;

  Future<bool> _back() async {
    if (_closing) return false;
    final request = ++_backRequest;
    final generation = _generation;
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      await FloatingBackKeyboard.hide();
      return false;
    }
    if (!_forceExit && _frames.isNotEmpty && _current) {
      final frame = _frames.last;
      bool hasHistory;
      try {
        hasHistory = await frame.controller?.canGoBack() == true;
      } catch (_) {
        return false;
      }
      if (!_owns(generation) ||
          request != _backRequest ||
          _frames.isEmpty ||
          !identical(_frames.last, frame)) return false;
      if (hasHistory) {
        if (frame.dirty &&
            !await _confirm(
                _l('返回上一网页？', 'Return to the previous page?'),
                _l('当前网页的未保存输入或文件上传可能中断。请先核对再返回。',
                    'Unsaved input or a website upload may be interrupted. Check the result before going back.'))) {
          return false;
        }
        if (!_owns(generation) ||
            request != _backRequest ||
            !_frames.contains(frame)) return false;
        frame.discardOnNextNavigation = true;
        await frame.controller?.goBack();
        return false;
      }
      if (_frames.length > 1) {
        if (frame.dirty &&
            !await _confirm(
                _l('关闭当前网页窗口？', 'Close this website window?'),
                _l('当前窗口的未保存输入或文件上传可能中断。请先核对完成情况。',
                    'Unsaved input or a website upload in this window may be interrupted. Check completion first.'))) {
          return false;
        }
        if (!_owns(generation) ||
            request != _backRequest ||
            !_frames.contains(frame)) return false;
        await _closePopup(frame);
        return false;
      }
    }
    _forceExit = false;
    if (_dirty &&
        _frames.isNotEmpty &&
        _current &&
        !await _confirm(
            _l('离开官方网页？', 'Leave the official page?'),
            _l('请先确认网页修改已保存、上传已完成并核对结果。网页上传不会转入应用后台队列，离开可能中断尚未完成的操作。',
                'Check that website changes are saved and uploads have finished. Website uploads do not enter the app’s background queue; leaving may interrupt unfinished work.'))) {
      return false;
    }
    if (!mounted || request != _backRequest || generation != _generation) {
      return false;
    }
    _closing = true;
    ++_generation;
    _cancelDialog();
    try {
      await _destroyViews();
    } catch (_) {
      if (mounted) {
        setState(() {
          _closing = false;
          _failure = 'cleanup';
        });
      }
      return false;
    }
    try {
      await _finishHandoff();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_l('返回后请重新刷新并核对站内状态。',
                'Refresh and reconcile website state after returning.'))));
      }
    }
    return mounted;
  }

  Future<void> _requestPop() async {
    if (!mounted || _disposed) return;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    try {
      if (!await _back() || !mounted || _disposed) return;
      if (route?.isCurrent == true) {
        navigator.pop();
      } else if (route?.isActive == true) {
        // Never pop a newer route while an asynchronous close is finishing.
        setState(() {
          _closing = false;
          _expired = true;
          _failure = 'closed';
        });
      }
    } catch (_) {
      if (mounted && !_disposed) {
        _message('无法返回此网页，请使用关闭按钮重新核对。',
            'Could not return through this page. Close it and check the manager again.');
      }
    }
  }

  Future<void> _closePopup(_UploadWebFrame frame) async {
    if (!_frames.contains(frame) || _frames.length < 2) return;
    try {
      await frame.controller?.stopLoading();
    } catch (_) {}
    if (mounted) setState(() => _frames.remove(frame));
  }

  Future<void> _retry() async {
    if (_preparing || _closing || _expired) return;
    if (_dirty &&
        _frames.isNotEmpty &&
        !await _confirm(
            _l('重新打开管理页？', 'Reopen the manager?'),
            _l('这会丢弃网页中未保存的输入。只重新读取管理页，不会重发上次的上传、发布或删除请求。',
                'Unsaved website input will be discarded. This reads the manager again without replaying the previous upload, publication, or deletion.'))) {
      return;
    }
    await _prepare();
  }

  void _message(String zh, String en) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_l(zh, en))));
  }

  Future<NavigationActionPolicy> _navigation(
      _UploadWebFrame frame, NavigationAction action) async {
    final url = action.request.url;
    if (url?.toString() == 'about:blank' &&
        (_closing || _failure != null || frame.url == null)) {
      return NavigationActionPolicy.ALLOW;
    }
    if (!_current) {
      _invalidate(session: true);
      return NavigationActionPolicy.CANCEL;
    }
    if (_closing || _failure == 'changed') {
      return NavigationActionPolicy.CANCEL;
    }
    if (!action.isForMainFrame && !UploadWebPolicy.official(url)) {
      return (url?.scheme == 'https' && url!.userInfo.isEmpty) ||
              {'about:blank', 'about:srcdoc'}.contains(url?.toString())
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    }
    if (!UploadWebPolicy.official(url)) {
      frame.discardOnNextNavigation = false;
      _message('应用内仅打开 E 站官方页面。此链接已阻止。',
          'Only official E-Hentai pages open here. This link was blocked.');
      return NavigationActionPolicy.CANCEL;
    }
    if (UploadWebPolicy.login(url)) {
      _invalidate(session: true);
      return NavigationActionPolicy.CANCEL;
    }
    if (action.iosWKNavigationType == IOSWKNavigationType.BACK_FORWARD &&
        !{'GET', 'HEAD'}
            .contains((action.request.method ?? 'GET').toUpperCase())) {
      frame.discardOnNextNavigation = false;
      _message('未重发历史表单，请重新打开管理页核对。',
          'The previous form was not resubmitted. Reopen the manager to check it.');
      return NavigationActionPolicy.CANCEL;
    }
    return await _prepareDestination(url!)
        ? NavigationActionPolicy.ALLOW
        : NavigationActionPolicy.CANCEL;
  }

  String _observer(_UploadWebFrame frame) => '''(() => {
    if (window.top !== window || location.protocol !== 'https:' ||
        !${jsonEncode(UploadWebPolicy.hosts.toList())}.includes(location.hostname)) return;
    const report = kind => {
      if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler(
        'oviewerUploadState', {nonce:${jsonEncode(frame.observerNonce)},kind,href:location.href});
    };
    document.addEventListener('input', e => { if (e.isTrusted) report('dirty'); }, true);
    document.addEventListener('change', e => { if (e.isTrusted) report('dirty'); }, true);
    document.addEventListener('submit', () => report('submit'), true);
    document.addEventListener('click', e => {
      if (!e.isTrusted || !e.target.closest) return;
      const target = e.target.closest('button,input[type="submit"],[onclick],a[href]');
      if (!target) return;
      const action = (target.getAttribute('onclick') || '') + ' ' + (target.getAttribute('href') || '');
      if (target.matches('button,input[type="submit"]') || /submit_|delete_|reorder|act=(publish|delete|disown|clone|unlock)/i.test(action)) report('submit');
    }, true);
  })();''';

  Widget _webView(_UploadWebFrame frame) => InAppWebView(
        key: ValueKey(frame.id),
        windowId: frame.windowId,
        initialUrlRequest:
            frame.entry == null ? null : URLRequest(url: frame.entry),
        initialUserScripts: UnmodifiableListView([
          UserScript(
              source: _observer(frame),
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START)
        ]),
        initialOptions: InAppWebViewGroupOptions(
          crossPlatform: InAppWebViewOptions(
              javaScriptEnabled: true,
              useShouldOverrideUrlLoading: true,
              javaScriptCanOpenWindowsAutomatically: false,
              mediaPlaybackRequiresUserGesture: true,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false),
          android: AndroidInAppWebViewOptions(
              supportMultipleWindows: true,
              useShouldInterceptRequest: true,
              mixedContentMode:
                  AndroidMixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
              allowFileAccess: false),
          ios: IOSInAppWebViewOptions(
              allowsBackForwardNavigationGestures: false,
              allowsLinkPreview: false,
              sharedCookiesEnabled: false),
        ),
        onWebViewCreated: (controller) {
          frame.controller = controller;
          controller.addJavaScriptHandler(
              handlerName: 'oviewerUploadState',
              callback: (args) {
                if (!_current ||
                    _closing ||
                    !_frames.contains(frame) ||
                    args.length != 1 ||
                    args.first is! Map) return null;
                final message = args.first as Map;
                final url = Uri.tryParse(
                    message['href'] is String ? message['href'] as String : '');
                if (message['nonce'] != frame.observerNonce ||
                    !UploadWebPolicy.official(url)) return null;
                if (message['kind'] == 'dirty' || message['kind'] == 'submit') {
                  setState(() {
                    frame.dirty = true;
                    if (message['kind'] == 'submit') frame.submitting = true;
                  });
                }
                return null;
              });
        },
        shouldOverrideUrlLoading: (_, action) => _navigation(frame, action),
        androidShouldInterceptRequest: (_, request) async {
          if (request.url.toString() == 'about:blank') return null;
          final official = UploadWebPolicy.official(request.url);
          final unprepared =
              official && !_verifiedOrigins.contains(request.url.origin);
          final write = !{'GET', 'HEAD'}
              .contains((request.method ?? 'GET').toUpperCase());
          if (!_current) _invalidate(session: true);
          if (!_current ||
              _closing ||
              _failure != null ||
              request.isForMainFrame == true &&
                  (unprepared ||
                      UploadWebPolicy.login(request.url) ||
                      !official) ||
              (write && unprepared)) {
            return WebResourceResponse(
                contentType: 'text/plain',
                data: Uint8List(0),
                statusCode: 403,
                reasonPhrase: 'Blocked',
                headers: {});
          }
          return null;
        },
        onCreateWindow: (_, action) async {
          if (!_current || _closing) return false;
          if (_frames.length >= 4) {
            _message('请先关闭一个官方网页窗口。',
                'Close an existing official website window first.');
            return false;
          }
          final url = action.request.url;
          if (url != null &&
              url.toString() != 'about:blank' &&
              !UploadWebPolicy.official(url)) {
            _message('已阻止非官方地址的新窗口。',
                'A new window to a non-official address was blocked.');
            return false;
          }
          if (UploadWebPolicy.login(url)) {
            _invalidate(session: true);
            return false;
          }
          if (url != null &&
              url.toString() != 'about:blank' &&
              !await _prepareDestination(url)) return false;
          if (!_current || _closing) return false;
          setState(() => _frames
              .add(_UploadWebFrame(_nonce(), action.windowId, null, _nonce())));
          return true;
        },
        onCloseWindow: (_) => unawaited(_closePopup(frame)),
        onLoadStart: (_, url) {
          if (!_current ||
              _closing ||
              !_frames.contains(frame) ||
              url?.toString() == 'about:blank') return;
          if (!UploadWebPolicy.official(url)) {
            _invalidate(session: false);
            return;
          }
          setState(() {
            if (frame.discardOnNextNavigation) {
              frame.dirty = false;
              frame.discardOnNextNavigation = false;
            }
            frame.url = url;
            frame.failed = false;
            frame.progress = 0;
          });
        },
        onLoadStop: (controller, url) async {
          if (!_current ||
              _closing ||
              !_frames.contains(frame) ||
              url?.toString() == 'about:blank') return;
          if (!UploadWebPolicy.official(url) || UploadWebPolicy.login(url)) {
            _invalidate(session: true);
            return;
          }
          setState(() {
            frame.url = url;
            frame.progress = 100;
            frame.submitting = false;
            if (url != null && UploadWebPolicy.safeEntry(url)) _safeUrl = url;
            if ({'e-hentai.org', 'exhentai.org'}.contains(url?.host) &&
                url?.path == '/uconfig.php') {
              _visitedReaderSettings = true;
            }
          });
          final generation = _generation;
          try {
            await _checkBrowserIdentity(url!);
            if (!_owns(generation) ||
                !_frames.contains(frame) ||
                url.host != 'upld.e-hentai.org') return;
            // Read only the site's public account identifier. Never inspect
            // scripts, keys, password fields, or selected files.
            final uid = await controller.evaluateJavascript(source: '''
(() => {
  const value = window.apiuid;
  if (typeof value === 'undefined') return null;
  if (typeof value === 'number' && Number.isSafeInteger(value)) return String(value);
  return typeof value === 'string' ? value : '';
})()
''');
            if (_owns(generation) &&
                _frames.contains(frame) &&
                uid != null &&
                uid != _identity['ipb_member_id']) {
              _invalidate(session: true);
            }
          } catch (_) {
            if (_owns(generation) && _frames.contains(frame)) {
              _invalidate(session: true);
            }
          }
        },
        onProgressChanged: (_, progress) {
          if (_current && _frames.contains(frame)) {
            setState(() => frame.progress = progress);
          }
        },
        onLoadError: (_, url, code, __) {
          if (mounted &&
              _frames.contains(frame) &&
              code != -999 &&
              url?.toString() != 'about:blank' &&
              (url == null ||
                  frame.url == null ||
                  url.removeFragment() == frame.url?.removeFragment())) {
            setState(() => frame.failed = true);
          }
        },
        onLoadHttpError: (_, url, __, ___) {
          if (mounted &&
              _frames.contains(frame) &&
              url?.removeFragment() == frame.url?.removeFragment()) {
            setState(() => frame.failed = true);
          }
        },
        onUpdateVisitedHistory: (_, url, __) {
          if (_current &&
              !_closing &&
              _frames.contains(frame) &&
              UploadWebPolicy.official(url)) {
            setState(() => frame.url = url);
          }
        },
        onTitleChanged: (_, title) {
          if (title?.contains('E-Hentai.org Login') == true) {
            _invalidate(session: true);
          }
        },
        onJsConfirm: (_, request) async {
          final generation = _generation;
          final allowed = _current &&
              UploadWebPolicy.official(request.url) &&
              await _confirm(_l('官方网页确认', 'Official website confirmation'),
                  request.message ?? '');
          if (!allowed && _frames.contains(frame)) frame.submitting = false;
          return JsConfirmResponse(
              handledByClient: true,
              action: allowed && _owns(generation)
                  ? JsConfirmResponseAction.CONFIRM
                  : JsConfirmResponseAction.CANCEL);
        },
        onJsAlert: (_, request) async {
          if (_current && UploadWebPolicy.official(request.url)) {
            await _dialog<void>((ctx) => AlertDialog(
                    title: Text(_l('官方网页提示', 'Official website message')),
                    content: SingleChildScrollView(
                        child: Text(request.message ?? '')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(_l('确定', 'OK')))
                    ]));
          }
          return JsAlertResponse(handledByClient: true);
        },
        onJsPrompt: (_, request) async {
          final generation = _generation;
          if (!_current || !UploadWebPolicy.official(request.url)) {
            return JsPromptResponse(
                handledByClient: true, action: JsPromptResponseAction.CANCEL);
          }
          var text = request.defaultValue ?? '';
          final entered = await _dialog<String>((ctx) => AlertDialog(
                title: Text(_l('官方网页输入', 'Official website input')),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(request.message ?? ''),
                  TextFormField(
                      initialValue: text, onChanged: (value) => text = value),
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(_l('取消', 'Cancel'))),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, text),
                      child: Text(_l('确认', 'Confirm'))),
                ],
              ));
          final confirmed = entered != null && _owns(generation);
          if (confirmed) frame.dirty = true;
          return JsPromptResponse(
              handledByClient: true,
              value: confirmed ? entered : null,
              action: confirmed
                  ? JsPromptResponseAction.CONFIRM
                  : JsPromptResponseAction.CANCEL);
        },
        androidOnFormResubmission: (_, __) async {
          _message('未自动重发历史表单，请打开管理页核对。',
              'The previous form was not resubmitted. Reopen the manager to check it.');
          return FormResubmissionAction.DONT_RESEND;
        },
        androidOnPermissionRequest: (_, __, resources) async =>
            PermissionRequestResponse(
                resources: resources,
                action: PermissionRequestResponseAction.DENY),
      );

  Widget _failureView() {
    final message = switch (_failure) {
      'entry' => _l('请从画廊列表或新建入口打开官方管理页。',
          'Open the official manager from the gallery list or new-gallery entry.'),
      'session' => _l('账号或网页登录状态已改变，旧网页已关闭。请返回应用确认登录后再进入。',
          'The account or website session changed. The old page was closed; verify your app login before returning.'),
      'closed' => _l('官方网页已关闭，请返回应用继续。',
          'The official page is closed. Return to the app to continue.'),
      'network' => _l('当前网页无法使用应用的网络设置。尚未载入网页。',
          'This browser could not use the app’s network configuration. No page was loaded.'),
      'changed' => _l('网络设置已改变，旧网页已停止。请明确重新载入并核对未保存的修改。',
          'Network settings changed and the old page was stopped. Reload explicitly and check any unsaved changes.'),
      'cleanup' => _l('网页网络设置未能恢复。请重试关闭；若仍失败，请关闭并重新打开应用。',
          'The browser network route could not be restored. Retry closing; if it still fails, restart the app.'),
      _ => _l('无法准备官方网页。请先保存本地修改、停止并核对未完成的上传，再重试。',
          'The official page could not be prepared. Save local changes, stop and reconcile pending uploads, then retry.'),
    };
    return Center(
        child: SingleChildScrollView(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(message),
                  const SizedBox(height: 16),
                  if (_offerSystem)
                    FilledButton(
                        onPressed: _preparing
                            ? null
                            : () {
                                _systemNetwork = true;
                                unawaited(_prepare());
                              },
                        child: Text(_l('明确使用系统网络／VPN载入',
                            'Load using system network / VPN'))),
                  if (!_expired && _failure != 'entry')
                    TextButton(
                        onPressed: _preparing ? null : _retry,
                        child: Text(_l('重试', 'Retry'))),
                  TextButton(
                      onPressed: () {
                        _forceExit = true;
                        Navigator.maybePop(context);
                      },
                      child: Text(_l('返回应用', 'Return to app'))),
                ]))));
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (!didPop) unawaited(_requestPop());
        },
        child: Scaffold(
          appBar: AppBar(
              title: Text(_l('官方上传管理', 'Official upload manager')),
              leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.maybePop(context)),
              actions: [
                IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: _l('重新读取管理页', 'Read the manager again'),
                    onPressed: _preparing || _expired ? null : _retry),
                IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: _l('关闭官方网页', 'Close official page'),
                    onPressed: () {
                      _forceExit = true;
                      Navigator.maybePop(context);
                    })
              ]),
          body: _closing || (_preparing && !_expired)
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_closing
                      ? _l('正在返回并核对站内状态…',
                          'Returning and checking website state…')
                      : _l('正在准备官方网页…', 'Preparing the official page…')),
                ]))
              : _failure != null || _frames.isEmpty
                  ? _failureView()
                  : Column(children: [
                      ConstrainedBox(
                          constraints: BoxConstraints(
                              maxHeight: min(200,
                                  MediaQuery.of(context).size.height * .3)),
                          child: SingleChildScrollView(
                              child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: RuleNotice(
                                      rule: UploadRules.byId(
                                          UploadRuleId.webHandoff),
                                      onOpenSource: (uri) => UploadPlatform()
                                          .openExternal(uri))))),
                      Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                          child: Text(
                              _l('${_systemNetwork || _configuredProxy == null ? '系统网络／VPN' : '应用代理'} · 网页上传不会进入应用后台队列，离开前请核对完成情况。',
                                  '${_systemNetwork || _configuredProxy == null ? 'System network / VPN' : 'App proxy'} · Website uploads do not enter the app’s background queue; check completion before leaving.'),
                              style: Theme.of(context).textTheme.bodySmall)),
                      if (_frames.last.failed)
                        MaterialBanner(
                            content: Text(_l(
                                '网页加载失败；站点可能已收到上次操作。重新读取管理页核对，不重发原请求。',
                                'The page failed to load; the website may have received the previous action. Read the manager again without replaying it.')),
                            actions: [
                              TextButton(
                                  onPressed: _retry,
                                  child: Text(_l('核对', 'Check')))
                            ]),
                      if (_frames.last.progress < 100)
                        LinearProgressIndicator(
                            value: _frames.last.progress / 100),
                      Expanded(
                          child: IndexedStack(
                              index: _frames.length - 1,
                              children: _frames.map(_webView).toList())),
                    ]),
        ),
      );

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _cancelDialog();
    _authSubscription?.cancel();
    _network?.removeListener(_networkChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_destroyViews().catchError((Object _) {}).whenComplete(() async {
      try {
        await _finishHandoff();
      } catch (_) {}
    }));
    super.dispose();
  }
}
