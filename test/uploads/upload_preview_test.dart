import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';

class Session extends app.CookieManager {
  int revision = 1;
  @override
  int get sessionRevision => revision;
  @override
  Future<bool> hasLoginCookies() async => true;
  @override
  void configureDio(Dio dio) {
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['Cookie'] = 'site-auth-cookie';
      handler.next(options);
    }));
  }
}

class Adapter implements HttpClientAdapter {
  FutureOr<ResponseBody> Function(RequestOptions) response;
  final calls = <RequestOptions>[];
  Adapter(this.response);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    return await response(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  tearDown(() => NetworkProxy.beforeRequest = null);
  final uri =
      Uri.parse('https://example.hath.network/signed-image?token=fixture-only');

  test('signed images never receive gallery cookies and retain request bounds',
      () async {
    final images = Adapter((_) => ResponseBody.fromBytes([1, 2, 3], 200,
        headers: {
          'content-type': ['image/png']
        }));
    final client = UploadHttpClient(Session(), imageAdapter: images);
    addTearDown(client.dispose);
    expect(await client.readImage(uri), [1, 2, 3]);
    final request = images.calls.single;
    expect(request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')));
    expect(request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')));
    expect(request.followRedirects, isFalse);
    expect(request.headers['User-Agent'], contains('Mozilla'));
  });

  test(
      'image destinations must be HTTPS observed CDN hosts without userinfo or extra ports',
      () async {
    final images = Adapter((_) => throw StateError('Must not send'));
    final client = UploadHttpClient(Session(), imageAdapter: images);
    addTearDown(client.dispose);
    for (final value in [
      'http://example.hath.network/image',
      'https://example.hath.network:8443/image',
      'https://user@example.hath.network/image',
      'https://example.hath.network.evil.invalid/image',
      'https://e-hentai.org/image',
    ]) {
      await expectLater(
          client.readImage(Uri.parse(value)), throwsA(isA<UploadFailure>()));
    }
    expect(images.calls, isEmpty);
  });

  test('CDN redirects are refused rather than followed with the signed URL',
      () async {
    final images = Adapter((_) => ResponseBody.fromString('', 302, headers: {
          'location': ['https://other.invalid/image']
        }));
    final client = UploadHttpClient(Session(), imageAdapter: images);
    addTearDown(client.dispose);
    await expectLater(client.readImage(uri), throwsA(isA<UploadFailure>()));
    expect(images.calls, hasLength(1));
  });

  test('declared and streamed image sizes are bounded', () async {
    var cancelled = false;
    final body = StreamController<Uint8List>(onCancel: () => cancelled = true);
    final images = Adapter((_) => ResponseBody(body.stream, 200, headers: {
          'content-length': ['50000001'],
          'content-type': ['image/png']
        }));
    final client = UploadHttpClient(Session(), imageAdapter: images);
    addTearDown(client.dispose);
    await expectLater(
        client.readImage(uri),
        throwsA(isA<UploadFailure>().having(
            (error) => error.kind, 'kind', UploadFailureKind.restricted)));
    expect(cancelled, isTrue);
    await body.close();
    images.response = (_) => ResponseBody(
            Stream.fromIterable([
              Uint8List(25000000),
              Uint8List(25000001),
            ]),
            200,
            headers: {
              'content-type': ['image/png']
            });
    await expectLater(
        client.readImage(uri),
        throwsA(isA<UploadFailure>().having(
            (error) => error.kind, 'kind', UploadFailureKind.restricted)));
  });

  test('logout during image streaming cannot return old-account bytes',
      () async {
    final session = Session();
    final started = Completer<void>();
    final body =
        StreamController<Uint8List>(onListen: () => started.complete());
    final images = Adapter((_) => ResponseBody(body.stream, 200));
    final client = UploadHttpClient(session, imageAdapter: images);
    addTearDown(client.dispose);
    final read = client.readImage(uri);
    final check = expectLater(
        read,
        throwsA(isA<UploadFailure>().having(
            (error) => error.kind, 'kind', UploadFailureKind.sessionChanged)));
    await started.future;
    body.add(Uint8List.fromList([1]));
    session.revision++;
    body.add(Uint8List.fromList([2]));
    await check;
    await body.close();
  });

  test(
      'cancelling a silent image stream completes without waiting for more bytes',
      () async {
    var cancelled = false;
    final started = Completer<void>();
    final body = StreamController<Uint8List>(
        onListen: () => started.complete(), onCancel: () => cancelled = true);
    final images = Adapter((_) => ResponseBody(body.stream, 200));
    final client = UploadHttpClient(Session(), imageAdapter: images);
    addTearDown(client.dispose);
    final token = CancelToken();
    final check = expectLater(
        client.readImage(uri, cancelToken: token),
        throwsA(isA<UploadFailure>().having(
            (error) => error.kind, 'kind', UploadFailureKind.sessionChanged)));
    await started.future;
    token.cancel();
    await check;
    expect(cancelled, isTrue);
    await body.close();
  });

  test(
      'viewimage API uses the same user agent with observed origin and editor referer',
      () async {
    final controls = Adapter((_) =>
        ResponseBody.fromString('{"url":"https://ehgt.org/image"}', 200));
    final client = UploadHttpClient(Session(), adapter: controls);
    addTearDown(client.dispose);
    final editor = uploadOrigin.resolve('managegallery?ulgid=12345');
    await client.readApi(const UploadApiSession(101, 'fixture-key'),
        'viewimage', {'ulgid': 12345, 'page': 1, 'fileindex': 123},
        referer: editor);
    final request = controls.calls.single;
    expect(request.headers['Origin'], 'https://upld.e-hentai.org');
    expect(request.headers['Referer'], editor.toString());
    expect(request.headers['User-Agent'], contains('Mozilla'));
  });
}
