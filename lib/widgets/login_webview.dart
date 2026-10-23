import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/constants/app_constants.dart';
import '../core/l10n/s.dart';
import '../core/network/network_proxy_io.dart';

typedef PublicLoginInspector = Future<Map<String, dynamic>?> Function(
    String script);

/// Owns one browser session, including while switching tabs or saving a login.
class LoginWebView extends StatefulWidget {
  const LoginWebView({
    super.key,
    required this.url,
    required this.enabled,
    required this.onLogin,
    this.publicOnly = false,
    this.onInspectorReady,
  });

  final Uri url;
  final bool enabled;
  final ValueChanged<Map<String, String>> onLogin;
  final bool publicOnly;
  final ValueChanged<PublicLoginInspector>? onInspectorReady;

  static bool allowsPublicNavigation(Uri? uri, String? method) {
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !const {'forums.e-hentai.org', 'e-hentai.org'}.contains(uri.host))
      return false;
    return !(method == 'POST' &&
        uri.path == '/index.php' &&
        uri.queryParameters['act'] == 'Login' &&
        uri.queryParameters['CODE'] == '01');
  }

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView>
    with AutomaticKeepAliveClientMixin {
  MethodChannel? _channel;
  InAppWebViewController? _androidController;
  int _readGeneration = 0;
  bool _checking = false;
  bool _submitted = false;
  bool _loadFailed = false;
  bool _publicGuardInstalled = false;
  Uri? _pendingUrl;
  late Future<void> _networkReady = NetworkProxy.waitUntilReady();

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(LoginWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _readGeneration++;
      _pendingUrl = null;
      if (widget.enabled) _submitted = false;
    }
  }

  bool _trusted(Uri? url) =>
      url?.scheme == 'https' &&
      const {'forums.e-hentai.org', 'e-hentai.org', 'exhentai.org'}
          .contains(url?.host);

  Future<void> _checkLogin(Uri? url) async {
    if (!mounted ||
        widget.publicOnly ||
        !widget.enabled ||
        _submitted ||
        !_trusted(url)) return;
    _pendingUrl = url;
    if (_checking) return;
    _checking = true;
    final generation = _readGeneration;
    try {
      // Cookie-store notifications may arrive during a read; coalesce them
      // rather than losing the notification that supplies the second cookie.
      while (mounted && widget.enabled && !_submitted && _pendingUrl != null) {
        final current = _pendingUrl!;
        _pendingUrl = null;
        for (final scope in {current, Uri.parse(AppConstants.ehBaseUrl)}) {
          final cookies = await CookieManager.instance().getCookies(url: scope);
          if (!mounted || !widget.enabled || generation != _readGeneration) {
            return;
          }
          final values = {for (final c in cookies) c.name: c.value};
          final member = values[AppConstants.cookieIpbMemberId];
          final pass = values[AppConstants.cookieIpbPassHash];
          // Do not assemble a login from partial cookies belonging to
          // different scopes, or treat a Cloudflare cookie as a login.
          if (member == null ||
              member.isEmpty ||
              pass == null ||
              pass.isEmpty) {
            continue;
          }
          _submitted = true;
          widget.onLogin({
            AppConstants.cookieIpbMemberId: member,
            AppConstants.cookieIpbPassHash: pass,
            if (values[AppConstants.cookieIgneous]?.isNotEmpty == true)
              AppConstants.cookieIgneous: values[AppConstants.cookieIgneous]!,
          });
          break;
        }
      }
    } on PlatformException {
      // The native store can be busy during navigation; a later page/cookie
      // notification or an explicit retry will read it again.
    } finally {
      _checking = false;
      if (mounted && widget.enabled && !_submitted && _pendingUrl != null) {
        unawaited(_checkLogin(_pendingUrl));
      }
    }
  }

  void _failed(bool value) {
    if (mounted && _loadFailed != value) setState(() => _loadFailed = value);
  }

  void _created(int id) {
    _channel = MethodChannel('oviewer/login-webview/$id');
    _channel!.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'onLoadStart':
          _failed(false);
          break;
        case 'onLoadStop':
        case 'onCookiesChanged':
          final args = call.arguments as Map?;
          await _checkLogin(Uri.tryParse(args?['url'] as String? ?? ''));
          break;
        case 'onLoadError':
          _failed(true);
          break;
      }
    });
    widget.onInspectorReady?.call(_inspectPublicForm);
  }

  Future<Map<String, dynamic>?> _inspectPublicForm(String script) async {
    if (!mounted || !widget.publicOnly) return {'failed': true};
    dynamic snapshot;
    if (_channel != null) {
      snapshot = await _channel!.invokeMapMethod<String, dynamic>(
          'inspectPublicForm', {'script': script});
    } else {
      final controller = _androidController;
      final url = await controller?.getUrl();
      if (!LoginWebView.allowsPublicNavigation(url, 'GET'))
        return {'ready': false};
      // Leave interstitials untouched; inspect only the ordinary login page.
      final title = (await controller?.getTitle())?.trim().toLowerCase();
      if (!const {'log in', 'login', 'e-hentai.org login'}.contains(title)) {
        return {'ready': false, 'phase': 'page_loading'};
      }
      if (!_publicGuardInstalled) {
        _publicGuardInstalled = true;
        await controller?.setOptions(options: _options());
      }
      snapshot = await controller?.evaluateJavascript(source: script);
    }
    if (!mounted || snapshot is! Map) return {'ready': false};
    final result = Map<String, dynamic>.from(snapshot);
    if (result['ready'] == true) {
      final values = await CookieManager.instance().getCookies(url: widget.url);
      if (!mounted) return {'failed': true};
      result['cookies'] = values
          .where((c) => const {'cf_clearance', '__cf_bm'}.contains(c.name))
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
    }
    return result;
  }

  Future<void> _reload() async {
    _submitted = false;
    _failed(false);
    try {
      if (_channel != null) {
        await _channel!.invokeMethod<void>('reload');
      } else {
        await _androidController?.reload();
      }
    } on PlatformException {
      _failed(true);
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (NetworkProxy.beforeRequest == null) return _buildReady(context);
    return FutureBuilder<void>(
        future: _networkReady,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: TextButton(
                    onPressed: () => setState(
                        () => _networkReady = NetworkProxy.waitUntilReady()),
                    child: Text(S.of(context).retry)));
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return _buildReady(context);
        });
  }

  Widget _buildReady(BuildContext context) {
    final s = S.of(context);
    return Column(children: [
      if (!widget.publicOnly)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: widget.enabled ? _reload : null,
            icon: const Icon(Icons.refresh),
            label: Text(s.reloadLoginPage),
          ),
        ),
      if (_loadFailed)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(s.loadFailedTapRetry),
        ),
      Expanded(
        child: defaultTargetPlatform == TargetPlatform.iOS
            ? UiKitView(
                viewType: 'oviewer/login-webview',
                creationParams: {
                  'url': widget.url.toString(),
                  if (widget.publicOnly) 'publicOnly': true
                },
                creationParamsCodec: const StandardMessageCodec(),
                onPlatformViewCreated: _created,
              )
            : InAppWebView(
                initialUrlRequest: URLRequest(url: widget.url),
                initialOptions: _options(),
                onWebViewCreated: (controller) {
                  _androidController = controller;
                  widget.onInspectorReady?.call(_inspectPublicForm);
                },
                shouldOverrideUrlLoading: (_, action) async =>
                    !widget.publicOnly ||
                            action.isForMainFrame == false ||
                            LoginWebView.allowsPublicNavigation(
                                action.request.url, action.request.method)
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL,
                androidShouldInterceptRequest: (_, request) async {
                  if (widget.publicOnly &&
                      request.isForMainFrame == true &&
                      !LoginWebView.allowsPublicNavigation(
                          request.url, request.method)) {
                    return WebResourceResponse(
                        contentType: 'text/plain',
                        data: Uint8List(0),
                        statusCode: 403,
                        reasonPhrase: 'Blocked',
                        headers: {});
                  }
                  return null;
                },
                onLoadStart: (_, __) => _failed(false),
                onLoadStop: (_, url) => _checkLogin(url),
                onUpdateVisitedHistory: (_, url, __) => _checkLogin(url),
                onLoadError: (_, __, code, ___) {
                  if (code != -999) _failed(true);
                },
              ),
      ),
    ]);
  }

  InAppWebViewGroupOptions _options() => InAppWebViewGroupOptions(
        crossPlatform: InAppWebViewOptions(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: widget.publicOnly,
            cacheEnabled: !widget.publicOnly,
            incognito: false),
        android: AndroidInAppWebViewOptions(
            domStorageEnabled: true,
            thirdPartyCookiesEnabled: true,
            useShouldInterceptRequest:
                widget.publicOnly && _publicGuardInstalled),
      );
}
