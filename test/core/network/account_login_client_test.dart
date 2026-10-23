import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/account_login_client.dart';
import 'package:oviewer/core/network/automatic_login_check.dart';
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'comment_redirect_test.dart' show RedirectAdapter;

final form = File('test/fixtures/account_login_form.html').readAsStringSync();
const verified = '<a href="index.php?act=Login&amp;CODE=03">Log Out</a>'
    '<a href="index.php?showuser=123">Test</a>';
ResponseBody body(String text, [int status = 200]) =>
    ResponseBody.fromString(text, status);
ResponseBody loggedIn({String? location, bool partial = false, int? status}) =>
    ResponseBody.fromString('Welcome', status ?? (location == null ? 200 : 302),
        headers: {
          'set-cookie': [
            'ipb_member_id=123; Path=/; Secure',
            if (!partial) 'ipb_pass_hash=test-hash; Path=/; Secure'
          ],
          if (location != null) 'location': [location],
        });
BrowserCheckResult prepared({String? html, Uri? url}) =>
    BrowserCheckResult(BrowserCheckStatus.ready,
        userAgent: 'native-browser',
        formHtml: html ??
            form.replaceFirst('</form>',
                '<input type="hidden" name="cf-turnstile-response" value="automatic-token"></form>'),
        formUrl: url ??
            Uri.parse(
                'https://forums.e-hentai.org/index.php?act=Login&CODE=00'),
        cookies: [
          Cookie('cf_clearance', 'test-clearance'),
          Cookie('ipb_member_id', 'must-not-import')
        ]);

class FakeCheck extends AutomaticLoginCheck {
  FakeCheck({BrowserCheckResult? answer}) : answer = answer ?? prepared();
  BrowserCheckResult answer;
  int calls = 0;
  Completer<BrowserCheckResult>? pending;
  @override
  Future<BrowserCheckResult> run(CancelToken token) async {
    calls++;
    return pending?.future ?? Future.value(answer);
  }
}

Future<AccountLoginResult> login(RedirectAdapter adapter,
        {bool ex = false, CancelToken? token, AutomaticLoginCheck? check}) =>
    AccountLoginClient(
            createDio: () => Dio()..httpClientAdapter = adapter,
            automaticCheck: check ?? FakeCheck())
        .login(
            username: '  test 用户  ',
            password: ' a&+密  ',
            checkEx: ex,
            cancelToken: token ?? CancelToken());
Matcher failure(AccountLoginFailure reason) => throwsA(
    isA<AccountLoginException>().having((e) => e.reason, 'reason', reason));

