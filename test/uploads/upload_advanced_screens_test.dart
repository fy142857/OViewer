import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/features/uploads/data/upload_advanced_actions.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/presentation/upload_advanced_screens.dart';
import 'package:oviewer/features/uploads/upload_services.dart';
import 'package:oviewer/models/user_profile.dart';

class _Services extends Mock implements UploadServices {}

class _Auth extends Mock implements AuthBloc {}

Uri _uri(String id) => uploadOrigin.resolve('managegallery?ulgid=$id');
UploadDraft _draft(String id) => UploadDraft(
    id: id,
    accountId: '101',
    serverUri: _uri(id),
    fields: const {},
    assets: const []);
UploadEditorSnapshot _editor(String id) => const UploadProtocol().editor(
    File('test/fixtures/uploads/uploaded.html')
        .readAsStringSync()
        .replaceAll('12345', id),
    _uri(id));
PreparedUploadAction _prepared(String id, UploadGalleryAction action) =>
    PreparedUploadAction(
        accountId: '101',
        action: action,
        editorUri: _uri(id),
        actionUri: _uri(id).replace(query: 'ulgid=$id&act=${action.name}'),
        editor: _editor(id),
        fingerprint: 'review-$id',
        revision: 1);
ManagedUploadGallery _gallery(String id) => ManagedUploadGallery(
    title: 'Gallery $id',
    date: '',
    category: 'Non-H',
    fileCount: 8,
    section: 'u',
    actions: {'Manage': _uri(id)});
AuthState _loggedIn(int generation) => AuthState(
    status: AuthStatus.authenticated,
    sessionGeneration: generation,
    profile: const UserProfile(memberId: '101', isLoggedIn: true));

