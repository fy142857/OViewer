import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/account_login_client.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'comment_redirect_test.dart' show RedirectAdapter;

final form = File('test/fixtures/account_login_form.html').readAsStringSync();
// Synthetic authenticated response: never contains real account information.
const verified = '<a href="index.php?act=Login&amp;CODE=03">Log Out</a>'
    '<a href="index.php?showuser=123">Test</a>';
ResponseBody body(String text, [int status = 200]) =>
    ResponseBody.fromString(text, status);
ResponseBody loggedIn({String? location, bool partial = false}) =>
    ResponseBody.fromString('Welcome', location == null ? 200 : 302, headers: {
      'set-cookie': [
        'ipb_member_id=123; Path=/; Secure',
        if (!partial) 'ipb_pass_hash=test-hash; Path=/; Secure'
      ],
      if (location != null) 'location': [location],
    });

Future<AccountLoginResult> login(RedirectAdapter adapter,
        {bool ex = false, CancelToken? token}) =>
    AccountLoginClient(createDio: () => Dio()..httpClientAdapter = adapter)
        .login(
            username: '  test 用户  ',
            password: ' a&+密  ',
            checkEx: ex,
            cancelToken: token ?? CancelToken());

Matcher failure(AccountLoginFailure reason) => throwsA(
    isA<AccountLoginException>().having((e) => e.reason, 'reason', reason));

