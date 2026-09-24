import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/constants/app_constants.dart';
import '../core/l10n/s.dart';

/// Owns one browser session, including while switching tabs or saving a login.
class LoginWebView extends StatefulWidget {
  const LoginWebView({
    super.key,
    required this.url,
    required this.enabled,
    required this.onLogin,
  });

  final Uri url;
  final bool enabled;
  final ValueChanged<Map<String, String>> onLogin;

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView>
    with AutomaticKeepAliveClientMixin {
  MethodChannel? _channel;
  InAppWebViewController? _androidController;
  bool _checking = false;
  bool _submitted = false;
  bool _loadFailed = false;
  Uri? _pendingUrl;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(LoginWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled) _submitted = false;
  }

  bool _trusted(Uri? url) =>
      url?.scheme == 'https' &&
      const {'forums.e-hentai.org', 'e-hentai.org', 'exhentai.org'}
          .contains(url?.host);

  Future<void> _checkLogin(Uri? url) async {
    if (!mounted || !widget.enabled || _submitted || !_trusted(url)) return;
    _pendingUrl = url;
    if (_checking) return;
    _checking = true;
    try {
      // Cookie-store notifications may arrive during a read; coalesce them
      // rather than losing the notification that supplies the second cookie.
      while (mounted && widget.enabled && !_submitted && _pendingUrl != null) {
        final current = _pendingUrl!;
        _pendingUrl = null;
        for (final scope in {current, Uri.parse(AppConstants.ehBaseUrl)}) {
          final cookies = await CookieManager.instance().getCookies(url: scope);
          if (!mounted || !widget.enabled) return;
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
    final s = S.of(context);
    return Column(children: [
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
                creationParams: {'url': widget.url.toString()},
                creationParamsCodec: const StandardMessageCodec(),
                onPlatformViewCreated: _created,
              )
            : InAppWebView(
                initialUrlRequest: URLRequest(url: widget.url),
                initialOptions: InAppWebViewGroupOptions(
                  crossPlatform: InAppWebViewOptions(
                    javaScriptEnabled: true,
                    useShouldOverrideUrlLoading: false,
                    cacheEnabled: true,
                    incognito: false,
                  ),
                  android: AndroidInAppWebViewOptions(
                    domStorageEnabled: true,
                    thirdPartyCookiesEnabled: true,
                  ),
                ),
                onWebViewCreated: (controller) =>
                    _androidController = controller,
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
}