void main() {
  late _Services services;
  late _Auth auth;
  late AuthState state;
  late StreamController<AuthState> changes;

  setUpAll(() {
    registerFallbackValue(_draft('12345'));
    registerFallbackValue(UploadGalleryAction.publish);
    registerFallbackValue(_prepared('12345', UploadGalleryAction.publish));
    registerFallbackValue(_uri('12345'));
  });
  setUp(() {
    services = _Services();
    auth = _Auth();
    state = _loggedIn(1);
    changes = StreamController<AuthState>.broadcast(sync: true);
    when(() => auth.state).thenAnswer((_) => state);
    when(() => auth.stream).thenAnswer((_) => changes.stream);
    when(() => services.openExternal(any())).thenAnswer((_) async {});
    when(() => services.openRemote(any(), any())).thenAnswer((call) async {
      final id = uploadGalleryId(call.positionalArguments[1] as Uri)!;
      return UploadEditingSession(_draft(id), _editor(id));
    });
    when(() => services.prepareAdvanced(any(), any())).thenAnswer(
        (call) async => _prepared(
            (call.positionalArguments[0] as UploadDraft).id,
            call.positionalArguments[1] as UploadGalleryAction));
    when(() => services.performAdvanced(any(), any(), confirmed: true))
        .thenAnswer((call) async => UploadActionResult(
            (call.positionalArguments[1] as PreparedUploadAction).action));
  });
  tearDown(() async => changes.close());

  Widget host(Widget child) => BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child));
  Widget single(UploadGalleryAction action) => host(Builder(
      builder: (context) => Scaffold(
          body: TextButton(
              onPressed: () => reviewUploadAction(
                  context, services, _draft('12345'), action),
              child: const Text('Review')))));
  Widget batch() => host(UploadBulkAdvancedScreen(
      services: services,
      accountId: '101',
      action: UploadGalleryAction.publish,
      targets: [_gallery('12345'), _gallery('12346'), _gallery('12347')]));
  Future<void> openBatch(WidgetTester tester) async {
    await tester.pumpWidget(batch());
    await tester.pumpAndSettle();
    final button = find.text('Review and confirm');
    await tester.scrollUntilVisible(button, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('review never sends an action until exact snapshot is confirmed',
      (tester) async {
    final prepared = _prepared('12345', UploadGalleryAction.publish);
    when(() => services.prepareAdvanced(any(), any()))
        .thenAnswer((_) async => prepared);
    await tester.pumpWidget(single(UploadGalleryAction.publish));
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Upload management ID: 12345'), findsOneWidget);
    verifyNever(() => services.performAdvanced(any(), any(), confirmed: true));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => services.performAdvanced(any(), any(), confirmed: true));
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm Publish gallery'));
    await tester.pumpAndSettle();
    final calls = verify(() =>
            services.performAdvanced(any(), captureAny(), confirmed: true))
        .captured;
    expect(identical(calls.single, prepared), isTrue);
  });

  testWidgets('changed session disables an open action confirmation',
      (tester) async {
    await tester.pumpWidget(single(UploadGalleryAction.delete));
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    state = _loggedIn(2);
    changes.add(state);
    await tester.pumpAndSettle();
    expect(find.text('Login state changed'), findsOneWidget);
    expect(find.text('Confirm Delete website gallery'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    verifyNever(() => services.performAdvanced(any(), any(), confirmed: true));
  });

  testWidgets('changed session while fetching cannot open stale confirmation',
      (tester) async {
    final pending = Completer<PreparedUploadAction>();
    when(() => services.prepareAdvanced(any(), any()))
        .thenAnswer((_) => pending.future);
    await tester.pumpWidget(single(UploadGalleryAction.publish));
    await tester.tap(find.text('Review'));
    state = _loggedIn(2);
    changes.add(state);
    pending.complete(_prepared('12345', UploadGalleryAction.publish));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    verifyNever(() => services.performAdvanced(any(), any(), confirmed: true));
  });

  testWidgets(
      'unavailable deletion displays explanation and deletion rules without confirm',
      (tester) async {
    when(() => services.prepareAdvanced(any(), any())).thenThrow(
        const UploadFailure(UploadFailureKind.restricted,
            code: 'public_delete_forbidden',
            serverMessage: 'Published public galleries cannot be deleted.'));
    await tester.pumpWidget(single(UploadGalleryAction.delete));
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Published public galleries cannot be deleted.'),
        findsOneWidget);
    expect(find.text('Confirm Delete website gallery'), findsNothing);
    expect(find.text('Show details'), findsWidgets);
    verifyNever(() => services.performAdvanced(any(), any(), confirmed: true));
  });

  testWidgets(
      'uncertain second result stops batch and does not replay first or third',
      (tester) async {
    final sent = <String>[];
    when(() => services.performAdvanced(any(), any(), confirmed: true))
        .thenAnswer((call) async {
      final id = (call.positionalArguments.first as UploadDraft).id;
      sent.add(id);
      if (id == '12346')
        throw const UploadFailure(UploadFailureKind.resultUncertain);
      return const UploadActionResult(UploadGalleryAction.publish);
    });
    await openBatch(tester);
    expect(sent, isEmpty);
    await tester.tap(find.text('Confirm listed targets'));
    await tester.pumpAndSettle();
    expect(sent, ['12345', '12346']);
    expect(find.text('uncertain'), findsOneWidget);
    expect(find.text('not executed'), findsOneWidget);
    expect(find.text('Review and confirm'), findsNothing);
  });

  testWidgets(
      'site restriction without a known per-gallery reason stops review',
      (tester) async {
    when(() => services.prepareAdvanced(any(), any())).thenAnswer((call) async {
      final id = (call.positionalArguments.first as UploadDraft).id;
      if (id == '12346')
        throw const UploadFailure(UploadFailureKind.restricted,
            serverMessage: 'Try again later.');
      return _prepared(id, UploadGalleryAction.publish);
    });
    await tester.pumpWidget(batch());
    await tester.pumpAndSettle();
    expect(find.text('Review and confirm'), findsNothing);
    verifyNever(() => services.performAdvanced(any(), any(), confirmed: true));
    verifyNever(() => services.openRemote('101', _uri('12347')));
  });

  testWidgets(
      'known unavailable target is skipped but other reviewed targets can run',
      (tester) async {
    when(() => services.prepareAdvanced(any(), any())).thenAnswer((call) async {
      final id = (call.positionalArguments.first as UploadDraft).id;
      if (id == '12346')
        throw const UploadFailure(UploadFailureKind.restricted,
            code: 'unavailable_action');
      return _prepared(id, UploadGalleryAction.publish);
    });
    await openBatch(tester);
    await tester.tap(find.text('Confirm listed targets'));
    await tester.pumpAndSettle();
    final sent = verify(() =>
            services.performAdvanced(captureAny(), any(), confirmed: true))
        .captured
        .cast<UploadDraft>()
        .map((draft) => draft.id)
        .toList();
    expect(sent, ['12345', '12347']);
  });

  testWidgets(
      'statistics render native table and hide account data after session change',
      (tester) async {
    when(() => services.statistics(any())).thenAnswer((_) async =>
        UploadStatsSnapshot(
            uri: Uri.parse('https://e-hentai.org/stats.php?gid=12345'),
            title: 'Test statistics',
            tables: const [
              [
                ['Date', 'Views'],
                ['2026-11-12', '8']
              ]
            ],
            notes: const [
              'Daily counts'
            ]));
    await tester.pumpWidget(host(
        UploadStatisticsScreen(services: services, draft: _draft('12345'))));
    await tester.pumpAndSettle();
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    state = _loggedIn(2);
    changes.add(state);
    await tester.pumpAndSettle();
    expect(find.byType(Table), findsNothing);
    expect(find.text('Login state changed. Reopen this page.'), findsOneWidget);
  });
}