void main() {
  tearDown(() {
    NetworkProxy.beforeRequest = null;
    NetworkProxy.setProxy(null);
  });
  test(
      'browser verification precedes every request; one POST keeps its form, UA and token',
      () async {
    final check = FakeCheck()..pending = Completer<BrowserCheckResult>();
    final adapter =
        RedirectAdapter((r, n) => n == 1 ? loggedIn() : body(verified));
    final result = login(adapter, check: check);
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, isEmpty);
    check.pending!.complete(prepared());
    expect((await result).memberId, '123');
    expect(check.calls, 1);
    expect(adapter.requests.map((r) => r.method), ['POST', 'GET']);
    expect(adapter.requests.first.uri.queryParameters['s'], 'test-session');
    expect(adapter.requests.first.headers['User-Agent'], 'native-browser');
    expect(adapter.requests.first.headers['cookie'],
        contains('cf_clearance=test-clearance'));
    expect(adapter.requests.first.headers['cookie'],
        isNot(contains('must-not-import')));
    expect(Uri.splitQueryString(adapter.bodies.first), {
      'referer': 'https://forums.e-hentai.org/',
      'b': '',
      'bt': '',
      'UserName': 'test 用户',
      'PassWord': ' a&+密  ',
      'CookieDate': '1',
      'submit': 'Log me in',
      'cf-turnstile-response': 'automatic-token',
    });
    expect(adapter.requests.every((r) => r.uri.host != 'exhentai.org'), isTrue);
  });
  test('ordinary form widgets and JSD scripts do not claim an interstitial',
      () async {
    final ordinary =
        '$form<div class="cf-turnstile"></div><script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>';
    expect(AccountLoginClient.isChallenge(ordinary), isFalse);
    final adapter = RedirectAdapter(
        (r, n) => n == 1 ? loggedIn() : body('$verified$ordinary'));
    expect((await login(adapter)).memberId, '123');
  });
  for (final status in [
    BrowserCheckStatus.interactive,
    BrowserCheckStatus.unavailable
  ]) {
    test('failed preparation $status sends no credentials', () async {
      final adapter = RedirectAdapter((r, n) => body('must not request'));
      await expectLater(
          login(adapter, check: FakeCheck(answer: BrowserCheckResult(status))),
          failure(status == BrowserCheckStatus.interactive
              ? AccountLoginFailure.challenge
              : AccountLoginFailure.browserRequired));
      expect(adapter.requests, isEmpty);
    });
  }
  for (final status in [200, 403, 503]) {
    test('POST challenge $status never retries credentials or verification',
        () async {
      final check = FakeCheck();
      final adapter = RedirectAdapter((r, n) => body(
          '<title>Just a moment...</title><script>window._cf_chl_opt={}</script>',
          status));
      await expectLater(login(adapter, check: check),
          failure(AccountLoginFailure.browserRequired));
      expect(adapter.requests, hasLength(1));
      expect(check.calls, 1);
    });
  }
  test(
      'incorrect password stays a credentials error even with an embedded widget',
      () async {
    final adapter = RedirectAdapter((r, n) => body(
        'The password you entered is incorrect $form<div class="cf-turnstile"></div>'));
    await expectLater(login(adapter), failure(AccountLoginFailure.credentials));
    expect(adapter.requests, hasLength(1));
  });
  test(
      'partial authentication and anonymous successful responses cannot log in',
      () async {
    final partial = RedirectAdapter((r, n) => loggedIn(partial: true));
    await expectLater(login(partial), failure(AccountLoginFailure.site));
    final anonymous = RedirectAdapter(
        (r, n) => n == 1 ? loggedIn() : body('<html>OK</html>'));
    await expectLater(login(anonymous), failure(AccountLoginFailure.site));
  });
  for (final status in [302, 303]) {
    test('$status redirect carries cookies but never replays the POST body',
        () async {
      final adapter = RedirectAdapter((r, n) => n == 1
          ? loggedIn(location: '/index.php', status: status)
          : body(verified));
      expect((await login(adapter)).memberId, '123');
      expect(adapter.requests.map((r) => r.method), ['POST', 'GET', 'GET']);
      expect(adapter.bodies.skip(1).every((b) => b.isEmpty), isTrue);
      expect(adapter.requests[1].headers['cookie'].toString(),
          contains('test-hash'));
    });
  }
  for (final target in [
    'https://example.com/index.php',
    'http://forums.e-hentai.org/index.php',
    'https://exhentai.org/'
  ]) {
    test('rejects login redirect outside allowlist: $target', () async {
      final adapter = RedirectAdapter((r, n) => loggedIn(location: target));
      await expectLater(login(adapter), failure(AccountLoginFailure.site));
      expect(adapter.requests, hasLength(1));
    });
  }
  for (final code in [307, 308]) {
    test('$code does not replay credentials', () async {
      final adapter = RedirectAdapter(
          (r, n) => loggedIn(location: '/index.php', status: code));
      await expectLater(login(adapter), failure(AccountLoginFailure.site));
      expect(adapter.requests, hasLength(1));
    });
  }
  test('redirect count is bounded', () async {
    final adapter =
        RedirectAdapter((r, n) => ResponseBody.fromString('', 302, headers: {
              'location': ['/index.php']
            }));
    await expectLater(login(adapter), failure(AccountLoginFailure.site));
    expect(adapter.requests, hasLength(6));
    expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
  });
  test('malformed or untrusted prepared forms receive no credentials',
      () async {
    for (final value in [
      form.replaceAll('CODE=01', 'CODE=03'),
      form.replaceAll('forums.e-hentai.org', 'example.com'),
      '<html>Unavailable</html>'
    ]) {
      final adapter = RedirectAdapter((r, n) => body('must not send'));
      await expectLater(
          login(adapter, check: FakeCheck(answer: prepared(html: value))),
          failure(AccountLoginFailure.site));
      expect(adapter.requests, isEmpty);
    }
    final adapter = RedirectAdapter((r, n) => body('must not send'));
    await expectLater(
        login(adapter,
            check: FakeCheck(
                answer: prepared(url: Uri.parse('https://example.com/')))),
        failure(AccountLoginFailure.site));
    expect(adapter.requests, isEmpty);
  });
  test('EX failure preserves verified login', () async {
    final adapter = RedirectAdapter((r, n) => n == 1
        ? loggedIn()
        : n == 2
            ? body(verified)
            : body('Denied', 403));
    final result = await login(adapter, ex: true);
    expect(result.memberId, '123');
    expect(result.exUnavailable, isTrue);
  });
  test('EX success collects igneous with the new account pair', () async {
    final adapter = RedirectAdapter((r, n) => n == 1
        ? loggedIn()
        : n == 2
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
  test('cancellation before proxy preparation sends no request', () async {
    final ready = Completer<void>();
    NetworkProxy.beforeRequest = () => ready.future;
    final token = CancelToken();
    final adapter = RedirectAdapter((r, n) => body('must not request'));
    final result = login(adapter, token: token);
    token.cancel();
    await expectLater(result, throwsA(isA<DioException>()));
    ready.complete();
    expect(adapter.requests, isEmpty);
  });
  test('late browser readiness cannot resume a cancelled login', () async {
    final check = FakeCheck()..pending = Completer<BrowserCheckResult>();
    final token = CancelToken();
    final adapter = RedirectAdapter((r, n) => body('must not request'));
    final result = login(adapter, check: check, token: token);
    final assertion = expectLater(result, throwsA(isA<DioException>()));
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    check.pending!.complete(prepared());
    await assertion;
    expect(adapter.requests, isEmpty);
  });
  test('proxy changes during browser preparation invalidate the result',
      () async {
    final check = FakeCheck()..pending = Completer<BrowserCheckResult>();
    final adapter = RedirectAdapter((r, n) => body('must not request'));
    final result = login(adapter, check: check);
    final assertion = expectLater(result, failure(AccountLoginFailure.network));
    await Future<void>.delayed(Duration.zero);
    NetworkProxy.setProxy('http://127.0.0.1:7890');
    check.pending!.complete(prepared());
    await assertion;
    expect(adapter.requests, isEmpty);
  });
  test('network errors do not expose credential-bearing diagnostics', () async {
    final adapter = RedirectAdapter((r, n) => throw DioException(
        requestOptions: r, type: DioExceptionType.connectionTimeout));
    await expectLater(login(adapter), failure(AccountLoginFailure.network));
    expect(const AccountLoginResult('123', 'secret').toString(),
        isNot(contains('secret')));
  });
}
