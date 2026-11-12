import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/features/uploads/data/upload_advanced_actions.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/presentation/upload_editor_screen.dart';
import 'package:oviewer/features/uploads/presentation/upload_management_screens.dart';
import 'package:oviewer/features/uploads/upload_services.dart';

import 'upload_screens_test.dart' as f;

class _Review extends Mock implements UploadAdvancedRecovery {}

void main() {
  late f.MockServices services;
  late f.MockUploadRepository repository;
  late f.MockStore storage;
  late f.MockAuthBloc auth;
  late StreamController<AuthState> authEvents;
  late AuthState owner;
  late Directory root;
  late UploadDraft draft;
  late UploadEditorSnapshot editor;
  late UploadVisibilityConsent consent;
  late PendingUploadWrite? pending;

  UploadEditorSnapshot snapshot(
      {String id = '12345', String title = 'Fresh private gallery'}) {
    final doc = html.parse(File('test/fixtures/uploads/uploaded.html')
        .readAsStringSync()
        .replaceAll('12345', id));
    doc.querySelector('#gname_en')!.attributes['value'] = title;
    for (final option in doc.querySelectorAll('#category option')) {
      option.attributes.remove('selected');
      if (option.attributes['value'] == '0') {
        option.attributes['selected'] = 'selected';
      }
    }
    return const UploadProtocol()
        .editor(doc.outerHtml, uploadOrigin.resolve('managegallery?ulgid=$id'));
  }

  setUpAll(() {
    registerFallbackValue(f.draft());
    registerFallbackValue(Uri.parse('https://ehwiki.org/'));
    registerFallbackValue(<ManagedUploadGallery>[]);
    registerFallbackValue(<UploadVisibilityConsent>[]);
    registerFallbackValue(_Review());
    registerFallbackValue(UploadVisibilityConsent(
        accountId: '101',
        uri: uploadOrigin.resolve('managegallery?ulgid=12345'),
        targetCategory: '3',
        fingerprint: 'fingerprint',
        editsHash: 'edits',
        revision: 1,
        editor: snapshot()));
  });
  setUp(() {
    services = f.MockServices();
    repository = f.MockUploadRepository();
    storage = f.MockStore();
    auth = f.MockAuthBloc();
    owner = f.loggedIn('101', 1);
    authEvents = StreamController<AuthState>.broadcast(sync: true);
    root = Directory.systemTemp.createTempSync('upload-confirmation-ui-');
    editor = snapshot();
    draft = f.draft().copyWith(serverUri: editor.uri);
    consent = UploadVisibilityConsent(
        accountId: '101',
        uri: editor.uri,
        targetCategory: '3',
        fingerprint: 'fingerprint',
        editsHash: 'edits',
        revision: 1,
        editor: editor);
    pending = null;
    when(() => auth.state).thenAnswer((_) => owner);
    when(() => auth.stream).thenAnswer((_) => authEvents.stream);
    when(() => services.store).thenAnswer((_) async => storage);
    when(() => storage.root).thenReturn(root);
    when(() => services.repository).thenReturn(repository);
    when(() => services.supportsNativePublication).thenReturn(false);
    when(() => services.pendingWrite(any())).thenAnswer((_) async => pending);
    when(() => services.transferSnapshot())
        .thenAnswer((_) async => {'tasks': [], 'receipts': []});
    when(() => services.assetProgress(any(), snapshot: any(named: 'snapshot')))
        .thenAnswer((_) async => []);
    when(() => services.saveLocal(any())).thenAnswer(
        (call) async => call.positionalArguments.single as UploadDraft);
    when(() => services.openExternal(any())).thenAnswer((_) async {});
  });
  tearDown(() async {
    await authEvents.close();
    root.deleteSync(recursive: true);
  });
  Widget host(Widget child) => BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child));
  Future<void> mountEditor(WidgetTester tester) async {
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services, session: UploadEditingSession(draft, editor))));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Future<void> click(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(target, 250);
    }
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets(
      'privacy review waits for the fresh snapshot, and cancellation sends no save',
      (tester) async {
    final fresh = Completer<UploadVisibilityConsent?>();
    when(() => services.prepareVisibilityChange(any()))
        .thenAnswer((_) => fresh.future);
    await mountEditor(tester);
    await tester
        .ensureVisible(find.byKey(const ValueKey('upload-action-savebutton')));
    await tester.tap(find.byKey(const ValueKey('upload-action-savebutton')));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('upload-visibility-dialog')), findsNothing);
    verify(() => services.prepareVisibilityChange(any())).called(1);
    fresh.complete(consent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final dialog = find.byKey(const ValueKey('upload-visibility-dialog'));
    expect(
        find.descendant(
            of: dialog, matching: find.text('Fresh private gallery')),
        findsOneWidget);
    expect(find.text('Private / Unlisted → Manga'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => services.saveRemote(any()));
    verifyNever(() => services.saveRemoteWithVisibility(any(), any()));
    await finish(tester);
  });

  testWidgets(
      'privacy confirmation submits the exact reviewed proof and not an ordinary save',
      (tester) async {
    when(() => services.prepareVisibilityChange(any()))
        .thenAnswer((_) async => consent);
    UploadVisibilityConsent? submitted;
    when(() => services.saveRemoteWithVisibility(any(), any()))
        .thenAnswer((call) async {
      submitted = call.positionalArguments[1] as UploadVisibilityConsent;
      return UploadEditingSession(draft.copyWith(dirty: false), editor);
    });
    await mountEditor(tester);
    await click(tester, 'upload-action-savebutton');
    verifyNever(() => services.saveRemoteWithVisibility(any(), any()));
    await click(tester, 'upload-visibility-confirm');
    expect(identical(submitted, consent), isTrue);
    verifyNever(() => services.saveRemote(any()));
    await finish(tester);
  });

  testWidgets('account replacement while privacy dialog is open cannot submit',
      (tester) async {
    when(() => services.prepareVisibilityChange(any()))
        .thenAnswer((_) async => consent);
    await mountEditor(tester);
    await click(tester, 'upload-action-savebutton');
    owner = f.loggedIn('102', 2);
    authEvents.add(owner);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('upload-visibility-confirm')), findsNothing);
    verifyNever(() => services.saveRemoteWithVisibility(any(), any()));
    await finish(tester);
  });

  testWidgets(
      'a stale privacy proof remains an error and never falls back to an unconfirmed save',
      (tester) async {
    when(() => services.prepareVisibilityChange(any()))
        .thenAnswer((_) async => consent);
    when(() => services.saveRemoteWithVisibility(any(), any())).thenThrow(
        const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'The gallery changed after review. Review it again.'));
    await mountEditor(tester);
    await click(tester, 'upload-action-savebutton');
    await click(tester, 'upload-visibility-confirm');
    expect(find.textContaining('The gallery changed after review.'),
        findsOneWidget);
    verify(() => services.saveRemoteWithVisibility(any(), consent)).called(1);
    verifyNever(() => services.saveRemote(any()));
    await finish(tester);
  });

  testWidgets(
      'pending website write disables mutating menu actions but keeps statistics',
      (tester) async {
    pending = PendingUploadWrite('operation1', 'save', editor.uri, const {
      'gname_en': ['Submitted title']
    });
    await mountEditor(tester);
    await tester.tap(find.byTooltip('Gallery management'));
    await tester.pumpAndSettle();
    final entries = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>));
    expect(entries.where((entry) => entry.value != 'statistics'), hasLength(4));
    expect(
        entries
            .where((entry) => entry.value != 'statistics')
            .every((entry) => !entry.enabled),
        isTrue);
    expect(entries.singleWhere((entry) => entry.value == 'statistics').enabled,
        isTrue);
    await finish(tester);
  });

  testWidgets(
      'save association keeps the operation identifier captured before its dialog',
      (tester) async {
    pending = PendingUploadWrite('operation1', 'save', editor.uri, const {
      'gname_en': ['Submitted title']
    });
    when(() => repository.editor('101', editor.uri))
        .thenAnswer((_) async => editor);
    when(() => services.associatePendingGallery(any(), editor.uri,
            expectedOperationId: 'operation1'))
        .thenThrow(const UploadFailure(UploadFailureKind.resultUncertain));
    await mountEditor(tester);
    await click(tester, 'upload-pending-associate');
    expect(find.text('Confirm this gallery association'), findsOneWidget);
    pending = PendingUploadWrite('operation2', 'save', editor.uri, const {
      'gname_en': ['A newer submission']
    });
    await tester
        .tap(find.widgetWithText(FilledButton, 'Link and continue editing'));
    await tester.pumpAndSettle();
    verify(() => services.associatePendingGallery(any(), editor.uri,
        expectedOperationId: 'operation1')).called(1);
    expect(find.text('Submitted title: A newer submission'), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
      'bulk category review fetches proofs before asking and passes the frozen set',
      (tester) async {
    final manager = const UploadProtocol().manager(
        File('test/fixtures/uploads/populated-manager.html')
            .readAsStringSync());
    final targets = manager.galleries;
    final prepared = Completer<List<UploadVisibilityConsent>>();
    when(() => services.prepareBulkVisibilityChange('101', any(), '3'))
        .thenAnswer((_) => prepared.future);
    List<UploadVisibilityConsent>? sent;
    when(() => services.bulkModifyWithVisibility('101', any(),
        categoryValue: '3',
        consents: any(named: 'consents'),
        isCancelled: any(named: 'isCancelled'))).thenAnswer((call) async {
      sent = call.namedArguments[#consents] as List<UploadVisibilityConsent>;
      return UploadBulkResult(targets
          .map((t) => UploadBulkItemResult(t, UploadBulkStatus.completed))
          .toList());
    });
    await tester.pumpWidget(host(UploadBulkScreen(
        accountId: '101',
        manager: manager,
        targets: targets,
        category: true,
        services: services)));
    await tester.pumpAndSettle();
    await click(tester, 'upload-bulk-destination');
    await tester.tap(find.text('Manga').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('upload-bulk-execute')));
    await tester.pump();
    expect(find.text('Confirm bulk action'), findsNothing);
    prepared.complete([consent]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Confirm bulk action'), findsOneWidget);
    expect(find.text('Fresh private gallery'), findsOneWidget);
    expect(sent, isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(sent, [consent]);
    verifyNever(() => repository.bulkModify(any(), any(),
        categoryValue: any(named: 'categoryValue'),
        isCancelled: any(named: 'isCancelled')));
    await finish(tester);
  });

  _Review review(
      {List<UploadEditorSnapshot> candidates = const [],
      bool canClear = false,
      UploadActionResult? observed}) {
    final value = _Review();
    when(() => value.operationId).thenReturn('operation1');
    when(() => value.kind).thenReturn(UploadGalleryAction.clone);
    when(() => value.editor).thenReturn(editor);
    when(() => value.candidates).thenReturn(candidates);
    when(() => value.canMarkNoEffect).thenReturn(canClear);
    when(() => value.confirmedResult).thenReturn(observed);
    return value;
  }

  void unresolved(_Review value) {
    pending = PendingUploadWrite('operation1', 'clone', editor.uri, const {
      'gname_en': ['Original request title']
    });
    when(() => services.prepareAdvancedRecovery(any()))
        .thenAnswer((_) async => value);
  }

  testWidgets(
      'advanced manual clearance requires the acknowledgement checkbox and never replays',
      (tester) async {
    final value = review(canClear: true);
    unresolved(value);
    when(() => services.resolveAdvancedRecovery(any(), value,
        selectedEditor: null, confirmedNoEffect: true)).thenAnswer((_) async {
      pending = null;
      return null;
    });
    await mountEditor(tester);
    expect(
        find.byKey(const ValueKey('upload-pending-no-change')), findsNothing);
    await click(tester, 'upload-pending-advanced-review');
    final button = find.byKey(const ValueKey('upload-recovery-confirm'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await click(tester, 'upload-recovery-no-effect-check');
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await click(tester, 'upload-recovery-confirm');
    verify(() => services.resolveAdvancedRecovery(any(), value,
        selectedEditor: null, confirmedNoEffect: true)).called(1);
    expect(find.text('Previous gallery action needs reconciliation'),
        findsNothing);
    verifyNever(() => services.saveRemote(any()));
    await finish(tester);
  });

  testWidgets(
      'parent-linked candidate must be selected and opens the returned local child identity',
      (tester) async {
    final child = snapshot(id: '54321', title: 'Explicit child');
    final value = review(candidates: [child]);
    unresolved(value);
    when(() => services.resolveAdvancedRecovery(any(), value,
        selectedEditor: child.uri,
        confirmedNoEffect: false)).thenAnswer((_) async {
      pending = null;
      return UploadActionResult(UploadGalleryAction.clone,
          editor: child, localDraftId: 'child-local-id');
    });
    when(() => services.openDraft('101', 'child-local-id')).thenAnswer(
        (_) async => UploadEditingSession(
            f.draft(id: 'child-local-id').copyWith(serverUri: child.uri),
            child));
    await mountEditor(tester);
    await click(tester, 'upload-pending-advanced-review');
    expect(find.byKey(const ValueKey('upload-recovery-no-effect-check')),
        findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-recovery-confirm')))
            .onPressed,
        isNull);
    await click(tester, 'upload-recovery-candidate-54321');
    await click(tester, 'upload-recovery-confirm');
    verify(() => services.resolveAdvancedRecovery(any(), value,
        selectedEditor: child.uri, confirmedNoEffect: false)).called(1);
    verify(() => services.openDraft('101', 'child-local-id')).called(1);
    await finish(tester);
  });

  testWidgets(
      'advanced review for a newer operation cannot reuse the pending confirmation',
      (tester) async {
    final value = review(canClear: true);
    when(() => value.operationId).thenReturn('new-operation');
    unresolved(value);
    await mountEditor(tester);
    await click(tester, 'upload-pending-advanced-review');
    expect(find.byKey(const ValueKey('upload-advanced-recovery-dialog')),
        findsNothing);
    verifyNever(() => services.resolveAdvancedRecovery(any(), any(),
        selectedEditor: any(named: 'selectedEditor'),
        confirmedNoEffect: any(named: 'confirmedNoEffect')));
    await finish(tester);
  });

  testWidgets(
      'an observed advanced result needs confirmation and is never labeled no effect',
      (tester) async {
    final result = UploadActionResult(UploadGalleryAction.clone,
        editor: editor, localDraftId: draft.id);
    final value = review(observed: result);
    unresolved(value);
    when(() => services.resolveAdvancedRecovery(any(), value,
        selectedEditor: null, confirmedNoEffect: false)).thenAnswer((_) async {
      pending = null;
      return result;
    });
    when(() => services.openDraft('101', draft.id))
        .thenAnswer((_) async => UploadEditingSession(draft, editor));
    await mountEditor(tester);
    await click(tester, 'upload-pending-advanced-review');
    expect(find.byKey(const ValueKey('upload-recovery-no-effect-check')),
        findsNothing);
    expect(find.text('Confirm current result'), findsOneWidget);
    verifyNever(() => services.resolveAdvancedRecovery(any(), value,
        selectedEditor: null, confirmedNoEffect: false));
    await click(tester, 'upload-recovery-confirm');
    verify(() => services.resolveAdvancedRecovery(any(), value,
        selectedEditor: null, confirmedNoEffect: false)).called(1);
    await finish(tester);
  });
}
