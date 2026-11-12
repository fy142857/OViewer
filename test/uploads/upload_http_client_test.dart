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
  bool loggedIn = true;
  @override
  int get sessionRevision => revision;
  @override
  Future<bool> hasLoginCookies() async => loggedIn;
  @override
  void configureDio(Dio dio) {}
}

class Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  final calls = <RequestOptions>[];
  Adapter(this.handler);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    if (requestStream != null) await requestStream.drain<void>();
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  tearDown(() => NetworkProxy.beforeRequest = null);
  final uri = uploadOrigin.resolve('manage');
  final form = UploadForm(action: uri, fields: const {
    'fname': UploadField(name: 'fname', type: 'text', values: ['']),
    'do_save': UploadField(name: 'do_save', type: 'hidden', values: ['1']),
  });

  test('read-only gallery requests reject mutation actions including redirects',
      () async {
    final adapter = Adapter((_) => ResponseBody.fromString('unused', 200));
    final client = UploadHttpClient(Session(), adapter: adapter);
    addTearDown(client.dispose);
    for (final action in [
      'publish',
      'delete',
      'disown',
      'unlock',
      'new&act=delete'
    ]) {
      await expectLater(
          client.get(
              uploadOrigin.resolve('managegallery?ulgid=12345&act=$action')),
          throwsA(isA<UploadFailure>()));
    }
    expect(adapter.calls, isEmpty);
    final redirect = Adapter((_) => ResponseBody.fromString('', 302, headers: {
          'location': ['/managegallery?ulgid=12345&act=delete'],
        }));
    final redirectedClient = UploadHttpClient(Session(), adapter: redirect);
    addTearDown(redirectedClient.dispose);
    await expectLater(
        redirectedClient.get(uploadOrigin.resolve('managegallery?ulgid=12345')),
        throwsA(isA<UploadFailure>()));
    expect(redirect.calls, hasLength(1));
  });

  test('redirect after a write is GET and never replays the body', () async {
    final adapter = Adapter((options) => options.method == 'POST'
        ? ResponseBody.fromString('', 303, headers: {
            'location': ['/manage']
          })
        : ResponseBody.fromString('saved', 200));
    final client = UploadHttpClient(Session(), adapter: adapter);
    addTearDown(client.dispose);
    final response = await client.postForm(form, {
      'fname': ['A & B']
    });
    expect(response.body, 'saved');
    expect(adapter.calls.map((c) => c.method), ['POST', 'GET']);
    expect(adapter.calls.first.data, 'fname=A+%26+B&do_save=1');
    expect(adapter.calls.last.data, isNull);
  });

  test('cross-origin redirects and 307 mutations are never followed', () async {
    for (final destination in ['https://example.invalid/steal', '/manage']) {
      final adapter = Adapter((_) => ResponseBody.fromString('', 307, headers: {
            'location': [destination]
          }));
      final client = UploadHttpClient(Session(), adapter: adapter);
      await expectLater(
          client.postForm(form, {
            'fname': ['folder']
          }),
          throwsA(isA<UploadFailure>()));
      expect(adapter.calls, hasLength(1));
      client.dispose();
    }
  });

  test('logout while request is pending cannot return an old account result',
      () async {
    final started = Completer<void>();
    final reply = Completer<ResponseBody>();
    final session = Session();
    final adapter = Adapter((_) {
      started.complete();
      return reply.future;
    });
    final client = UploadHttpClient(session, adapter: adapter);
    addTearDown(client.dispose);
    final request = client.get(uri);
    final assertion = expectLater(
        request,
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.sessionChanged)));
    await started.future;
    session.revision++;
    reply.complete(ResponseBody.fromString('old account', 200));
    await assertion;
  });

  test('unknown mutation outcome is not automatically retried', () async {
    final adapter = Adapter((options) => throw DioException(
        requestOptions: options, type: DioExceptionType.receiveTimeout));
    final client = UploadHttpClient(Session(), adapter: adapter);
    addTearDown(client.dispose);
    await expectLater(
        client.postForm(form, {
          'fname': ['folder']
        }),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(adapter.calls, hasLength(1));
  });

  test('selected delete submitter posts once and a 303 only reads the manager',
      () async {
    final target = uploadOrigin.resolve('managegallery?act=delete&ulgid=12345');
    final delete = UploadForm(action: target, fields: const {
      'qa_delete':
          UploadField(name: 'qa_delete', type: 'hidden', values: ['Delete']),
    });
    final adapter = Adapter((request) => request.method == 'POST'
        ? ResponseBody.fromString('', 303, headers: {
            'location': ['/manage']
          })
        : ResponseBody.fromString('manager', 200));
    final client = UploadHttpClient(Session(), adapter: adapter);
    addTearDown(client.dispose);
    final response = await client.postForm(delete, const {});
    expect(response.uri, uri);
    expect(adapter.calls.map((r) => r.method), ['POST', 'GET']);
    expect(adapter.calls.first.data, 'qa_delete=Delete');
    expect(adapter.calls.last.data, isNull);
  });

  test('delete submitter is not replayed or followed back to a mutating GET',
      () async {
    for (final status in [303, 307]) {
      final target =
          uploadOrigin.resolve('managegallery?act=delete&ulgid=12345');
      final delete = UploadForm(action: target, fields: const {
        'qa_delete':
            UploadField(name: 'qa_delete', type: 'hidden', values: ['Delete']),
      });
      final adapter =
          Adapter((_) => ResponseBody.fromString('', status, headers: {
                'location': [target.toString()]
              }));
      final client = UploadHttpClient(Session(), adapter: adapter);
      try {
        await expectLater(
            client.postForm(delete, const {}), throwsA(isA<UploadFailure>()));
        expect(adapter.calls, hasLength(1));
        expect(adapter.calls.single.method, 'POST');
      } finally {
        client.dispose();
      }
    }
  });

  test('login required and invalid endpoints never transmit a request',
      () async {
    final adapter = Adapter((_) => ResponseBody.fromString('', 200));
    final session = Session()..loggedIn = false;
    final client = UploadHttpClient(session, adapter: adapter);
    addTearDown(client.dispose);
    await expectLater(client.get(uri), throwsA(isA<UploadFailure>()));
    session.loggedIn = true;
    await expectLater(client.get(Uri.https('example.org', '/manage')),
        throwsA(isA<UploadFailure>()));
    await expectLater(client.get(uploadOrigin.resolve('unexpected')),
        throwsA(isA<UploadFailure>()));
    expect(adapter.calls, isEmpty);
  });

  test('API login/error/invalid replies do not masquerade as successful rows',
      () async {
    for (final body in ['{"login":true}', '{"error":"Wait"}', 'not-json']) {
      final adapter = Adapter((_) => ResponseBody.fromString(body, 200));
      final client = UploadHttpClient(Session(), adapter: adapter);
      await expectLater(
          client.readApi(const UploadApiSession(101, 'key'), 'managefolders',
              {'state': 0, 'fid': 0, 'ss': 'd', 'sd': 'a'}),
          throwsA(isA<UploadFailure>()));
      client.dispose();
    }
  });
}
