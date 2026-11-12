import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/features/uploads/data/upload_http_client.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';
import 'package:oviewer/features/uploads/presentation/upload_management_screens.dart';
import 'package:oviewer/features/uploads/upload_services.dart';
import 'package:oviewer/models/user_profile.dart';

class MockServices extends Mock implements UploadServices {}

class MockRepository extends Mock implements UploadRepository {}

class MockClient extends Mock implements UploadHttpClient {}

class MockAuth extends Mock implements AuthBloc {}

String fixture(String name) =>
    File('test/fixtures/uploads/$name.html').readAsStringSync();
const protocol = UploadProtocol();
final galleryUri = uploadOrigin.resolve('managegallery?ulgid=12345');

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 250);
  }
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late MockServices services;
  late MockRepository repository;
  late MockClient client;
  late MockAuth auth;
  late AuthState state;
  late StreamController<AuthState> events;
  late UploadFoldersSnapshot folders;
  late UploadManagerSnapshot manager;
  late UploadEditorSnapshot images;
  setUpAll(() {
    registerFallbackValue(protocol.folders(fixture('populated-folders')));
    registerFallbackValue(protocol.editor(fixture('uploaded'), galleryUri));
    registerFallbackValue(Uri.parse('https://ehgt.org/fixture'));
    registerFallbackValue(CancelToken());
    registerFallbackValue(<int, String>{});
    registerFallbackValue(<String, int>{});
    registerFallbackValue(<String, RemoteUploadImage>{});
    registerFallbackValue(<ManagedUploadGallery>[]);
    registerFallbackValue(UploadReceiptReview(
        receiptId: 'r',
        taskId: 't',
        draftId: 'd',
        galleryUri: galleryUri,
        expectedNames: const [],
        matchedFiles: const {},
        missingNames: const [],
        ambiguousNames: const []));
  });
  setUp(() {
    services = MockServices();
    repository = MockRepository();
    client = MockClient();
    auth = MockAuth();
    folders = protocol.folders(fixture('populated-folders'));
    manager = protocol.manager(fixture('populated-manager'));
    images = protocol.editor(fixture('uploaded'), galleryUri);
    state = const AuthState(
        status: AuthStatus.authenticated,
        sessionGeneration: 1,
        profile: UserProfile(memberId: '101', isLoggedIn: true));
    events = StreamController<AuthState>.broadcast(sync: true);
    when(() => auth.state).thenAnswer((_) => state);
    when(() => auth.stream).thenAnswer((_) => events.stream);
    when(() => services.repository).thenReturn(repository);
    when(() => repository.client).thenReturn(client);
    when(() => repository.folders('101')).thenAnswer((_) async => folders);
    when(() => services.openExternal(any())).thenAnswer((_) async {});
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lLkAAAAASUVORK5CYII=');
    when(() => client.readImage(any(),
        cancelToken: any(named: 'cancelToken'),
        maxBytes: any(named: 'maxBytes'))).thenAnswer((_) async => png);
  });
  tearDown(() async {
    await events.close();
  });
  Widget host(Widget child) => BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child));

  testWidgets(
      'folder edits remain local until explicit save and preserve current constraints',
      (tester) async {
    final doc = html.parse(fixture('populated-folders'));
    doc.querySelector('input[name="fn1"]')!.attributes['value'] =
        'Renamed in app';
    final saved = protocol.folders(doc.outerHtml);
    Map<int, String>? requested;
    when(() => repository.saveFolders('101', any(),
        renamed: any(named: 'renamed'),
        orderedIds: any(named: 'orderedIds'),
        newName: any(named: 'newName'))).thenAnswer((call) async {
      requested = call.namedArguments[#renamed] as Map<int, String>;
      return saved;
    });
    await tester.pumpWidget(
        host(UploadFoldersScreen(accountId: '101', services: services)));
    await tester.pumpAndSettle();
    final name = find.byKey(const ValueKey('upload-folder-name-1'));
    await tester.ensureVisible(name);
    await tester.enterText(name, 'Renamed in app');
    await tester.pump();
    verifyNever(() => repository.saveFolders('101', any(),
        renamed: any(named: 'renamed'),
        orderedIds: any(named: 'orderedIds'),
        newName: any(named: 'newName')));
    await tapVisible(tester, find.byKey(const ValueKey('upload-folders-save')));
    expect(requested, {1: 'Renamed in app'});
    expect(tester.widget<TextField>(name).controller!.text, 'Renamed in app');
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-folders-save')))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'nonempty folder rejection remains visible and does not claim deletion',
      (tester) async {
    when(() => repository.deleteEmptyFolder('101', 1)).thenThrow(
        const UploadFailure(UploadFailureKind.restricted,
            serverMessage:
                'Move all galleries out of this folder before deleting it.'));
    await tester.pumpWidget(
        host(UploadFoldersScreen(accountId: '101', services: services)));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byTooltip('Delete empty folder'));
    await tester.tap(find.widgetWithText(TextButton, 'Delete empty folder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Move all galleries out'), findsOneWidget);
    expect(find.byKey(const ValueKey('upload-folder-name-1')), findsOneWidget);
  });

  testWidgets('bulk action requires destination and frozen-list confirmation',
      (tester) async {
    List<ManagedUploadGallery>? sent;
    when(() => repository.bulkModify('101', any(),
        folderId: 0,
        categoryValue: null,
        isCancelled: any(named: 'isCancelled'))).thenAnswer((call) async {
      sent = call.positionalArguments[1] as List<ManagedUploadGallery>;
      return UploadBulkResult(
          [UploadBulkItemResult(sent!.single, UploadBulkStatus.completed)]);
    });
    await tester.pumpWidget(host(UploadBulkScreen(
        accountId: '101',
        manager: manager,
        targets: manager.galleries,
        category: false,
        services: services)));
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-bulk-execute')))
            .onPressed,
        isNull);
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-bulk-destination')));
    await tester.tap(find.text('Unsorted').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('upload-bulk-execute')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Confirm bulk action'), findsOneWidget);
    expect(sent, isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    expect(sent!.single.selectionValue, '12345');
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Back to galleries'), findsOneWidget);
  });

  testWidgets('batch stop affects unsent items without claiming rollback',
      (tester) async {
    final pending = Completer<UploadBulkResult>();
    bool Function()? stop;
    when(() => repository.bulkModify('101', any(),
        folderId: 0,
        categoryValue: null,
        isCancelled: any(named: 'isCancelled'))).thenAnswer((call) {
      stop = call.namedArguments[#isCancelled] as bool Function();
      return pending.future;
    });
    await tester.pumpWidget(host(UploadBulkScreen(
        accountId: '101',
        manager: manager,
        targets: manager.galleries,
        category: false,
        services: services)));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-bulk-destination')));
    await tester.tap(find.text('Unsorted').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('upload-bulk-execute')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    await tester.tap(find.text('Stop unsent items'));
    await tester.pump();
    expect(stop!(), isTrue);
    pending.complete(UploadBulkResult([
      UploadBulkItemResult(manager.galleries.single, UploadBulkStatus.uncertain)
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Result uncertain'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
  });

  testWidgets(
      'remote ordering stays pending until save and sends the complete mapping',
      (tester) async {
    final reversed = protocol.editor(fixture('reordered'), galleryUri);
    Map<String, int>? submitted;
    when(() => repository.reorderImages('101', any(), any()))
        .thenAnswer((call) async {
      submitted = call.positionalArguments[2] as Map<String, int>;
      return images;
    });
    await tester.pumpWidget(host(RemoteUploadImagesScreen(
        accountId: '101', initial: reversed, services: services)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Natural sort (unsaved)'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-remote-images-save')));
    expect(submitted!.length, 8);
    expect(submitted!['pagesel_1'], 8);
    expect(submitted!['pagesel_8'], 1);
    expect(find.text('8 images retained; 0 pending removal.'), findsOneWidget);
  });

  testWidgets('removing a remote image needs an additional save confirmation',
      (tester) async {
    when(() => repository.reorderImages('101', any(), any()))
        .thenAnswer((_) async => images);
    await tester.pumpWidget(host(RemoteUploadImagesScreen(
        accountId: '101', initial: images, services: services)));
    await tester.pumpAndSettle();
    final remove = find.byTooltip('Mark for removal on save').first;
    await tapVisible(tester, remove);
    verifyNever(() => repository.reorderImages('101', any(), any()));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-remote-images-save')));
    expect(find.text('Confirm removal of remote images'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => repository.reorderImages('101', any(), any()));
    expect(find.text('7 images retained; 1 pending removal.'), findsOneWidget);
  });

  testWidgets(
      'auth replacement removes folder data and ignores its pending refresh',
      (tester) async {
    final pending = Completer<UploadFoldersSnapshot>();
    when(() => repository.folders('101')).thenAnswer((_) => pending.future);
    await tester.pumpWidget(
        host(UploadFoldersScreen(accountId: '101', services: services)));
    await tester.pump();
    state = const AuthState(
        status: AuthStatus.unauthenticated, sessionGeneration: 2);
    events.add(state);
    pending.complete(folders);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('upload-folder-name-1')), findsNothing);
    expect(find.text('The login session changed.'), findsOneWidget);
  });

  testWidgets(
      'uncertain folder creation blocks repeat writes until a successful reload',
      (tester) async {
    when(() => repository.saveFolders('101', any(),
            renamed: any(named: 'renamed'),
            orderedIds: any(named: 'orderedIds'),
            newName: any(named: 'newName')))
        .thenThrow(const UploadFailure(UploadFailureKind.resultUncertain));
    await tester.pumpWidget(
        host(UploadFoldersScreen(accountId: '101', services: services)));
    await tester.pumpAndSettle();
    final newName = find.byKey(const ValueKey('upload-folder-new'));
    await tester.ensureVisible(newName);
    await tester.enterText(newName, 'Maybe created');
    await tester.pump();
    await tapVisible(tester, find.byKey(const ValueKey('upload-folders-save')));
    expect(find.textContaining('The previous result is uncertain'),
        findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-folders-save')))
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip('Reload'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('The previous result is uncertain'), findsNothing);
    expect(tester.widget<TextField>(newName).controller!.text, isEmpty);
    verify(() => repository.saveFolders('101', any(),
        renamed: any(named: 'renamed'),
        orderedIds: any(named: 'orderedIds'),
        newName: any(named: 'newName'))).called(1);
  });

  testWidgets(
      'partial receipt review explicitly stops old task without resending matches',
      (tester) async {
    final review = UploadReceiptReview(
        receiptId: 'r',
        taskId: 't',
        draftId: 'd',
        galleryUri: galleryUri,
        expectedNames: const ['one.png', 'two.png'],
        matchedFiles: const {'one.png': 12},
        missingNames: const ['two.png'],
        ambiguousNames: const []);
    when(() => services.reviewReceipt('r')).thenAnswer((_) async => review);
    when(() => services.acceptReceiptReview(any(),
        confirmed: true, stopRemaining: true)).thenAnswer((_) async {});
    await tester.pumpWidget(host(UploadReceiptReviewScreen(
        accountId: '101', receiptId: 'r', services: services)));
    await tester.pumpAndSettle();
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-receipt-confirm')));
    expect(find.text('Confirm partial receipt and stop the old task'),
        findsOneWidget);
    verifyNever(() => services.acceptReceiptReview(any(),
        confirmed: true, stopRemaining: true));
    await tester
        .tap(find.widgetWithText(FilledButton, 'Confirm reviewed result'));
    await tester.pumpAndSettle();
    verify(() => services.acceptReceiptReview(any(),
        confirmed: true, stopRemaining: true)).called(1);
    expect(find.text('Back to tasks'), findsOneWidget);
    expect(find.text('Receipt recorded'), findsOneWidget);
    expect(find.text('Receipt not confirmed; image retained locally'),
        findsOneWidget);
    expect(
        find.text('Matching entry found, awaiting your review'), findsNothing);
  });

  testWidgets(
      'ambiguous receipt cannot be marked confirmed from matching names alone',
      (tester) async {
    final review = UploadReceiptReview(
        receiptId: 'r',
        taskId: 't',
        draftId: 'd',
        galleryUri: galleryUri,
        expectedNames: const ['same.png'],
        matchedFiles: const {},
        missingNames: const [],
        ambiguousNames: const ['same.png']);
    when(() => services.reviewReceipt('r')).thenAnswer((_) async => review);
    await tester.pumpWidget(host(UploadReceiptReviewScreen(
        accountId: '101', receiptId: 'r', services: services)));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-receipt-confirm')))
            .onPressed,
        isNull);
    expect(find.text('Ambiguous, not confirmed'), findsOneWidget);
    verifyNever(() => services.acceptReceiptReview(any(),
        confirmed: true, stopRemaining: false));
  });

  testWidgets(
      'manual selection distinguishes same-content entries by page and prevents row reuse',
      (tester) async {
    const first = RemoteUploadImage(
        page: 1,
        positionField: 'p1',
        position: 1,
        name: 'first-remote.png',
        fileIndex: 77);
    const second = RemoteUploadImage(
        page: 2,
        positionField: 'p2',
        position: 2,
        name: 'second-remote.png',
        fileIndex: 77);
    final review = UploadReceiptReview(
        receiptId: 'copies',
        taskId: 't',
        draftId: 'd',
        galleryUri: galleryUri,
        expectedNames: const ['one.png', 'two.png'],
        matchedFiles: const {},
        missingNames: const [],
        ambiguousNames: const ['one.png', 'two.png'],
        remoteFiles: const [first, second]);
    when(() => services.reviewReceipt('copies'))
        .thenAnswer((_) async => review);
    Map<String, RemoteUploadImage>? submitted;
    when(() => services.acceptManualReceiptMapping(any(),
        selectedEntries: any(named: 'selectedEntries'),
        notReceivedNames: any(named: 'notReceivedNames'),
        confirmed: true)).thenAnswer((call) async {
      submitted = call.namedArguments[#selectedEntries]
          as Map<String, RemoteUploadImage>;
    });
    await tester.pumpWidget(host(UploadReceiptReviewScreen(
        accountId: '101', receiptId: 'copies', services: services)));
    await tester.pumpAndSettle();
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-receipt-manual')));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-manual-choose-one.png')));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-manual-remote-1')));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-manual-choose-two.png')));
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('upload-manual-remote-1')))
            .enabled,
        isFalse);
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-manual-remote-2')));
    expect(find.text('Selected website image: 2. second-remote.png'),
        findsOneWidget);
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-receipt-manual-confirm')));
    expect(find.text('one.png → 1. first-remote.png'), findsOneWidget);
    expect(find.text('two.png → 2. second-remote.png'), findsOneWidget);
    await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm review and stop old task'));
    await tester.pumpAndSettle();
    expect(submitted, {'one.png': first, 'two.png': second});
    expect(find.text('Manual review recorded for this item'), findsNWidgets(2));
  });

  testWidgets(
      'a single website occurrence cannot be selected twice to clear two local images',
      (tester) async {
    const only = RemoteUploadImage(
        page: 1,
        positionField: 'p1',
        position: 1,
        name: 'only-remote.png',
        fileIndex: 77);
    final review = UploadReceiptReview(
        receiptId: 'one-copy',
        taskId: 't',
        draftId: 'd',
        galleryUri: galleryUri,
        expectedNames: const ['one.png', 'two.png'],
        matchedFiles: const {},
        missingNames: const [],
        ambiguousNames: const ['one.png', 'two.png'],
        remoteFiles: const [only]);
    when(() => services.reviewReceipt('one-copy'))
        .thenAnswer((_) async => review);
    await tester.pumpWidget(host(UploadReceiptReviewScreen(
        accountId: '101', receiptId: 'one-copy', services: services)));
    await tester.pumpAndSettle();
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-receipt-manual')));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-manual-choose-one.png')));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-manual-remote-1')));
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-manual-choose-two.png')));
    final tile = tester
        .widget<ListTile>(find.byKey(const ValueKey('upload-manual-remote-1')));
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
    Navigator.of(tester
            .element(find.byKey(const ValueKey('upload-manual-remote-1'))))
        .pop();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-receipt-manual-confirm')))
            .onPressed,
        isNull);
    verifyNever(() => services.acceptManualReceiptMapping(any(),
        selectedEntries: any(named: 'selectedEntries'),
        notReceivedNames: any(named: 'notReceivedNames'),
        confirmed: true));
  });
}
