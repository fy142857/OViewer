import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'network_proxy_io.dart';

enum BrowserCheckStatus { ready, interactive, unavailable }

class BrowserCheckResult {
  const BrowserCheckResult(this.status,
      {this.userAgent = '',
      this.cookies = const [],
      this.formHtml,
      this.formUrl});
  final BrowserCheckStatus status;
  final String userAgent;
  final List<Cookie> cookies;
  final String? formHtml;
  final Uri? formUrl;
  @override
  String toString() => 'BrowserCheckResult(${status.name})';
}

/// Coordinates the public login page without sending it credentials. The site
/// runs its checks; any CAPTCHA interaction belongs to the user in the widget.
class AutomaticLoginCheck {
  AutomaticLoginCheck(
      {this.timeout = const Duration(seconds: 40),
      this.pollInterval = const Duration(milliseconds: 500),
      Future<Map<String, dynamic>?> Function(int, String)? snapshotReader})
      : _snapshotReader = snapshotReader ?? _readAttached;
  final Duration timeout;
  final Duration pollInterval;
  final Future<Map<String, dynamic>?> Function(int, String) _snapshotReader;
  static const _channel = MethodChannel('oviewer/automatic_login_check');
  static int _nextId = 0;
  static Future<void> _previous = Future.value();
  static final activeView = ValueNotifier<int?>(null);
  static final _inspectors =
      <int, Future<Map<String, dynamic>?> Function(String)>{};
  static final _interacted = <int>{};
  static void attach(
      int id, Future<Map<String, dynamic>?> Function(String) inspector) {
    if (activeView.value == id) _inspectors[id] = inspector;
  }

  static void detach(
      int id, Future<Map<String, dynamic>?> Function(String) inspector) {
    if (identical(_inspectors[id], inspector)) _inspectors.remove(id);
  }

  static void interacted(int id) {
    if (activeView.value == id) _interacted.add(id);
  }

  static Future<Map<String, dynamic>?> _readAttached(
          int id, String script) async =>
      await _inspectors[id]?.call(script) ??
      {'ready': false, 'phase': 'waiting_for_view'};
  static const cookieNames = {'cf_clearance', '__cf_bm'};

  // Keep credentials in app fields. Cross-origin challenge frames are neither
  // inspected nor clicked; only the ordinary login form is prepared here.
  static const probeScript = r'''(() => {
    const visible = e => !!(e && e.getClientRects().length &&
      getComputedStyle(e).visibility !== 'hidden');
    const form = [...document.forms].find(f => {
      const a = new URL(f.action, location.href);
      return a.protocol === 'https:' && a.hostname === 'forums.e-hentai.org' &&
        a.pathname === '/index.php' && a.searchParams.get('act') === 'Login' &&
        a.searchParams.get('CODE') === '01' &&
        f.querySelector('input[name="UserName"]') &&
        f.querySelector('input[name="PassWord"][type="password"]');
    });
    if (form && !form.dataset.oviewerPreparation) {
      form.dataset.oviewerPreparation = 'true';
      form.addEventListener('submit', e => e.preventDefault());
      for (const input of form.querySelectorAll('input[name="UserName"], input[name="PassWord"]')) {
        input.readOnly = true;
      }
    }
    const interactive = [...document.querySelectorAll('input:not([type="hidden"])')]
      .some(e => visible(e) && (/captcha/i.test(e.name || '') ||
        (e.type === 'checkbox' && !e.checked && [...(e.labels || [])]
          .some(l => /verify (that )?you are human|i.m not a robot/i.test(l.textContent || '')))));
    const widget = document.querySelector('.cf-turnstile, .g-recaptcha');
    const responseName = (widget && widget.getAttribute('data-response-field-name')) ||
      (widget && widget.classList.contains('g-recaptcha') ? 'g-recaptcha-response' : 'cf-turnstile-response');
    const response = [...document.querySelectorAll('input[type="hidden"], textarea')]
      .find(e => e.name === responseName);
    const ready = !!form && !interactive && (!widget || !!(response && response.value));
    if (!ready) return {ready: false, interactive,
      phase: form ? 'form_verification' :
        (document.querySelector('a[href*="CODE=03"]') ? 'browser_session_present' : 'page_loading')};
    // Serialize successful form controls without reading credentials. The
    // detached copy is never attached to the page or submitted by this browser.
    const clean = document.createElement('form');
    clean.method = form.method;
    clean.action = form.action;
    for (const source of form.querySelectorAll('input[name]')) {
      if (source.disabled || (source.type === 'checkbox' && !source.checked)) continue;
      if (!['hidden', 'checkbox', 'submit', 'text', 'password'].includes(source.type)) continue;
      const input = document.createElement('input');
      input.type = source.type;
      input.name = source.name;
      input.setAttribute('value', ['text', 'password'].includes(source.type) ? '' : source.value);
      if (source.checked) input.setAttribute('checked', 'checked');
      clean.appendChild(input);
    }
    if (widget && response && ![...clean.elements].some(e => e.name === responseName)) {
      const input = document.createElement('input');
      input.type = 'hidden'; input.name = responseName; input.setAttribute('value', response.value);
      clean.appendChild(input);
    }
    return {ready: true, interactive: false, userAgent: navigator.userAgent,
      formHtml: clean.outerHTML, formUrl: location.href};
  })()''';