void main() {
  tearDown(() => NetworkProxy.beforeRequest = null);
  test(
      'official form fields, fresh session and hidden values are submitted once',
      () async {
    final adapter = RedirectAdapter((r, n) => n == 1
        ? body(form)
        : n == 2
            ? loggedIn()
            : body(verified));
    final result = await login(adapter);
    expect(result.memberId, '123');
    expect(result.passHash, 'test-hash');
    expect(result.exUnavailable, isFalse);
    expect(adapter.requests.map((r) => r.method), ['GET', 'POST', 'GET']);
    expect(adapter.requests[1].uri.queryParameters['s'], 'test-session');
    expect(Uri.splitQueryString(adapter.bodies[1]), {
      'referer': 'https://forums.e-hentai.org/',
      'b': '',
      'bt': '',
      'UserName': 'test 用户',
      'PassWord': ' a&+密  ',
      'CookieDate': '1',
      'submit': 'Log me in',
    });
    expect(adapter.requests.every((r) => r.uri.host != 'exhentai.org'), isTrue);
  });
  for (final status in [200, 403, 503]) {
    test('challenge with HTTP $status is not a successful login', () async {
      final adapter = RedirectAdapter((r, n) => body(
          '<script src="/cdn-cgi/challenge-platform/a"></script>', status));
      await expectLater(login(adapter), failure(AccountLoginFailure.challenge));
      expect(adapter.requests, hasLength(1));
    });
  }
  test('incorrect password is distinguished without automatic retry', () async {
    final adapter = RedirectAdapter((r, n) =>
        n == 1 ? body(form) : body('The password you entered is incorrect'));
    await expectLater(login(adapter), failure(AccountLoginFailure.credentials));
    expect(adapter.requests, hasLength(2));
  });
  test('partial cookie pair and anonymous 200 do not log in', () async {
    final adapter = RedirectAdapter(
        (r, n) => n == 1 ? body(form) : loggedIn(partial: true));
    await expectLater(login(adapter), failure(AccountLoginFailure.site));
    final anonymous = RedirectAdapter((r, n) => n == 1
        ? body(form)
        : n == 2
            ? loggedIn()
            : body('<html>OK</html>'));
    await expectLater(login(anonymous), failure(AccountLoginFailure.site));
  });
  test('302 keeps response cookies but never replays POST body', () async {
    final adapter = RedirectAdapter((r, n) => n == 1
        ? body(form)
        : n == 2
            ? loggedIn(location: '/index.php')
            : body(verified));
    expect((await login(adapter)).memberId, '123');
    expect(
        adapter.requests.map((r) => r.method), ['GET', 'POST', 'GET', 'GET']);
    expect(adapter.bodies.skip(2).every((b) => b.isEmpty), isTrue);
    expect(adapter.requests[2].headers['cookie'].toString(),
        contains('test-hash'));
  });
  for (final target in [
    'https://example.com/index.php',
    'http://forums.e-hentai.org/index.php',
    'https://exhentai.org/'
  ]) {
    test('rejects redirect outside the current login allowlist: $target',
        () async {
      final adapter = RedirectAdapter(
          (r, n) => n == 1 ? body(form) : loggedIn(location: target));
      await expectLater(login(adapter), failure(AccountLoginFailure.site));
      expect(adapter.requests, hasLength(2));
    });
  }
  for (final code in [307, 308]) {
    test('$code never replays credentials', () async {
      final adapter = RedirectAdapter((r, n) => n == 1
          ? body(form)
          : ResponseBody.fromString('', code, headers: {
              'location': ['/index.php']
            }));
      await expectLater(login(adapter), failure(AccountLoginFailure.site));
      expect(adapter.requests, hasLength(2));
    });
  }
  test('redirect count is bounded', () async {
    final adapter =
        RedirectAdapter((r, n) => ResponseBody.fromString('', 302, headers: {
              'location': ['/index.php']
            }));
    await expectLater(login(adapter), failure(AccountLoginFailure.site));
    expect(adapter.requests, hasLength(6));
  });
  test('malformed or non-login form never receives a password', () async {
    for (final invalid in [
      form.replaceAll('CODE=01', 'CODE=03'),
      form.replaceAll('https://forums.e-hentai.org/index.php?s=',
          'https://example.com/index.php?s='),
      '<html>Unavailable</html>'
    ]) {
      final adapter = RedirectAdapter((r, n) => body(invalid));
      await expectLater(login(adapter), failure(AccountLoginFailure.site));
      expect(adapter.requests, hasLength(1));
    }
  });
  test('EX failure preserves verified login without claiming EX access',
      () async {
    final adapter = RedirectAdapter((r, n) => n == 1
        ? body(form)
        : n == 2
            ? loggedIn()
            : n == 3
                ? body(verified)
                : body('Denied', 403));
    final result = await login(adapter, ex: true);
    expect(result.memberId, '123');
    expect(result.exUnavailable, isTrue);
  });
  test('EX success collects igneous and uses the new account pair', () async {
    final adapter = RedirectAdapter((r, n) => n == 1
        ? body(form)
        : n == 2
            ? loggedIn()
            : n == 3
                ? body(verified)
                : ResponseBody.fromString(
                    '<a href="/uconfig.php">Settings</a>', 200,
                    headers: {
                        'set-cookie': ['igneous=test-ex; Path=/']
                      }));
    final result = await login(adapter, ex: true);
    expect(result.igneous, 'test-ex');
    expect(result.exUnavailable, isFalse);
    expect(adapter.requests.last.headers['cookie'].toString(),
        contains('ipb_member_id=123'));
  });
  test('cancelling while proxy prepares makes no request', () async {
    final ready = Completer<void>();
    NetworkProxy.beforeRequest = () => ready.future;
    final token = CancelToken();
    final adapter = RedirectAdapter((r, n) => body(form));
    final result = login(adapter, token: token);
    token.cancel();
    await expectLater(result, throwsA(isA<DioException>()));
    ready.complete();
    expect(adapter.requests, isEmpty);
  });
  test('network error has no credential-bearing diagnostics', () async {
    final adapter = RedirectAdapter((r, n) => throw DioException(
        requestOptions: r, type: DioExceptionType.connectionTimeout));
    await expectLater(login(adapter), failure(AccountLoginFailure.network));
    expect(const AccountLoginResult('123', 'secret').toString(),
        isNot(contains('secret')));
  });
}
