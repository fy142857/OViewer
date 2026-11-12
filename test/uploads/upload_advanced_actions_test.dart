// Contract scenarios for published operations. These are not captured
// publication/disown/clone responses and do not contact a real account.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/features/uploads/data/upload_advanced_actions.dart';
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';

class _Session extends app.CookieManager {
  int revision = 1;
  @override
  int get sessionRevision => revision;
  @override
  Future<bool> hasLoginCookies() async => true;
  @override
  Future<String?> getMemberId() async => '101';
  @override
  void configureDio(Dio dio) {}
}

class _Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) reply;
  final requests = <RequestOptions>[];
  _Adapter(this.reply);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final editorUri = uploadOrigin.resolve('managegallery?ulgid=12345');
  final publicUri = Uri.parse('https://e-hentai.org/g/99999/abcde12345/');
  String fixture(String name) =>
      File('test/fixtures/uploads/$name.html').readAsStringSync();
  ResponseBody page(String body) => ResponseBody.fromString(body, 200);
  String published({String? operation, String? statsId}) {
    final doc = html.parse(fixture('uploaded'));
    for (final row in doc.querySelectorAll('td#d tr')) {
      final label = row.querySelector('td.k')?.text;
      if (label == 'Date Posted:') {
        row.querySelector('td.v')!.text = '2026-11-12 12:00';
      }
      if (label == 'Visible:') row.querySelector('td.v')!.text = 'Yes';
    }
    doc.querySelector('#publishbutton')!.attributes['disabled'] = 'disabled';
    doc.querySelector('td#d')!.append(Element.tag('a')
      ..attributes['href'] = publicUri.toString()
      ..text = 'Show Public Gallery');
    if (operation != null) {
      doc.querySelector('td#d')!.append(Element.tag('a')
        ..attributes['href'] = '$editorUri&act=$operation'
        ..text = '$operation Gallery');
    }
    if (statsId != null) {
      doc.querySelector('td#d')!.append(Element.tag('a')
        ..attributes['href'] = '#'
        ..attributes['onclick'] =
            "popUp('https://e-hentai.org/stats.php?gid=$statsId&token=abcde12345',600,600)"
        ..text = 'Show Gallery Stats');
    }
    return doc.documentElement!.outerHtml;
  }

  ({
    UploadAdvancedActions actions,
    UploadHttpClient client,
    _Adapter adapter,
    _Session session
  }) make(FutureOr<ResponseBody> Function(RequestOptions) reply) {
    final adapter = _Adapter(reply);
    final session = _Session();
    final client = UploadHttpClient(session, adapter: adapter);
    addTearDown(client.dispose);
    return (
      actions: UploadAdvancedActions(UploadRepository(client)),
      client: client,
      adapter: adapter,
      session: session
    );
  }

  test('observed publish control is prepared but a normal GET cannot invoke it',
      () async {
    final f = make((_) => page(fixture('uploaded')));
    final action =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.publish);
    expect(action.actionUri.queryParameters['act'], 'publish');
    expect(action.actionUri.queryParameters['from'], 'gallery');
    await expectLater(
        f.client.get(action.actionUri), throwsA(isA<UploadFailure>()));
    expect(f.adapter.requests, hasLength(1));
    await expectLater(f.actions.perform('101', action, confirmed: false),
        throwsArgumentError);
    expect(f.adapter.requests, hasLength(1));
  });

  test('changed gallery after review prevents the mutation', () async {
    var reads = 0;
    final f = make((_) => page(++reads == 1
        ? fixture('uploaded')
        : fixture('uploaded')
            .replaceAll('Fixture upload verification', 'Changed gallery')));
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.publish);
    await expectLater(
        f.actions.perform('101', prepared, confirmed: true),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.restricted)));
    expect(
        f.adapter.requests.every((r) => r.uri.queryParameters['act'] == null),
        isTrue);
  });

  test('publication is confirmed from fresh owner state, not redirect alone',
      () async {
    var sent = false;
    final f = make((request) {
      if (request.uri.queryParameters['act'] == 'publish') {
        sent = true;
        return ResponseBody.fromString('', 302, headers: {
          'location': [publicUri.toString()]
        });
      }
      return page(sent ? published() : fixture('uploaded'));
    });
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.publish);
    final result = await f.actions.perform('101', prepared, confirmed: true);
    expect(result.publicUri, publicUri);
    expect(result.editor!.uri, editorUri);
    expect(
        f.adapter.requests
            .where((r) => r.uri.queryParameters['act'] == 'publish'),
        hasLength(1));
    expect(f.adapter.requests.every((r) => r.uri.host == uploadOrigin.host),
        isTrue);
  });

  test('unconfirmed publication never silently reports success', () async {
    final f = make((_) => page(fixture('uploaded')));
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.publish);
    await expectLater(
        f.actions.perform('101', prepared, confirmed: true),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(
        f.adapter.requests
            .where((r) => r.uri.queryParameters['act'] == 'publish'),
        hasLength(1));
  });

  test(
      'published public gallery cannot be deleted even with a malformed delete link',
      () async {
    final f = make((_) => page(published()));
    await expectLater(
        f.actions.prepare('101', editorUri, UploadGalleryAction.delete),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.restricted)));
    expect(f.adapter.requests, hasLength(1));
  });

  test('delete is confirmed only after target disappears from owner manager',
      () async {
    final f = make((request) => page(request.uri.path == '/manage'
        ? fixture('manage')
        : request.uri.queryParameters['act'] == 'delete'
            ? '<p id="e">Gallery deleted.</p>'
            : fixture('uploaded')));
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
    final result = await f.actions.perform('101', prepared, confirmed: true);
    expect(result.kind, UploadGalleryAction.delete);
    expect(result.manager!.galleries, isEmpty);
    expect(
        f.adapter.requests
            .where((r) => r.uri.queryParameters['act'] == 'delete'),
        hasLength(1));
  });

  test(
      'captured delete confirmation submits only qa_delete once and verifies disappearance',
      () async {
    var deleted = false;
    final f = make((request) {
      if (request.method == 'POST') {
        expect(request.data, 'qa_delete=Delete');
        deleted = true;
        return page('<p>Deleted</p>');
      }
      if (request.uri.path == '/manage') {
        return page(deleted ? fixture('manage') : fixture('populated-manager'));
      }
      return page(request.uri.queryParameters['act'] == 'delete'
          ? fixture('delete-confirmation')
          : fixture('uploaded'));
    });
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
    final result = await f.actions.perform('101', prepared, confirmed: true);
    expect(result.kind, UploadGalleryAction.delete);
    expect(result.manager!.galleries, isEmpty);
    final post = f.adapter.requests.where((r) => r.method == 'POST').single;
    expect(post.uri.queryParameters, {'act': 'delete', 'ulgid': '12345'});
    expect(post.data.toString(), isNot(contains('qa_cancel')));
    expect(
        f.adapter.requests
            .where((r) => r.method == 'GET' && r.uri == editorUri),
        hasLength(3));
  });

  for (final invalid in [
    'target',
    'title',
    'action',
    'unknown control',
    'disabled delete',
    'unknown wording'
  ]) {
    test('delete follow-up refuses $invalid before sending its POST', () async {
      final doc = html.parse(fixture('delete-confirmation'));
      switch (invalid) {
        case 'target':
          doc.querySelector('form')!.attributes['action'] =
              '${uploadOrigin}managegallery?act=delete&ulgid=54321';
        case 'title':
          doc.querySelector('strong')!.text = 'Different gallery';
        case 'action':
          doc.querySelector('form')!.attributes['action'] =
              '$editorUri&act=disown';
        case 'unknown control':
          doc.querySelector('form')!.append(Element.tag('input')
            ..attributes
                .addAll({'type': 'hidden', 'name': 'unknown', 'value': '1'}));
        case 'disabled delete':
          doc.querySelector('[name="qa_delete"]')!.attributes['disabled'] =
              'disabled';
        case 'unknown wording':
          doc
              .querySelector('div.d')!
              .nodes
              .insert(0, Element.tag('p')..text = 'Unrecognized operation');
          for (final p in doc.querySelectorAll('p')) {
            if (p.text.contains('Please confirm that you wish to delete')) {
              p.remove();
            }
          }
      }
      final f = make((request) => page(
          request.uri.queryParameters['act'] == 'delete'
              ? doc.outerHtml
              : fixture('uploaded')));
      final prepared =
          await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
      await expectLater(
          f.actions.perform('101', prepared, confirmed: true),
          throwsA(isA<UploadFailure>().having(
              (e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
      expect(f.adapter.requests.where((r) => r.method == 'POST'), isEmpty);
    });
  }

  for (final changed in ['title', 'account', 'gallery identity']) {
    test(
        'delete rechecks $changed after the confirmation GET and never posts changed state',
        () async {
      var reads = 0;
      final f = make((request) {
        if (request.uri.queryParameters['act'] == 'delete') {
          return page(fixture('delete-confirmation'));
        }
        var body = fixture('uploaded');
        if (++reads == 3) {
          body = switch (changed) {
            'title' =>
              body.replaceAll('Fixture upload verification', 'Changed title'),
            'account' => body.replaceFirst(
                RegExp(r'var apiuid\s*=\s*101'), 'var apiuid = 202'),
            _ => body.replaceAll('12345', '54321'),
          };
        }
        return page(body);
      });
      final prepared =
          await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
      await expectLater(
          f.actions.perform('101', prepared, confirmed: true),
          throwsA(isA<UploadFailure>().having(
              (e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
      expect(reads, 3);
      expect(f.adapter.requests.where((r) => r.method == 'POST'), isEmpty);
    });
  }

  test('delete confirmation POST timeout is uncertain and is never replayed',
      () async {
    final f = make((request) {
      if (request.method == 'POST') {
        throw DioException(
            requestOptions: request, type: DioExceptionType.receiveTimeout);
      }
      return page(request.uri.queryParameters['act'] == 'delete'
          ? fixture('delete-confirmation')
          : fixture('uploaded'));
    });
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
    await expectLater(
        f.actions.perform('101', prepared, confirmed: true),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(f.adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  test('a repeated confirmation response never triggers a second delete POST',
      () async {
    final f = make((request) => page(request.uri.path == '/manage'
        ? fixture('populated-manager')
        : request.uri.queryParameters['act'] == 'delete'
            ? fixture('delete-confirmation')
            : fixture('uploaded')));
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
    await expectLater(
        f.actions.perform('101', prepared, confirmed: true),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(f.adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  test('a surviving target in the manager keeps the delete result uncertain',
      () async {
    final f = make((request) => page(request.uri.path == '/manage'
        ? fixture('populated-manager')
        : fixture('uploaded')));
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
    await expectLater(
        f.actions.perform('101', prepared, confirmed: true),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(
        f.adapter.requests
            .where((r) => r.uri.queryParameters['act'] == 'delete'),
        hasLength(1));
  });

  // Synthetic collapsed-folder replies exercise complete-list verification;
  // none of these delete/disown responses were obtained by live mutations.
  String collapsedManager(int? count) {
    final doc = html.parse(fixture('populated-manager'));
    doc.querySelector('#ft_u_1')!.text = '[+]';
    final total = doc.querySelector('#frow_u_1 strong')!;
    if (count == null) {
      total.remove();
    } else {
      total.text = '$count';
    }
    for (final cell in doc.querySelectorAll('td.gtc1')) {
      cell.parent!.remove();
    }
    return doc.outerHtml;
  }

  String folderResponse(List<String> ids) {
    final doc = html.parse(fixture('populated-manager'));
    final row = doc.querySelector('td.gtc1')!.parent!;
    return jsonEncode({
      'state': 'u',
      'fid': 1,
      'rows': [
        for (final id in ids)
          {
            for (var column = 1; column <= 6; column++)
              'c$column': row
                  .querySelector('td.gtc$column')!
                  .innerHtml
                  .replaceAll('12345', id)
          }
      ],
    });
  }

  test(
      'a successful-looking delete POST cannot bypass incomplete collapsed-folder verification',
      () async {
    final f = make((request) {
      if (request.uri.path == '/manage') return page(collapsedManager(1));
      if (request.uri.path == '/api') return page(folderResponse([]));
      if (request.method == 'POST') return page('<p>Deleted</p>');
      return page(request.uri.queryParameters['act'] == 'delete'
          ? fixture('delete-confirmation')
          : fixture('uploaded'));
    });
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.delete);
    await expectLater(
        f.actions.perform('101', prepared, confirmed: true),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
    expect(
        f.adapter.requests
            .where((r) => r.method == 'POST' && r.uri.path == '/managegallery'),
        hasLength(1));
  });

  for (final action in [
    UploadGalleryAction.delete,
    UploadGalleryAction.disown
  ]) {
    for (final scenario in [
      (label: 'empty rows for a nonempty folder', count: 1, ids: <String>[]),
      (label: 'missing declared folder count', count: null, ids: <String>[]),
      (label: 'partial nonempty folder rows', count: 2, ids: <String>['23456']),
      (
        label: 'complete count with a surviving target',
        count: 1,
        ids: <String>['12345']
      ),
    ]) {
      test('${action.name} remains uncertain with ${scenario.label}', () async {
        final f = make((request) {
          if (request.uri.path == '/manage') {
            return page(collapsedManager(scenario.count));
          }
          if (request.uri.path == '/api') {
            return page(folderResponse(scenario.ids));
          }
          if (request.uri.queryParameters['act'] == action.name) {
            return page('<p>Request processed</p>');
          }
          return page(action == UploadGalleryAction.delete
              ? fixture('uploaded')
              : published(operation: 'disown'));
        });
        final prepared = await f.actions.prepare('101', editorUri, action);
        await expectLater(
            f.actions.perform('101', prepared, confirmed: true),
            throwsA(isA<UploadFailure>().having(
                (e) => e.kind, 'kind', UploadFailureKind.resultUncertain)));
        expect(
            f.adapter.requests
                .where((r) => r.uri.queryParameters['act'] == action.name),
            hasLength(1));
        expect(f.adapter.requests.where((r) => r.uri.path == '/api'),
            hasLength(1));
      });
    }
    test(
        '${action.name} accepts complete collapsed rows only when the target is absent',
        () async {
      final f = make((request) {
        if (request.uri.path == '/manage') return page(collapsedManager(1));
        if (request.uri.path == '/api') return page(folderResponse(['23456']));
        if (request.uri.queryParameters['act'] == action.name) {
          return page('<p>Request processed</p>');
        }
        return page(action == UploadGalleryAction.delete
            ? fixture('uploaded')
            : published(operation: 'disown'));
      });
      final prepared = await f.actions.prepare('101', editorUri, action);
      final result = await f.actions.perform('101', prepared, confirmed: true);
      expect(result.kind, action);
      expect(
          f.adapter.requests
              .where((r) => r.uri.queryParameters['act'] == action.name),
          hasLength(1));
      expect(
          f.adapter.requests.where((r) => r.uri.path == '/api'), hasLength(1));
    });
  }

  test(
      'disown preserves the public link and never promises immediate name removal',
      () async {
    final f = make((request) => page(request.uri.path == '/manage'
        ? fixture('manage')
        : request.uri.queryParameters['act'] == 'disown'
            ? '<p>Done</p>'
            : published(operation: 'disown')));
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.disown);
    final result = await f.actions.perform('101', prepared, confirmed: true);
    expect(result.kind, UploadGalleryAction.disown);
    expect(result.publicUri, publicUri);
    expect(result.editor, isNull);
  });

  test(
      'clone uses only an advertised unlock control and requires parent evidence',
      () async {
    final parent = html.parse(published());
    parent.querySelector('#uploadbutton')!.remove();
    parent.querySelector('td#d')!.append(Element.tag('input')
      ..id = 'unlockbutton'
      ..attributes['type'] = 'button'
      ..attributes['value'] = 'Unlock Gallery'
      ..attributes['onclick'] =
          "document.location='$editorUri&act=unlock'; return false");
    final child = html.parse(fixture('uploaded'));
    child.querySelector('#uploadform')!.attributes['action'] =
        '${uploadOrigin}managegallery?ulgid=23456';
    for (final row in child.querySelectorAll('td#d tr')) {
      if (row.querySelector('td.k')?.text == 'Parent Gallery:') {
        row.querySelector('td.v')!.nodes.clear();
        row.querySelector('td.v')!.append(Element.tag('a')
          ..attributes['href'] = publicUri.toString()
          ..text = 'Parent');
      }
    }
    final f = make((request) => page(
        request.uri.queryParameters['act'] == 'unlock'
            ? child.documentElement!.outerHtml
            : parent.documentElement!.outerHtml));
    final prepared =
        await f.actions.prepare('101', editorUri, UploadGalleryAction.clone);
    final result = await f.actions.perform('101', prepared, confirmed: true);
    expect(result.editor!.uri.queryParameters['ulgid'], '23456');
    expect(result.kind, UploadGalleryAction.clone);
  });

  test('statistics stays within the owner-linked gallery and renders text only',
      () async {
    final f = make((request) => page(request.uri.path == '/stats.php'
        ? '<h1>Statistics</h1><table><tr><th>Visits</th><th>Hits</th></tr><tr><td>3</td><td>4</td></tr></table><script>do_not_execute()</script>'
        : published(statsId: '99999')));
    final result = await f.actions.stats('101', editorUri);
    expect(result.tables.single.last, ['3', '4']);
    expect(result.notes.join(), isNot(contains('do_not_execute')));
    expect(f.adapter.requests, hasLength(2));
  });

  test(
      'statistics link for a different public gallery is rejected before sending',
      () async {
    final f = make((_) => page(published(statsId: '88888')));
    await expectLater(
        f.actions.stats('101', editorUri), throwsA(isA<UploadFailure>()));
    expect(f.adapter.requests, hasLength(1));
  });
}
