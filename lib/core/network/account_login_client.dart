import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart' as cookies;
import 'package:html/parser.dart' as html;
import 'package:flutter/foundation.dart';

import '../constants/api_endpoints.dart';
import 'network_proxy_io.dart';
import 'automatic_login_check.dart';

enum AccountLoginFailure {
  credentials,
  challenge,
  browserRequired,
  network,
  site
}

class AccountLoginException implements Exception {
  const AccountLoginException(this.reason);
  final AccountLoginFailure reason;
  @override
  String toString() => 'AccountLoginException(${reason.name})';
}

/// Credentials exist only for the duration of this operation. Never log them.
class AccountLoginResult {
  const AccountLoginResult(this.memberId, this.passHash,
      {this.igneous, this.exUnavailable = false});
  final String memberId;
  final String passHash;
  final String? igneous;
  final bool exUnavailable;
  @override
  String toString() => 'AccountLoginResult';
}

/// An isolated, non-persistent cookie jar prevents failed attempts from changing
/// the app session. Only a verified result is handed to the session owner.
class AccountLoginClient {
  AccountLoginClient(
      {Dio Function()? createDio, AutomaticLoginCheck? automaticCheck})
      : _createDio = createDio ?? _nativeDio,
        _automaticCheck = automaticCheck ?? AutomaticLoginCheck();
  final Dio Function() _createDio;
  final AutomaticLoginCheck _automaticCheck;

