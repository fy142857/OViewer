import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';

void main() {
  const protocol = UploadProtocol();
  String fixture(String name) =>
      File('test/fixtures/uploads/$name.html').readAsStringSync();
  final newUri = uploadOrigin.resolve('managegallery?act=new');

  test('observed empty manager is a valid authenticated empty list', () {
    final snapshot = protocol.manager(fixture('manage'));
    expect(snapshot.galleries, isEmpty);
    expect(snapshot.folders, isEmpty);
    expect(snapshot.form.action, uploadOrigin.resolve('manage'));
    expect(snapshot.api.uid, 101);
    expect(snapshot.sort, 'd');
  });

  test(
      'captured folder pages parse without invented API credentials and remain unbound',
      () {
    for (final name in ['folders', 'populated-folders']) {
      final source = fixture(name);
      expect(source, isNot(contains('apiuid')));
      expect(source, isNot(contains('apikey')));
      final folders = protocol.folders(source);
      expect(folders.accountId, isNull);
      expect(folders.sessionRevision, isNull);
      expect(folders.form.action, uploadOrigin.resolve('managefolders'));
    }
    expect(protocol.folders(fixture('populated-folders')).folders.single.name,
        'Fixture upload verification');
  });

  test(
      'folder parser change does not relax owner identity required by manager or editor',
      () {
    String withoutApi(String name) =>
        fixture(name).replaceAll(RegExp(r'\bvar\s+apiuid\s*=\s*\d+\s*;'), '');
    expect(() => protocol.manager(withoutApi('manage')),
        throwsA(isA<UploadFailure>()));
    expect(() => protocol.editor(withoutApi('new'), newUri),
        throwsA(isA<UploadFailure>()));
  });

  test('observed new form preserves upload-specific values and restrictions',
      () {
    final snapshot = protocol.editor(fixture('new'), newUri);
    expect(snapshot.isNew, isTrue);
    expect(snapshot.form.multipart, isTrue);
    expect(snapshot.form.fields['gname_en']!.maxLength, 500);
    expect(snapshot.form.fields['category']!.options.map((o) => o.value),
        ['2', '3', '4', '5', '10', '9', '6', '7', '1', '0']);
    expect(snapshot.form.fields['langtype']!.options.map((o) => o.value),
        ['0', '1', '2']);
    expect(snapshot.form.fields['tos']!.values, isEmpty);
    expect(snapshot.form.fields['MAX_FILE_SIZE']!.value, '1258291200');
    expect(snapshot.form.fields['do_save']!.value, '1');
    expect(snapshot.canUpload, isTrue);
    expect(snapshot.canPublish, isFalse);
    expect(snapshot.buttons['publishbutton']!.reason, contains('empty'));
    expect(snapshot.metadata['Date Added'], 'Not created yet');
    expect(snapshot.images, isEmpty);
  });

  test(
      'form submission preserves hidden controls but excludes buttons and files',
      () {
    final form = protocol.editor(fixture('new'), newUri).form;
    final result = form.submission({
      'gname_en': ['Example'],
      'category': ['9'],
      'langtag': ['0'],
      'langtype': ['0'],
      'tos': ['on'],
      'aigen': [],
    });
    expect(result['do_save'], ['1']);
    expect(result['PHP_SESSION_UPLOAD_PROGRESS'], ['fixture-progress']);
    expect(result['tos'], ['on']);
    expect(result['files[]'], isNull);
    expect(result['aigen'], isEmpty);
    expect(
        () => form.submission({
              'do_save': ['99']
            }),
        throwsA(isA<UploadFailure>()));
    expect(
        () => form.submission({
              'category': ['999']
            }),
        throwsArgumentError);
    expect(
        () => form.submission({
              'unknown_field': ['x']
            }),
        throwsA(isA<UploadFailure>()));
    expect(
        () => form.submission({
              'gname_en': ['x' * 501]
            }),
        throwsArgumentError);
  });

  test('readonly and disabled server controls cannot be overridden', () {
    final input = fixture('new')
        .replaceFirst('id="gname_en"', 'readonly id="gname_en"')
        .replaceFirst('id="category"', 'disabled id="category"');
    final form = protocol.editor(input, newUri).form;
    expect(form.fields['category']!.value, '2');
    expect(
        () => form.submission({
              'gname_en': ['Edit']
            }),
        throwsA(isA<UploadFailure>()));
    expect(
        () => form.submission({
              'category': ['9']
            }),
        throwsA(isA<UploadFailure>()));
    expect(form.submission({}), isNot(contains('category')));
  });

  test('login and restrictions are distinct from empty or changed markup', () {
    expect(
        () => protocol.manager('<title>E-Hentai.org Login</title>'),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.loginRequired)));
    expect(
        () => protocol.manager('<p id="e">Upload temporarily unavailable.</p>'),
        throwsA(isA<UploadFailure>()
            .having((e) => e.kind, 'kind', UploadFailureKind.restricted)));
    for (final source in [
      '',
      '<html>maintenance</html>',
      fixture('manage').replaceAll('fixture-api-key', '[REDACTED]')
    ]) {
      expect(
          () => protocol.manager(source),
          throwsA(isA<UploadFailure>().having(
              (e) => e.kind, 'kind', UploadFailureKind.protocolChanged)));
    }
  });

  test('form destination cannot redirect credentials to another origin', () {
    for (final unsafe in [
      'https://upld.e-hentai.org.attacker.invalid/managegallery?act=new',
      'http://upld.e-hentai.org/managegallery?act=new',
      'https://user@upld.e-hentai.org/managegallery?act=new',
      'https://upld.e-hentai.org:444/managegallery?act=new',
    ]) {
      final source = fixture('new').replaceFirst(newUri.toString(), unsafe);
      // Replace the form action specifically; a navigation link can precede it.
      final formSource =
          source.replaceFirst('action="$newUri"', 'action="$unsafe"');
      expect(() => protocol.editor(formSource, newUri),
          throwsA(isA<UploadFailure>()));
    }
  });

  test(
      'API identity cannot be replaced by argument keys or printed by accident',
      () {
    const api = UploadApiSession(101, 'secret-test-value');
    final data = api.request(
        'managefolders', {'apiuid': 999, 'apikey': 'bad', 'method': 'bad'});
    expect(data['apiuid'], 101);
    expect(data['apikey'], 'secret-test-value');
    expect(data['method'], 'managefolders');
    expect(api.toString(), isNot(contains('secret-test-value')));
    expect(
        const UploadFailure(UploadFailureKind.restricted,
                serverMessage: 'private')
            .toString(),
        isNot(contains('private')));
  });
}
