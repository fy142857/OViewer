import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/constants/app_constants.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/core/network/dio_client.dart';

class MockCookies extends Mock implements app.CookieManager {}

class FakeDio extends Fake implements Dio {}

class RedirectAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions, int) respond;
  final requests = <RequestOptions>[];
  final bodies = <String>[];
  RedirectAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    final bytes =
        await stream?.fold<List<int>>([], (all, part) => all..addAll(part));
    bodies.add(bytes == null ? '' : utf8.decode(bytes));
    return respond(options, requests.length);
  }

  @override
  void close({bool force = false}) {}
}

DioClient client(RedirectAdapter adapter) {
  final cookies = MockCookies();
  when(() => cookies.configureDio(any())).thenAnswer((call) {
    final dio = call.positionalArguments.single as Dio;
    dio.httpClientAdapter = adapter;
    // Represents the same-site authenticated cookie interceptor.
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['Cookie'] = 'test-session=local-only';
      handler.next(options);
    }));
  });
  return DioClient(cookies);
}

void main() {
  setUpAll(() => registerFallbackValue(FakeDio()));
  tearDown(() => AppConstants.useExHentai = false);
  for (final ex in [false, true]) {
    for (final status in [302, 303]) {
      test(
          '$status comment response switches POST to GET on ${ex ? "EX" : "EH"}',
          () async {
        AppConstants.useExHentai = ex;
        final root = AppConstants.baseUrl;
        final adapter = RedirectAdapter((options, n) => n == 1
            ? ResponseBody.fromString('', status, headers: {
                'location': ['/g/10/abc/#c42']
              })
            : ResponseBody.fromString('posted', 200));
        final result = await client(adapter).post('$root/g/10/abc/?hc=1',
            data: {'commenttext_new': 'hello & 你好'},
            contentType: Headers.formUrlEncodedContentType,
            followPostRedirects: true);
        expect(result, 'posted');
        expect(adapter.requests.map((r) => r.method), ['POST', 'GET']);
        expect(adapter.requests.last.uri.toString(), '$root/g/10/abc/?hc=1');
        expect(
            adapter.requests.last.headers['Cookie'], 'test-session=local-only');
        expect(Uri.splitQueryString(adapter.bodies.first)['commenttext_new'],
            'hello & 你好');
        expect(adapter.bodies.last, isEmpty);
      });
    }
  }
  test('redirect chains never replay a comment and are bounded', () async {
    final adapter = RedirectAdapter(
        (options, n) => ResponseBody.fromString('', 302, headers: {
              'location': ['?hc=1']
            }));
    await expectLater(
        client(adapter).post('https://e-hentai.org/g/10/abc/',
            data: {'commenttext_new': 'once'}, followPostRedirects: true),
        throwsException);
    expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
    expect(adapter.requests, hasLength(6));
  });
  for (final location in [
    'https://example.test/steal',
    '/g/11/other/',
    '/index.php?act=Login',
    'http://e-hentai.org/g/10/abc/',
    'https://exhentai.org/g/10/abc/'
  ]) {
    test('does not follow untrusted or unrelated redirect $location', () async {
      final adapter = RedirectAdapter(
          (options, n) => ResponseBody.fromString('', 302, headers: {
                'location': [location]
              }));
      await expectLater(
          client(adapter).post('https://e-hentai.org/g/10/abc/',
              followPostRedirects: true),
          throwsException);
      expect(adapter.requests, hasLength(1));
    });
  }
  test('a 302 without Location is not considered success', () async {
    final adapter =
        RedirectAdapter((options, n) => ResponseBody.fromString('', 302));
    await expectLater(
        client(adapter)
            .post('https://e-hentai.org/g/10/abc/', followPostRedirects: true),
        throwsException);
    expect(adapter.requests, hasLength(1));
  });
}
