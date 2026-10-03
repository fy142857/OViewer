import 'dart:convert';
import 'dart:io' show File;
import 'native_auth_cookies.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart' as dio_cookie;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as webview;
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';
import '../constants/app_constants.dart';
import '../storage/reader_index_cache.dart';

class CookieManager {
  static const sessionRequestKey = 'oviewer.cookieSession';
  int _sessionRevision = 0;
  int? get sessionRevision => _sessionRevision;
  static final _log = Logger();
  late final PersistCookieJar _cookieJar;
  bool _initialized = false;
  bool _logoutPending = false;
  bool _acceptAuthentication = true;
  late File _logoutMarker;
  Future<void>? _writes;
  Future<void>? _logoutTask;
  final Future<void> Function() _clearBrowserAuthentication;

  CookieManager({Future<void> Function()? clearBrowserAuthentication})
      : _clearBrowserAuthentication =
            clearBrowserAuthentication ?? NativeAuthCookies.clear;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = (_writes ?? Future<void>.value()).then((_) => operation());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  bool _current(int revision) =>
      revision == _sessionRevision && !_logoutPending;
  void _requireCurrent(int revision) {
    if (!_current(revision)) throw StateError('Authentication session expired');
  }

  Future<void> init() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    final cookiePath = '${dir.path}/.cookies/';
    _cookieJar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(cookiePath),
    );
    _logoutMarker = File('${cookiePath}logout-pending');
    _logoutPending = await _logoutMarker.exists();
    final cookies =
        await _cookieJar.loadForRequest(Uri.parse(AppConstants.ehBaseUrl));
    _acceptAuthentication = !_logoutPending && _hasPair(cookies);
    _initialized = true;
    _log.i('CookieManager initialized at $cookiePath');
  }

  void configureDio(Dio dio) {
    dio.interceptors.add(_SessionCookieInterceptor(this));
  }

  /// Install the app's login session before a settings WebView navigates.
  /// WKWebView has its own cookie store; the Dio cookie jar is not shared with it.
  Future<void> syncToWebView(Uri uri) {
    final revision = _sessionRevision;
    return _serial(() => _syncToWebView(uri, revision));
  }

  Future<void> _syncToWebView(Uri uri, int revision) async {
    _requireCurrent(revision);
    if (uri.scheme != 'https' ||
        (uri.host != 'e-hentai.org' && uri.host != 'exhentai.org')) {
      throw ArgumentError.value(uri, 'uri', 'Expected an E-Hentai site URL');
    }

    final cookies = await _cookieJar.loadForRequest(uri);
    final webCookies = webview.CookieManager.instance();
    for (final cookie in cookies) {
      // Keep WebView-owned preferences (such as uconfig) intact. Only copy
      // authentication cookies that apply to this exact destination site.
      if (!_isAuthenticationCookie(cookie.name) ||
          (uri.host == 'e-hentai.org' &&
              cookie.name == AppConstants.cookieIgneous)) {
        continue;
      }
      // The app jar uses ignoreExpires. Mirror an older login cookie as a
      // session cookie instead of asking the native store to delete it.
      final expires = cookie.expires;
      _requireCurrent(revision);
      await webCookies.setCookie(
        url: uri,
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain ?? uri.host,
        path: cookie.path ?? '/',
        expiresDate: expires != null && expires.isAfter(DateTime.now())
            ? expires.millisecondsSinceEpoch
            : null,
        isSecure: cookie.secure,
        isHttpOnly: cookie.httpOnly,
      );
    }
  }

  Future<String> getCookieHeader(Uri uri) async {
    final revision = _sessionRevision;
    if (!AppConstants.useExHentai && _isExHentaiHost(uri.host)) {
      return '';
    }

    final cookies = await _cookieJar.loadForRequest(uri);
    if (!_isTrustedImageHost(uri.host)) {
      return _toCookieHeader(_filterCookiesForCurrentSite(cookies).where((c) =>
          !_isAuthenticationCookie(c.name) ||
          (_current(revision) && _acceptAuthentication)));
    }

    // Image CDNs don't share a cookie domain with ExHentai. Merge, rather
    // than replace, CDN cookies with the ExHentai session. A prior CDN cookie
    // must not prevent ipb_member_id / ipb_pass_hash / igneous from being sent.
    final merged = <String, Cookie>{
      for (final cookie in cookies) cookie.name: cookie,
    };
    final siteCookies = await _cookieJar.loadForRequest(
      Uri.parse(AppConstants.baseUrl),
    );
    for (final cookie in siteCookies) {
      if (_isAuthenticationCookie(cookie.name)) {
        if (!AppConstants.useExHentai &&
            cookie.name == AppConstants.cookieIgneous) {
          continue;
        }
        merged[cookie.name] = cookie;
      }
    }
    return _toCookieHeader(merged.values.where((c) =>
        !_isAuthenticationCookie(c.name) ||
        (_current(revision) && _acceptAuthentication)));
  }

  Future<void> applyRequestHeaders(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final cookieHeader = await getCookieHeader(uri);
    if (cookieHeader.isNotEmpty) headers['Cookie'] = cookieHeader;
    if (_isTrustedImageHost(uri.host)) {
      headers.putIfAbsent('Referer', () => '${AppConstants.baseUrl}/');
      headers.putIfAbsent(
        'Accept',
        () =>
            'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
      );
    }
  }

  Future<void> saveLoginCookies({
    required String memberId,
    required String passHash,
    String? igneous,
  }) {
    if (_logoutPending) return Future.error(const LogoutCleanupException());
    final revision = ++_sessionRevision;
    ReaderIndexCache.shared.clear();
    return _serial(() async {
      _requireCurrent(revision);
      await _saveLoginCookies(
          memberId: memberId,
          passHash: passHash,
          igneous: igneous,
          revision: revision);
      _requireCurrent(revision);
      _acceptAuthentication = true;
    });
  }

  Future<void> _saveLoginCookies(
      {required String memberId,
      required String passHash,
      String? igneous,
      required int revision}) async {
    final ehUri = Uri.parse(AppConstants.ehBaseUrl);
    final exUri = Uri.parse(AppConstants.exBaseUrl);

    List<Cookie> makeCookies(String domain, {required bool includeIgneous}) {
      final list = [
        Cookie(AppConstants.cookieIpbMemberId, memberId)
          ..domain = domain
          ..path = '/',
        Cookie(AppConstants.cookieIpbPassHash, passHash)
          ..domain = domain
          ..path = '/',
      ];
      if (includeIgneous && igneous != null && igneous.isNotEmpty) {
        list.add(Cookie(AppConstants.cookieIgneous, igneous)
          ..domain = domain
          ..path = '/');
      }
      return list;
    }

    await _cookieJar.saveFromResponse(
      ehUri,
      makeCookies('.e-hentai.org', includeIgneous: false),
    );
    _requireCurrent(revision);
    await _cookieJar.saveFromResponse(
      exUri,
      makeCookies('.exhentai.org', includeIgneous: true),
    );
    _log.i('Login cookies saved for both domains');
  }

  bool _hasPair(List<Cookie> cookies) =>
      cookies.any((c) =>
          c.name == AppConstants.cookieIpbMemberId && c.value.isNotEmpty) &&
      cookies.any((c) =>
          c.name == AppConstants.cookieIpbPassHash && c.value.isNotEmpty);

  Future<bool> hasLoginCookies() async {
    if (_logoutPending) await clearCookies();
    final revision = _sessionRevision;
    final cookies = await _cookieJar.loadForRequest(
      Uri.parse(AppConstants.ehBaseUrl),
    );
    return _current(revision) && _acceptAuthentication && _hasPair(cookies);
  }

  Future<String?> getMemberId() async {
    final revision = _sessionRevision;
    final cookies = await _cookieJar.loadForRequest(
      Uri.parse(AppConstants.ehBaseUrl),
    );
    if (!_current(revision) || !_acceptAuthentication || !_hasPair(cookies)) {
      return null;
    }
    try {
      return cookies
          .firstWhere((c) => c.name == AppConstants.cookieIpbMemberId)
          .value;
    } catch (_) {
      return null;
    }
  }

  Future<void> syncCookiesToExHentai() {
    final revision = _sessionRevision;
    return _serial(() => _syncCookiesToExHentai(revision));
  }

  Future<void> _syncCookiesToExHentai(int revision) async {
    _requireCurrent(revision);
    final ehUri = Uri.parse(AppConstants.ehBaseUrl);
    final exUri = Uri.parse(AppConstants.exBaseUrl);
    final ehCookies = await _cookieJar.loadForRequest(ehUri);

    String? memberId;
    String? passHash;
    String? igneous;
    for (final c in ehCookies) {
      if (c.name == AppConstants.cookieIpbMemberId) memberId = c.value;
      if (c.name == AppConstants.cookieIpbPassHash) passHash = c.value;
      if (c.name == AppConstants.cookieIgneous) igneous = c.value;
    }
    if (memberId == null || passHash == null) return;

    final exCookies = [
      Cookie(AppConstants.cookieIpbMemberId, memberId)
        ..domain = '.exhentai.org'
        ..path = '/',
      Cookie(AppConstants.cookieIpbPassHash, passHash)
        ..domain = '.exhentai.org'
        ..path = '/',
    ];
    if (igneous != null && igneous.isNotEmpty) {
      exCookies.add(Cookie(AppConstants.cookieIgneous, igneous)
        ..domain = '.exhentai.org'
        ..path = '/');
    }
    _requireCurrent(revision);
    await _cookieJar.saveFromResponse(exUri, exCookies);
    _log.i('Synced login cookies to ExHentai domain');
  }

  Future<void> clearCookies() {
    final running = _logoutTask;
    if (running != null) return running;
    _sessionRevision++;
    _logoutPending = true;
    _acceptAuthentication = false;
    ReaderIndexCache.shared.clear();
    late Future<void> task;
    task = _serial(() async {
      try {
        await _logoutMarker.parent.create(recursive: true);
        await _logoutMarker.writeAsString('pending', flush: true);
        await _removeJarAuthentication();
        await _clearBrowserAuthentication();
        await _logoutMarker.delete();
        _logoutPending = false;
        _log.i('Authentication cookies cleared');
      } catch (error, stack) {
        _log.w('Authentication cleanup failed (${error.runtimeType})',
            stackTrace: stack);
        throw const LogoutCleanupException();
      }
    }).whenComplete(() {
      if (identical(_logoutTask, task)) _logoutTask = null;
    });
    _logoutTask = task;
    return task;
  }

  Future<void> _removeJarAuthentication() async {
    await _cookieJar.forceInit();
    // PersistCookieJar 4.x exposes the storage and cookie maps but no per-name
    // deletion API. Preserve SerializableCookie metadata when updating its files.
    final index = await _cookieJar.storage.read('.index');
    final hosts = <String>{
      'e-hentai.org',
      'exhentai.org',
      'forums.e-hentai.org',
      ...(index == null
          ? <String>[]
          : (jsonDecode(index) as List).cast<String>())
    }.where(isAccountCookieHost).toSet();
    for (final host in hosts) {
      await _cookieJar.loadForRequest(Uri.https(host, '/'));
    }
    for (final entry in _cookieJar.domainCookies.entries) {
      if (!isAccountCookieHost(entry.key)) continue;
      for (final cookies in entry.value.values) {
        cookies.removeWhere((name, _) => _isAuthenticationCookie(name));
      }
    }
    await _cookieJar.storage
        .write('.domains', jsonEncode(_cookieJar.domainCookies));
    for (final host in hosts) {
      final paths = _cookieJar.hostCookies[host];
      if (paths == null) continue;
      // Host maps loaded by cookie_jar retain a lazy cast over JSON maps.
      for (final cookies in paths.cast<String, dynamic>().values) {
        (cookies as Map)
            .removeWhere((name, _) => _isAuthenticationCookie(name as String));
      }
      await _cookieJar.storage
          .write(host, jsonEncode(paths.cast<String, dynamic>()));
    }
  }

  bool _isTrustedImageHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'e-hentai.org' ||
        normalized.endsWith('.e-hentai.org') ||
        normalized == 'exhentai.org' ||
        normalized.endsWith('.exhentai.org') ||
        normalized == 'ehgt.org' ||
        normalized.endsWith('.ehgt.org') ||
        normalized == 'hath.network' ||
        normalized.endsWith('.hath.network');
  }

  bool _isExHentaiHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'exhentai.org' || normalized.endsWith('.exhentai.org');
  }

  bool _isAuthenticationCookie(String name) =>
      authenticationCookieNames.contains(name);

  String _toCookieHeader(Iterable<Cookie> cookies) {
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  Iterable<Cookie> _filterCookiesForCurrentSite(Iterable<Cookie> cookies) {
    if (AppConstants.useExHentai) return cookies;
    return cookies.where((cookie) => cookie.name != AppConstants.cookieIgneous);
  }
}

