import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart' as dio_cookie;
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';
import '../constants/app_constants.dart';

class CookieManager {
  static final _log = Logger();
  late final PersistCookieJar _cookieJar;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    final cookiePath = '${dir.path}/.cookies/';
    _cookieJar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage(cookiePath),
    );
    _initialized = true;
    _log.i('CookieManager initialized at $cookiePath');
  }

  void configureDio(Dio dio) {
    dio.interceptors.add(dio_cookie.CookieManager(_cookieJar));
  }

  Future<String> getCookieHeader(Uri uri) async {
    if (!AppConstants.useExHentai && _isExHentaiHost(uri.host)) {
      return '';
    }

    final cookies = await _cookieJar.loadForRequest(uri);
    if (!_isTrustedImageHost(uri.host)) {
      return _toCookieHeader(_filterCookiesForCurrentSite(cookies));
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
    return _toCookieHeader(merged.values);
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
  }) async {
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
    await _cookieJar.saveFromResponse(
      exUri,
      makeCookies('.exhentai.org', includeIgneous: true),
    );
    _log.i('Login cookies saved for both domains');
  }

  Future<bool> hasLoginCookies() async {
    final cookies = await _cookieJar.loadForRequest(
      Uri.parse(AppConstants.ehBaseUrl),
    );
    return cookies.any((c) => c.name == AppConstants.cookieIpbMemberId);
  }

  Future<String?> getMemberId() async {
    final cookies = await _cookieJar.loadForRequest(
      Uri.parse(AppConstants.ehBaseUrl),
    );
    try {
      return cookies
          .firstWhere((c) => c.name == AppConstants.cookieIpbMemberId)
          .value;
    } catch (_) {
      return null;
    }
  }

  Future<void> syncCookiesToExHentai() async {
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
    await _cookieJar.saveFromResponse(exUri, exCookies);
    _log.i('Synced login cookies to ExHentai domain');
  }

  Future<void> clearCookies() async {
    await _cookieJar.deleteAll();
    _log.i('All cookies cleared');
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

  bool _isAuthenticationCookie(String name) {
    return name == AppConstants.cookieIpbMemberId ||
        name == AppConstants.cookieIpbPassHash ||
        name == AppConstants.cookieIgneous ||
        name == AppConstants.cookieSk;
  }

  String _toCookieHeader(Iterable<Cookie> cookies) {
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  Iterable<Cookie> _filterCookiesForCurrentSite(Iterable<Cookie> cookies) {
    if (AppConstants.useExHentai) return cookies;
    return cookies.where((cookie) => cookie.name != AppConstants.cookieIgneous);
  }
}