  static Dio _nativeDio() => Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: NetworkProxy.createAuthenticatedHttpClient);

  static bool _trusted(Uri uri, {required bool allowEx}) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      (uri.host == 'forums.e-hentai.org' ||
          uri.host == 'e-hentai.org' ||
          (allowEx && uri.host == 'exhentai.org'));

  static bool isChallenge(String body) {
    final doc = html.parse(body);
    final title = doc.querySelector('title')?.text.trim().toLowerCase() ?? '';
    // JSD scripts are also injected into ordinary login and authenticated pages.
    // Their /cdn-cgi/challenge-platform/ URL alone is not an interstitial.
    return doc.querySelector('#challenge-form, #challenge-running') != null ||
        title == 'just a moment...' ||
        title == 'just a moment…' ||
        body.contains('window._cf_chl_opt');
  }

  static bool _authenticatedForum(String body, String memberId) {
    final links = html.parse(body).querySelectorAll('a[href]').map((a) =>
        Uri.tryParse(a.attributes['href'] ?? '')?.queryParameters ??
        <String, String>{});
    return links.any((q) => q['act'] == 'Login' && q['CODE'] == '03') &&
        links.any((q) => q['showuser'] == memberId);
  }

  Future<AccountLoginResult> login({
    required String username,
    required String password,
    required bool checkEx,
    required CancelToken cancelToken,
  }) async {
    final dio = _createDio();
    final jar = CookieJar();
    dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.plain,
      followRedirects: false,
      validateStatus: (status) =>
          status != null && status >= 200 && status < 600,
    );
    dio.interceptors.add(cookies.CookieManager(jar));
    void current() {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    }

    Future<Response<String>> request(Uri uri,
        {Map<String, String>? form, Uri? referer, bool allowEx = false}) async {
      for (var hop = 0; hop <= 5; hop++) {
        current();
        if (!_trusted(uri, allowEx: allowEx)) {
          throw const AccountLoginException(AccountLoginFailure.site);
        }
        final response = await dio.request<String>(uri.toString(),
            data: form,
            cancelToken: cancelToken,
            options: Options(
                method: form == null ? 'GET' : 'POST',
                headers: form == null
                    ? null
                    : {
                        'Origin': uri.origin,
                        if (referer != null) 'Referer': referer.toString(),
                      },
                contentType: Headers.formUrlEncodedContentType));
        current();
        if (kDebugMode)
          debugPrint(
              'OVIEWER_ACCOUNT_HTTP ${form == null ? "GET" : "POST"} ${response.statusCode} interstitial=${isChallenge(response.data ?? "")}');
        if (response.headers.value('cf-mitigated') == 'challenge' ||
            isChallenge(response.data ?? '')) {
          throw const AccountLoginException(
              AccountLoginFailure.browserRequired);
        }
        final code = response.statusCode!;
        if ({301, 302, 303, 307, 308}.contains(code)) {
          // Never replay a password-bearing POST, including for 307/308.
          if (form != null && (code == 307 || code == 308)) {
            throw const AccountLoginException(AccountLoginFailure.site);
          }
          final location = response.headers.value('location');
          if (location == null) {
            throw const AccountLoginException(AccountLoginFailure.site);
          }
          uri = uri.resolve(location);
          form = null;
          continue;
        }
        if (code < 200 || code >= 300) {
          throw const AccountLoginException(AccountLoginFailure.site);
        }
        return response;
      }
      throw const AccountLoginException(AccountLoginFailure.site);
    }

    try {
      await Future.any([NetworkProxy.waitUntilReady(), cancelToken.whenCancel]);
      current();
      // The site currently embeds Turnstile in its login form. Prepare that
      // form in the real browser first, without an extra unverified HTTP GET.
      final checkProxy = NetworkProxy.currentProxy;
      final preparation = await _automaticCheck.run(cancelToken);
      current();
      if (checkProxy != NetworkProxy.currentProxy) {
        throw const AccountLoginException(AccountLoginFailure.network);
      }
      if (preparation.status == BrowserCheckStatus.interactive) {
        throw const AccountLoginException(AccountLoginFailure.challenge);
      }
      if (preparation.status != BrowserCheckStatus.ready ||
          preparation.formHtml == null ||
          preparation.formUrl == null ||
          preparation.userAgent.isEmpty) {
        throw const AccountLoginException(AccountLoginFailure.browserRequired);
      }
      if (!_trusted(preparation.formUrl!, allowEx: false) ||
          preparation.formUrl!.host != 'forums.e-hentai.org') {
        throw const AccountLoginException(AccountLoginFailure.site);
      }
      dio.options.headers['User-Agent'] = preparation.userAgent;
      await jar.saveFromResponse(
          Uri.parse(ApiEndpoints.loginPage),
          preparation.cookies
              .where((c) => AutomaticLoginCheck.cookieNames.contains(c.name))
              .toList());
      current();
      // Keep this exact form and one-use response; a new GET would discard it.
      final page = Response<String>(
          data: preparation.formHtml,
          statusCode: 200,
          requestOptions: RequestOptions(path: preparation.formUrl.toString()));
      final doc = html.parse(page.data);
      final forms = doc
          .querySelectorAll('form')
          .where((f) => f.querySelector('input[type="password"][name]') != null)
          .toList();
      if (forms.length != 1) {
        throw const AccountLoginException(AccountLoginFailure.site);
      }
      final form = forms.single;
      final action = page.realUri.resolve(form.attributes['action'] ?? '');
      final users = form
          .querySelectorAll('input[name]')
          .where((e) =>
              {'text', 'email', ''}
                  .contains(e.attributes['type']?.toLowerCase() ?? '') &&
              !e.attributes.containsKey('disabled'))
          .toList();
      final passwords = form.querySelectorAll('input[type="password"][name]');
      if (action.scheme != 'https' ||
          action.host != 'forums.e-hentai.org' ||
          action.userInfo.isNotEmpty ||
          action.port != 443 ||
          action.path != '/index.php' ||
          users.length != 1 ||
          passwords.length != 1 ||
          form.attributes['method']?.toLowerCase() != 'post') {
        throw const AccountLoginException(AccountLoginFailure.site);
      }
      final values = <String, String>{
        for (final e in form.querySelectorAll('input[type="hidden"][name]'))
          e.attributes['name']!: e.attributes['value'] ?? '',
        for (final e
            in form.querySelectorAll('input[type="checkbox"][checked][name]'))
          e.attributes['name']!: e.attributes['value'] ?? 'on',
        for (final e
            in form.querySelectorAll('input[type="submit"][name]').take(1))
          e.attributes['name']!: e.attributes['value'] ?? '',
        users.single.attributes['name']!: username.trim(),
        passwords.single.attributes['name']!: password,
      };
      if ((action.queryParameters['act'] ?? values['act']) != 'Login' ||
          (action.queryParameters['CODE'] ?? values['CODE']) != '01') {
        throw const AccountLoginException(AccountLoginFailure.site);
      }
      final submitted =
          await request(action, form: values, referer: page.realUri);
      final forum = Uri.https('forums.e-hentai.org', '/index.php');
      final received = await jar.loadForRequest(forum);
      String? value(String name) {
        for (final cookie in received) {
          if (cookie.name == name && cookie.value.isNotEmpty)
            return cookie.value;
        }
        return null;
      }

      final member = value('ipb_member_id');
      final pass = value('ipb_pass_hash');
      if (member == null || pass == null) {
        final text = html.parse(submitted.data).body?.text.toLowerCase() ?? '';
        final invalid = text.contains('incorrect password') ||
            text.contains('password you entered is incorrect') ||
            text.contains('username or password') ||
            text.contains('could not find a member') ||
            text.contains('cannot find an account');
        throw AccountLoginException(invalid
            ? AccountLoginFailure.credentials
            : AccountLoginFailure.site);
      }
      final verified = await request(forum);
      if (!_authenticatedForum(verified.data ?? '', member)) {
        throw const AccountLoginException(AccountLoginFailure.site);
      }
      String? igneous;
      var exUnavailable = false;
      if (checkEx) {
        final ex = Uri.https('exhentai.org', '/');
        await jar.saveFromResponse(ex, [
          Cookie('ipb_member_id', member)..path = '/',
          Cookie('ipb_pass_hash', pass)..path = '/',
        ]);
        try {
          final response = await request(ex, allowEx: true);
          final exDoc = html.parse(response.data);
          final hasGalleryNav = exDoc.querySelectorAll('a[href]').any((a) {
            final uri = ex.resolve(a.attributes['href']!);
            return uri.origin == ex.origin && uri.path == '/uconfig.php';
          });
          final exCookies = await jar.loadForRequest(ex);
          for (final cookie in exCookies) {
            if (cookie.name == 'igneous' &&
                cookie.value.isNotEmpty &&
                cookie.value != 'mystery') igneous = cookie.value;
          }
          exUnavailable = !hasGalleryNav;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) rethrow;
          exUnavailable = true;
        } on AccountLoginException {
          exUnavailable = true;
        }
      }
      current();
      return AccountLoginResult(member, pass,
          igneous: igneous, exUnavailable: exUnavailable);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw const AccountLoginException(AccountLoginFailure.network);
    } finally {
      dio.close(force: true);
      await jar.deleteAll();
    }
  }
}