class _SessionCookieInterceptor extends dio_cookie.CookieManager {
  final CookieManager owner;
  static const _revisionKey = CookieManager.sessionRequestKey;
  _SessionCookieInterceptor(this.owner) : super(owner._cookieJar);

  @override
  Future<String> loadCookies(RequestOptions options) {
    final revision =
        options.extra[_revisionKey] as int? ?? owner._sessionRevision;
    options.extra[_revisionKey] = revision;
    return owner._serial(() async {
      if (revision != owner._sessionRevision) {
        throw StateError('Stale cookie request');
      }
      final header = await super.loadCookies(options);
      if (revision != owner._sessionRevision) {
        throw StateError('Stale cookie request');
      }
      if (owner._acceptAuthentication && !owner._logoutPending) return header;
      return header
          .split(';')
          .map((c) => c.trim())
          .where((c) => !authenticationCookieNames.contains(c.split('=').first))
          .join('; ');
    });
  }

  @override
  Future<void> saveCookies(Response response) => owner._serial(() async {
        final revision = response.requestOptions.extra[_revisionKey];
        if (revision != owner._sessionRevision || owner._logoutPending) return;
        if (!owner._acceptAuthentication) {
          // Do not let an anonymous or stale response bootstrap a new login.
          final values = response.headers['set-cookie'];
          if (values != null) {
            response.headers.set(
                'set-cookie',
                values
                    .expand(
                        (value) => value.split(RegExp(r'(?<=)(,)(?=[^;]+?=)')))
                    .where((value) => !authenticationCookieNames
                        .contains(value.split('=').first.trim()))
                    .toList());
          }
        }
        await super.saveCookies(response);
      });
}
