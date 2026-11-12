// Real UploadServices/Repository/Store with a fake HTTP adapter. Publication
// responses below are synthetic contract states, never requests to the website.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:mocktail/mocktail.dart';
import 'package:sqlite3/open.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/features/uploads/data/upload_advanced_actions.dart';
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/presentation/upload_advanced_screens.dart';
import 'package:oviewer/features/uploads/upload_services.dart';

import 'upload_services_test.dart' show UploadTestCookies, UploadTestPlatform;
import 'upload_screens_test.dart' show MockAuthBloc, loggedIn;

class _Transport implements HttpClientAdapter {
  final published = <String>{};
  final changed = <String>{};
  final mutations = <String>[];
  final reads = <Uri>[];
  final base = File('test/fixtures/uploads/uploaded.html').readAsStringSync();
  @override
  Future<ResponseBody> fetch(RequestOptions request, Stream<Uint8List>? body,
      Future<void>? cancellation) async {
    if (body != null) await body.drain<void>();
    final id = request.uri.queryParameters['ulgid']!;
    reads.add(request.uri);
    if (request.uri.queryParameters['act'] == 'publish') {
      mutations.add(id);
      published.add(id);
    } else if (request.uri.queryParameters.containsKey('act')) {
      throw StateError('Unexpected action in publication contract test');
    }
    final doc = html.parse(base.replaceAll('12345', id));
    doc.querySelector('#tos')!.attributes.remove('checked');
    if (changed.contains(id)) {
      doc.querySelector('#gname_en')!.attributes['value'] =
          'Changed after review';
    }
    if (published.contains(id)) {
      for (final row in doc.querySelectorAll('td#d tr')) {
        final label = row.querySelector('td.k')?.text;
        if (label == 'Date Posted:') {
          row.querySelector('td.v')!.text = '2026-11-13 12:00';
        }
        if (label == 'Visible:') row.querySelector('td.v')!.text = 'Yes';
      }
      doc.querySelector('#publishbutton')!.attributes['disabled'] = 'disabled';
      doc.querySelector('td#d')!.append(dom.Element.tag('a')
        ..attributes['href'] = 'https://e-hentai.org/g/$id/abcde12345/'
        ..text = 'Show Public Gallery');
    }
    return ResponseBody.fromString(doc.outerHtml, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  late Directory root;
  late UploadStore store;
  late UploadTestCookies cookies;
  late _Transport transport;
  late UploadServices services;
  late MockAuthBloc auth;
  late AuthState state;
  late StreamController<AuthState> events;
  Uri uri(String id) => uploadOrigin.resolve('managegallery?ulgid=$id');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('publication-terms-');
    store = UploadStore(UploadDatabase(NativeDatabase.memory()), root);
    cookies = UploadTestCookies();
    transport = _Transport();
    services = UploadServices(cookies,
        platform: UploadTestPlatform(),
        store: store,
        repository:
            UploadRepository(UploadHttpClient(cookies, adapter: transport)));
    await services.store;
    auth = MockAuthBloc();
    state = loggedIn('101', 1);
    events = StreamController<AuthState>.broadcast(sync: true);
    when(() => auth.state).thenAnswer((_) => state);
    when(() => auth.stream).thenAnswer((_) => events.stream);
  });
  tearDown(() async {
    await services.dispose();
    await events.close();
    await root.delete(recursive: true);
  });
  Future<({UploadDraft draft, PreparedUploadAction action})> prepare(
      String id) async {
    final editing = await services.openRemote('101', uri(id));
    final action = await services.prepareAdvanced(
        editing.draft, UploadGalleryAction.publish);
    return (draft: editing.draft, action: action);
  }

  test(
      'fresh remote drafts without tos publish only with explicit batch agreement and do not persist it',
      () async {
    final first = await prepare('12345');
    final second = await prepare('12346');
    expect(first.draft.fields.containsKey('tos'), isFalse);
    expect(first.action.editor.form.fields['tos']!.values, isEmpty);
    await expectLater(
        services.performAdvanced(first.draft, first.action, confirmed: true),
        throwsArgumentError);
    await expectLater(
        services.acceptPublicationTerms([first.action, second.action],
            confirmed: false),
        throwsArgumentError);
    expect(transport.mutations, isEmpty);
    final agreement = await services
        .acceptPublicationTerms([first.action, second.action], confirmed: true);
    for (final item in [first, second]) {
      final result = await services.performAdvanced(item.draft, item.action,
          confirmed: true, publicationTerms: agreement);
      expect(result.kind, UploadGalleryAction.publish);
      final saved = (await store.draft('101', item.draft.id))!;
      expect(saved.remoteState, 'published');
      expect(saved.fields.containsKey('tos'), isFalse);
      expect(await services.pendingWrite(saved), isNull);
    }
    expect(transport.mutations, ['12345', '12346']);
    final third = await prepare('12347');
    await expectLater(
        services.performAdvanced(third.draft, third.action, confirmed: true),
        throwsArgumentError);
    expect(transport.mutations, ['12345', '12346']);
  });