  Future<BrowserCheckResult> run(CancelToken token) async {
    final preceding = _previous;
    final released = Completer<void>();
    _previous = released.future;
    final id = ++_nextId;
    var started = false;
    String? lastPhase;
    void phase(String value) {
      if (kDebugMode && value != lastPhase) {
        debugPrint('OVIEWER_ACCOUNT_CHECK $id $value');
      }
      lastPhase = value;
    }

    Future<T> cancellable<T>(Future<T> work) => Future.any([
          work,
          token.whenCancel.then<T>((error) => throw error),
        ]);
    final proxy = NetworkProxy.currentProxy;
    try {
      await cancellable(preceding);
      if (token.isCancelled) throw token.cancelError!;
      final watch = Stopwatch()..start();
      started = defaultTargetPlatform != TargetPlatform.iOS;
      phase('begin');
      final available = !started
          ? proxy == null
          : await cancellable(_channel.invokeMethod<bool>('begin', {
              'id': id,
              'proxy': proxy,
            }).timeout(timeout));
      if (available != true) {
        phase('unsupported');
        return const BrowserCheckResult(BrowserCheckStatus.unavailable);
      }
      activeView.value = id;
      var limit = timeout;
      while (watch.elapsed < limit) {
        final snapshot = await cancellable(
            _snapshotReader(id, probeScript).timeout(limit - watch.elapsed));
        if (token.isCancelled) throw token.cancelError!;
        phase(snapshot?['ready'] == true
            ? 'ready'
            : snapshot?['failed'] == true
                ? 'native_failed'
                : snapshot?['phase'] as String? ?? 'loading');
        if (proxy != NetworkProxy.currentProxy || snapshot?['failed'] == true) {
          return const BrowserCheckResult(BrowserCheckStatus.unavailable);
        }
        if ((_interacted.contains(id) || snapshot?['interacted'] == true) &&
            _inspectors.containsKey(id)) {
          limit = const Duration(minutes: 2);
        }
        if (snapshot?['interactive'] == true && !_inspectors.containsKey(id)) {
          return const BrowserCheckResult(BrowserCheckStatus.interactive);
        }
        if (snapshot?['ready'] == true) {
          final ua = snapshot?['userAgent'] as String? ?? '';
          final formHtml = snapshot?['formHtml'] as String?;
          final formUrl = Uri.tryParse(snapshot?['formUrl'] as String? ?? '');
          if (ua.isEmpty ||
              formHtml == null ||
              formHtml.isEmpty ||
              formUrl == null ||
              formUrl.scheme != 'https' ||
              formUrl.host != 'forums.e-hentai.org' ||
              formUrl.port != 443 ||
              formUrl.userInfo.isNotEmpty ||
              formUrl.path != '/index.php')
            return const BrowserCheckResult(BrowserCheckStatus.unavailable);
          final values = <Cookie>[];
          for (final part
              in (snapshot?['cookies'] as String? ?? '').split(';')) {
            final index = part.indexOf('=');
            if (index < 1) continue;
            final name = part.substring(0, index).trim();
            if (!cookieNames.contains(name)) continue;
            values.add(Cookie(name, part.substring(index + 1).trim())
              ..path = '/'
              ..secure = true);
          }
          return BrowserCheckResult(BrowserCheckStatus.ready,
              userAgent: ua,
              cookies: values,
              formHtml: formHtml,
              formUrl: formUrl);
        }
        await cancellable(Future<void>.delayed(pollInterval));
      }
    } on MissingPluginException {
      // A platform without the background browser keeps the explicit fallback.
    } on PlatformException {
    } on TimeoutException {
      phase('timeout');
    } finally {
      if (activeView.value == id) activeView.value = null;
      _inspectors.remove(id);
      _interacted.remove(id);
      if (started) {
        try {
          await _channel.invokeMethod<void>(
              'close', {'id': id}).timeout(const Duration(seconds: 3));
        } on Exception {/* Native close is also bound to the host lifecycle. */}
      }
      // A cancelled queued attempt must not allow a third attempt to overtake
      // the still-running first browser (its proxy override is process-wide).
      await preceding;
      released.complete();
    }
    phase('not_completed');
    return const BrowserCheckResult(BrowserCheckStatus.unavailable);
  }
}