  test(
      'terms consent is limited to exact reviewed objects, targets and one use',
      () async {
    final first = await prepare('12345');
    final second = await prepare('12346');
    final consent =
        await services.acceptPublicationTerms([first.action], confirmed: true);
    await expectLater(
        services.performAdvanced(second.draft, second.action,
            confirmed: true, publicationTerms: consent),
        throwsA(isA<UploadFailure>()));
    final refreshed = await services.prepareAdvanced(
        first.draft, UploadGalleryAction.publish);
    await expectLater(
        services.performAdvanced(first.draft, refreshed,
            confirmed: true, publicationTerms: consent),
        throwsA(isA<UploadFailure>()));
    expect(transport.mutations, isEmpty);
    await services.performAdvanced(first.draft, first.action,
        confirmed: true, publicationTerms: consent);
    await expectLater(
        services.performAdvanced(first.draft, first.action,
            confirmed: true, publicationTerms: consent),
        throwsA(isA<UploadFailure>()));
    expect(transport.mutations, ['12345']);
  });

  test('a new login or account cannot consume the reviewed terms consent',
      () async {
    final item = await prepare('12345');
    final consent =
        await services.acceptPublicationTerms([item.action], confirmed: true);
    cookies.revision++;
    await expectLater(
        services.performAdvanced(item.draft, item.action,
            confirmed: true, publicationTerms: consent),
        throwsA(isA<UploadFailure>()));
    cookies.account = '202';
    await expectLater(
        services.acceptPublicationTerms([item.action], confirmed: true),
        throwsA(isA<UploadFailure>()));
    expect(transport.mutations, isEmpty);
  });

  test(
      'terms agreement never authorizes another action or a changed website snapshot',
      () async {
    final item = await prepare('12345');
    final consent =
        await services.acceptPublicationTerms([item.action], confirmed: true);
    final deletion =
        await services.prepareAdvanced(item.draft, UploadGalleryAction.delete);
    await expectLater(
        services.acceptPublicationTerms([deletion], confirmed: true),
        throwsArgumentError);
    await expectLater(
        services.performAdvanced(item.draft, deletion,
            confirmed: true, publicationTerms: consent),
        throwsA(isA<UploadFailure>()));
    transport.changed.add('12345');
    await expectLater(
        services.performAdvanced(item.draft, item.action,
            confirmed: true, publicationTerms: consent),
        throwsA(isA<UploadFailure>()));
    expect(transport.mutations, isEmpty);
    expect(await services.pendingWrite(item.draft), isNull);
  });

  test(
      'the existing single-draft terms agreement remains valid without a batch token',
      () async {
    final item = await prepare('12345');
    final local = await store.save(item.draft.copyWith(fields: {
      ...item.draft.fields,
      'tos': ['on']
    }, dirty: false));
    await services.performAdvanced(local, item.action, confirmed: true);
    expect(transport.mutations, ['12345']);
  });

  Widget screen() => BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: UploadBulkAdvancedScreen(
              services: services,
              accountId: '101',
              action: UploadGalleryAction.publish,
              targets: [
                ManagedUploadGallery(
                    title: 'Frozen target',
                    date: '',
                    category: 'Non-H',
                    fileCount: 8,
                    section: 'u',
                    actions: {'Manage': uri('12345')})
              ])));
  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(screen());
    // Real sqlite/HTTP-adapter futures need event-loop turns, beyond Flutter's
    // fake-clock animation settling. Wait for the two owner reads to finish.
    for (var i = 0; i < 100 && transport.reads.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    expect(transport.reads.length, greaterThanOrEqualTo(2));
    await tester.pumpAndSettle();
    final review = find.text('Review and confirm');
    if (review.evaluate().isEmpty) await tester.scrollUntilVisible(review, 300);
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
      'real batch UI starts unchecked, cancels without agreement, then publishes only after explicit check',
      (tester) async {
    await tester.runAsync(() async {
      await openDialog(tester);
      final terms =
          find.byKey(const ValueKey('upload-batch-publication-terms'));
      final confirm =
          find.widgetWithText(FilledButton, 'Confirm listed targets');
      expect(tester.widget<CheckboxListTile>(terms).value, false);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(transport.mutations, isEmpty);
      final review = find.text('Review and confirm');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(terms).value, false);
      await tester.ensureVisible(terms);
      await tester.tap(terms);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      for (var i = 0; i < 100 && find.text('success').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(transport.mutations, ['12345']);
      expect(find.text('success'), findsOneWidget);
      final saved = (await store.drafts('101')).single;
      expect(saved.fields.containsKey('tos'), isFalse);
      await unmount(tester);
    });
  });

  testWidgets(
      'changing login while checked dialog is open sends no publication request',
      (tester) async {
    await tester.runAsync(() async {
      await openDialog(tester);
      final terms =
          find.byKey(const ValueKey('upload-batch-publication-terms'));
      await tester.ensureVisible(terms);
      await tester.tap(terms);
      await tester.pumpAndSettle();
      cookies.revision++;
      state = loggedIn('101', 2);
      events.add(state);
      await tester.pumpAndSettle();
      expect(find.text('Confirm listed targets'), findsNothing);
      expect(transport.mutations, isEmpty);
      await unmount(tester);
    });
  });
}
