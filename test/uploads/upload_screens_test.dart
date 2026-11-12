import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/core/network/cookie_manager.dart' as app;
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/data/upload_repository.dart';
import 'package:oviewer/features/uploads/data/upload_store.dart';
import 'package:oviewer/features/uploads/files/upload_asset.dart';
import 'package:oviewer/features/uploads/presentation/upload_editor_screen.dart';
import 'package:oviewer/features/uploads/presentation/upload_home_screen.dart';
import 'package:oviewer/features/uploads/presentation/upload_web_page.dart';
import 'package:oviewer/features/uploads/upload_services.dart';
import 'package:oviewer/models/user_profile.dart';

class MockServices extends Mock implements UploadServices {}

class MockUploadRepository extends Mock implements UploadRepository {}

class MockStore extends Mock implements UploadStore {}

class MockAuthBloc extends Mock implements AuthBloc {}

class MockUploadCookies extends Mock implements app.CookieManager {}

const fields = <String, List<String>>{
  'gname_en': ['Local example'],
  'category': ['9'],
  'langtag': ['1058'],
  'langtype': ['0'],
  'tos': ['on'],
};

UploadDraft draft(
        {String id = 'draft1',
        String account = '101',
        List<PreparedUploadAsset> assets = const []}) =>
    UploadDraft(id: id, accountId: account, fields: fields, assets: assets);

UploadEditorSnapshot editor() => const UploadProtocol().editor(
    File('test/fixtures/uploads/new.html').readAsStringSync(),
    Uri.parse('https://upld.e-hentai.org/managegallery?act=new'));

UploadManagerSnapshot manager(
        {List<ManagedUploadGallery> galleries = const []}) =>
    UploadManagerSnapshot(
        form: UploadForm(
            action: uploadOrigin.resolve('manage'), fields: const {}),
        api: const UploadApiSession(101, 'fixture-key'),
        galleries: galleries,
        folders: const [],
        sort: 'd',
        direction: 'a');

AuthState loggedIn(String account, int generation) => AuthState(
    status: AuthStatus.authenticated,
    sessionGeneration: generation,
    profile: UserProfile(memberId: account, isLoggedIn: true));

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  const browserCookiesChannel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
  late MockServices services;
  late MockUploadRepository repository;
  late MockStore store;
  late MockAuthBloc auth;
  late AuthState authState;
  late StreamController<AuthState> authEvents;
  late StreamController<void> storeEvents;
  late Directory root;
  late List<UploadDraft> savedLocally;

  setUpAll(() {
    registerFallbackValue(draft());
    registerFallbackValue(Uri.parse('https://ehwiki.org/'));
    registerFallbackValue(const PreparedUploadAsset(
        relativePath: 'imports/fallback',
        displayName: 'fallback',
        size: 1,
        sha256: 'fallback',
        crc32: 1,
        format: null,
        width: null,
        height: null));
  });
  setUp(() {
    services = MockServices();
    repository = MockUploadRepository();
    store = MockStore();
    auth = MockAuthBloc();
    authState = loggedIn('101', 1);
    authEvents = StreamController<AuthState>.broadcast(sync: true);
    storeEvents = StreamController<void>.broadcast(sync: true);
    root = Directory.systemTemp.createTempSync('oviewer-upload-ui-');
    savedLocally = [];
    when(() => auth.state).thenAnswer((_) => authState);
    when(() => auth.stream).thenAnswer((_) => authEvents.stream);
    when(() => services.repository).thenReturn(repository);
    when(() => services.store).thenAnswer((_) async => store);
    when(() => services.publicationProtocolVerified).thenReturn(false);
    when(() => services.supportsNativePublication).thenReturn(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browserCookiesChannel,
            (call) async => call.method == 'getCookies' ? [] : true);
    when(() => store.root).thenReturn(root);
    when(() => store.changes).thenAnswer((_) => storeEvents.stream);
    when(() => store.drafts(any())).thenAnswer((_) async => []);
    when(() => repository.manager(any())).thenAnswer((_) async => manager());
    when(() => services.transferSnapshot())
        .thenAnswer((_) async => {'tasks': [], 'receipts': []});
    when(() => services.pendingWrite(any())).thenAnswer((_) async => null);
    when(() => services.prepareVisibilityChange(any()))
        .thenAnswer((_) async => null);
    when(() => services.pendingAssets(any())).thenAnswer((call) async =>
        (call.positionalArguments.single as UploadDraft).assets);
    when(() => services.assetProgress(any(), snapshot: any(named: 'snapshot')))
        .thenAnswer((call) async => (call.positionalArguments.single
                as UploadDraft)
            .assets
            .map((asset) => UploadAssetProgress(asset, UploadAssetState.local))
            .toList());
    when(() => services.saveLocal(any())).thenAnswer((invocation) async {
      final value = invocation.positionalArguments.single as UploadDraft;
      savedLocally.add(value);
      return value;
    });
    when(() => services.openExternal(any())).thenAnswer((_) async {});
    when(() => services.cancelPreparation()).thenAnswer((_) async {});
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browserCookiesChannel, null);
    await authEvents.close();
    await storeEvents.close();
    root.deleteSync(recursive: true);
  });

  Widget host(Widget child) => BlocProvider<AuthBloc>.value(
      value: auth,
      child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('zh')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          routes: {'/login': (_) => const Scaffold(body: Text('Login page'))},
          home: child));

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
      'official manager entry stays in-app and releases its own handoff generation',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('oviewer/upload_web_proxy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cookie = MockUploadCookies();
    final sync = Completer<void>();
    when(() => services.cookies).thenReturn(cookie);
    when(() => cookie.sessionRevision).thenReturn(1);
    when(() => cookie.getUploadCookieHeader())
        .thenAnswer((_) async => 'ipb_member_id=101; ipb_pass_hash=fixture');
    when(() => cookie.syncToWebView(any())).thenAnswer((_) => sync.future);
    when(() => services.prepareWebHandoff()).thenAnswer((_) async => 42);
    when(() => services.endWebHandoff(generation: any(named: 'generation')))
        .thenAnswer((_) async {});
    messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'begin' || call.method == 'check' ? true : null);
    try {
      await tester.pumpWidget(host(UploadHomeScreen(services: services)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Official manager'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(UploadWebPage), findsOneWidget);
      verify(() => services.prepareWebHandoff()).called(1);
      verifyNever(() => services.openExternal(uploadOrigin.resolve('manage')));
      await tester.tap(find.byTooltip('Close official page'));
      await tester.pumpAndSettle();
      verify(() => services.endWebHandoff(generation: 42)).called(1);
      sync.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UploadWebPage), findsNothing);
    } finally {
      if (!sync.isCompleted) sync.complete();
      await unmount(tester);
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'editor website entry saves locally and restores dirty fields with its owner token',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('oviewer/upload_web_proxy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cookie = MockUploadCookies();
    final sync = Completer<void>();
    final original = draft().copyWith(fields: {
      ...fields,
      'gname_en': ['Still-local-dirty']
    }, dirty: true);
    // openDraft deliberately leaves a dirty local draft's fields intact.
    final returned = original.copyWith(dirty: true);
    when(() => services.cookies).thenReturn(cookie);
    when(() => cookie.sessionRevision).thenReturn(1);
    when(() => cookie.getUploadCookieHeader())
        .thenAnswer((_) async => 'ipb_member_id=101; ipb_pass_hash=fixture');
    when(() => cookie.syncToWebView(any())).thenAnswer((_) => sync.future);
    when(() => services.prepareWebHandoff(draft: any(named: 'draft')))
        .thenAnswer((_) async {
      expect(savedLocally, isNotEmpty);
      return 77;
    });
    when(() => services.finishWebHandoff(any(),
            generation: any(named: 'generation')))
        .thenAnswer((_) async => UploadEditingSession(returned, editor()));
    messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'begin' || call.method == 'check' ? true : null);
    try {
      await tester.pumpWidget(host(UploadEditorScreen(
          session: UploadEditingSession(original, editor()),
          services: services)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Official manager'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(UploadWebPage), findsOneWidget);
      await tester.tap(find.byTooltip('Close official page'));
      await tester.pumpAndSettle();
      verify(() => services.finishWebHandoff(any(), generation: 77)).called(1);
      verifyNever(() => services.openExternal(any()));
      sync.complete();
      await tester.pumpAndSettle();
      expect(find.text('Still-local-dirty'), findsOneWidget);
    } finally {
      if (!sync.isCompleted) sync.complete();
      await unmount(tester);
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'clean acknowledged draft adopts website changes instead of old form dirtiness',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('oviewer/upload_web_proxy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cookie = MockUploadCookies();
    final sync = Completer<void>();
    UploadEditorSnapshot snapshot(String title) {
      final source = File('test/fixtures/uploads/uploaded.html')
          .readAsStringSync()
          .replaceFirstMapped(
              RegExp(r'(<input[^>]*name="gname_en"[^>]*value=")[^"]*(")'),
              (match) => '${match[1]}${htmlEscape.convert(title)}${match[2]}');
      return const UploadProtocol()
          .editor(source, uploadOrigin.resolve('managegallery?ulgid=12345'));
    }

    Map<String, List<String>> values(UploadEditorSnapshot snapshot) => {
          for (final name in uploadEditableFields)
            if (snapshot.form.fields[name] != null)
              name: snapshot.form.fields[name]!.values,
        };
    final old = snapshot('Old server');
    final fresh = snapshot('Website changed');
    expect(old.form.fields['gname_en']!.values, ['Old server']);
    expect(fresh.form.fields['gname_en']!.values, ['Website changed']);
    final original = UploadDraft(
        id: 'draft1',
        accountId: '101',
        assets: [],
        serverUri: old.uri,
        fields: {
          ...values(old),
          'gname_en': ['Acknowledged local']
        },
        serverFields: values(old),
        dirty: true);
    final returned = original.copyWith(
        fields: values(fresh), serverFields: values(fresh), dirty: false);
    when(() => services.cookies).thenReturn(cookie);
    when(() => cookie.sessionRevision).thenReturn(1);
    when(() => cookie.getUploadCookieHeader())
        .thenAnswer((_) async => 'ipb_member_id=101; ipb_pass_hash=fixture');
    when(() => cookie.syncToWebView(any())).thenAnswer((_) => sync.future);
    // Simulates a native upload's store acknowledgement, arriving before the
    // form receives a refreshed editor snapshot.
    when(() => services.saveLocal(any())).thenAnswer((invocation) async {
      final value = invocation.positionalArguments.single as UploadDraft;
      savedLocally.add(value);
      return value.copyWith(serverFields: value.fields, dirty: false);
    });
    when(() => services.prepareWebHandoff(draft: any(named: 'draft')))
        .thenAnswer((_) async => 78);
    when(() => services.finishWebHandoff(any(),
            generation: any(named: 'generation')))
        .thenAnswer((_) async => UploadEditingSession(returned, fresh));
    messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'begin' || call.method == 'check' ? true : null);
    try {
      await tester.pumpWidget(host(UploadEditorScreen(
          session: UploadEditingSession(original, old), services: services)));
      await tester.pumpAndSettle();
      expect(find.text('Acknowledged local'), findsOneWidget);
      await tester.tap(find.byTooltip('Official manager'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('Close official page'));
      await tester.pumpAndSettle();
      verify(() => services.finishWebHandoff(any(), generation: 78)).called(1);
      sync.complete();
      await tester.pumpAndSettle();
      expect(find.text('Website changed'), findsOneWidget);
      expect(find.text('Acknowledged local'), findsNothing);
    } finally {
      if (!sync.isCompleted) sync.complete();
      await unmount(tester);
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('guest can read rules and login without loading private lists',
      (tester) async {
    authState = const AuthState(status: AuthStatus.unauthenticated);
    await tester.pumpWidget(host(UploadHomeScreen(services: services)));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to upload'), findsOneWidget);
    expect(find.byKey(const ValueKey('upload-rule-account')), findsOneWidget);
    verifyNever(() => repository.manager(any()));
    verifyNever(() => store.drafts(any()));
    await tapVisible(tester, find.text('Sign in to upload'));
    expect(find.text('Login page'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('home separates remote galleries, local drafts and task failures',
      (tester) async {
    when(() => store.drafts('101')).thenAnswer((_) async => [draft()]);
    when(() => services.transferSnapshot()).thenThrow(MissingPluginException());
    await tester.pumpWidget(host(UploadHomeScreen(services: services)));
    await tester.pumpAndSettle();
    expect(find.text('My galleries'), findsOneWidget);
    await tapVisible(tester, find.text('Local drafts'));
    expect(find.text('Local example'), findsOneWidget);
    expect(find.textContaining('Device only'), findsOneWidget);
    await tapVisible(tester, find.text('Upload tasks'));
    expect(find.textContaining('Task state is not confirmed'), findsOneWidget);
    expect(find.text('No upload tasks.'), findsNothing);
    await unmount(tester);
  });

  testWidgets(
      'late remote results cannot reveal the previous account after logout',
      (tester) async {
    final pending = Completer<UploadManagerSnapshot>();
    when(() => repository.manager('101')).thenAnswer((_) => pending.future);
    await tester.pumpWidget(host(UploadHomeScreen(services: services)));
    await tester.pump();
    authState = const AuthState(
        status: AuthStatus.unauthenticated, sessionGeneration: 2);
    authEvents.add(authState);
    await tester.pump();
    pending.complete(manager(galleries: [
      ManagedUploadGallery(
          title: 'Private old gallery',
          date: 'Today',
          category: 'Private',
          fileCount: 1,
          section: '1',
          actions: {'Manage': uploadOrigin.resolve('managegallery?ulgid=123')})
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Private old gallery'), findsNothing);
    expect(find.text('Sign in to upload'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('home filters task snapshots and local drafts by current account',
      (tester) async {
    when(() => store.drafts('101')).thenAnswer(
        (_) async => [draft(), draft(id: 'foreign', account: '202')]);
    when(() => services.transferSnapshot()).thenAnswer((_) async => {
          'tasks': [
            {
              'taskId': 'draft1',
              'accountId': '101',
              'state': 'completed',
              'reason': 'redirect_requires_verification',
              'items': [
                {'state': 'confirmed'}
              ]
            },
            {
              'taskId': 'foreign-private-task',
              'accountId': '202',
              'state': 'sending',
              'items': []
            },
          ]
        });
    await tester.pumpWidget(host(UploadHomeScreen(services: services)));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Local drafts'));
    expect(find.text('Local example'), findsOneWidget);
    await tapVisible(tester, find.text('Upload tasks'));
    expect(find.text('1 / 1 batches confirmed'), findsOneWidget);
    expect(find.textContaining('Check the file'), findsNothing);
    expect(find.text('Sending'), findsNothing);
    expect(find.textContaining('foreign-private-task'), findsNothing);
    await unmount(tester);
  });

  testWidgets(
      'field edits autosave locally and never implicitly submit to website',
      (tester) async {
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services, session: UploadEditingSession(draft(), editor()))));
    await tester.pumpAndSettle();
    final title = find.byKey(const ValueKey('upload-field-gname_en'));
    await tester.enterText(title, 'Unpublished local edit');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(savedLocally.last.title, 'Unpublished local edit');
    verifyNever(() => services.saveRemote(any()));
    verifyNever(() => services.startUpload(any(),
        wifiOnly: any(named: 'wifiOnly'), language: any(named: 'language')));
    expect(find.textContaining('no website gallery has been created'),
        findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
      'explicit website save changes status only after confirmed service result',
      (tester) async {
    final original = draft();
    final remote = editor();
    final saved = original.copyWith(
        fields: {
          for (final field in remote.form.fields.values)
            if (uploadEditableFields.contains(field.name))
              field.name: field.values,
          ...fields,
        },
        serverUri: uploadOrigin.resolve('managegallery?ulgid=123'),
        dirty: false);
    final savedEditor = UploadEditorSnapshot(
        uri: saved.serverUri!,
        form: remote.form,
        api: remote.api,
        buttons: remote.buttons,
        images: remote.images,
        metadata: remote.metadata,
        links: remote.links);
    when(() => services.saveRemote(any()))
        .thenAnswer((_) async => UploadEditingSession(saved, savedEditor));
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services, session: UploadEditingSession(original, remote))));
    await tester.pumpAndSettle();
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-action-savebutton')));
    verify(() => services.saveRemote(any())).called(1);
    expect(find.text('Saved to the website.'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
      'partial import keeps successful files and displays named failures',
      (tester) async {
    const asset = PreparedUploadAsset(
        relativePath: 'imports/file.png',
        displayName: 'good.png',
        size: 5000,
        sha256: 'abc',
        crc32: 1,
        format: UploadImageFormat.png,
        width: 300,
        height: 400);
    when(() => services.importFiles(any(), photos: false, language: 'en'))
        .thenThrow(UploadImportException(draft(assets: [asset]), const [
      {'displayName': 'broken.png', 'reason': 'corrupt_image'},
    ]));
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services, session: UploadEditingSession(draft(), editor()))));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('upload-import-files')));
    expect(find.textContaining('1 local images'), findsOneWidget);
    expect(find.text('broken.png: The image is corrupt or incomplete.'),
        findsOneWidget);
    verifyNever(() => services.saveRemote(any()));
    await unmount(tester);
  });

  testWidgets(
      'changing auth hides editor content and ignores late import result',
      (tester) async {
    final pending = Completer<UploadDraft>();
    when(() => services.importFiles(any(), photos: false, language: 'en'))
        .thenAnswer((_) => pending.future);
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services, session: UploadEditingSession(draft(), editor()))));
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('upload-import-files'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pump();
    authState = loggedIn('202', 2);
    authEvents.add(authState);
    await tester.pump();
    pending.complete(draft().copyWith(fields: const {
      'gname_en': ['Old account secret']
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('Old account secret'), findsNothing);
    expect(find.byKey(const ValueKey('upload-field-gname_en')), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('malformed native snapshot does not silently enable uploading',
      (tester) async {
    when(() => services.transferSnapshot()).thenAnswer((_) async => {});
    const asset = PreparedUploadAsset(
        relativePath: 'imports/file.png',
        displayName: 'good.png',
        size: 5000,
        sha256: 'abc',
        crc32: 1,
        format: UploadImageFormat.png,
        width: 300,
        height: 400);
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services,
        session: UploadEditingSession(draft(assets: [asset]), editor()))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-action-uploadbutton')))
            .onPressed,
        isNull);
    expect(find.text('Retry task status'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
      'upload confirmation defaults to current network and never publishes',
      (tester) async {
    const asset = PreparedUploadAsset(
        relativePath: 'imports/file.png',
        displayName: 'good.png',
        size: 5000,
        sha256: 'abc',
        crc32: 1,
        format: UploadImageFormat.png,
        width: 300,
        height: 400);
    final original = draft(assets: [asset]);
    var started = false;
    when(() => services.transferSnapshot()).thenAnswer((_) async => {
          'tasks': started
              ? [
                  {
                    'taskId': 'attempt-1',
                    'draftId': 'draft1',
                    'accountId': '101',
                    'state': 'queued',
                    'blocksEditing': true,
                    'items': []
                  }
                ]
              : []
        });
    when(() => services.startUpload(any(), wifiOnly: false, language: 'en'))
        .thenAnswer((_) async {
      started = true;
    });
    when(() => store.draft('101', 'draft1'))
        .thenAnswer((_) async => original.copyWith(
              assets: [asset.withUploadName('0001_good.png')],
              serverUri: uploadOrigin.resolve('managegallery?ulgid=123'),
            ));
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services,
        session: UploadEditingSession(original, editor()))));
    await tester.pumpAndSettle();
    final start = find.byKey(const ValueKey('upload-action-uploadbutton'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Confirm upload to website draft'), findsOneWidget);
    expect(find.text('Uses the current network, including mobile data.'),
        findsOneWidget);
    verifyNever(
        () => services.startUpload(any(), wifiOnly: false, language: 'en'));
    await tester.tap(find.widgetWithText(FilledButton, 'Start upload').last);
    await tester.pumpAndSettle();
    verify(() => services.startUpload(any(), wifiOnly: false, language: 'en'))
        .called(1);
    verifyNever(() => services.publish(any()));
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await unmount(tester);
  });

  testWidgets(
      'file review sorts and removes local entries without deleting files',
      (tester) async {
    final imports = Directory('${root.path}/imports')..createSync();
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lLkAAAAASUVORK5CYII=');
    final tenFile = File('${imports.path}/ten.png')..writeAsBytesSync(png);
    final twoFile = File('${imports.path}/two.png')..writeAsBytesSync(png);
    final originalFile = File('${root.path}/source-original.png')
      ..writeAsBytesSync(png);
    const ten = PreparedUploadAsset(
        relativePath: 'imports/ten.png',
        displayName: '10.png',
        size: 5000,
        sha256: 'ten',
        crc32: 1,
        format: UploadImageFormat.png,
        width: 300,
        height: 400);
    const two = PreparedUploadAsset(
        relativePath: 'imports/two.png',
        displayName: '2.png',
        size: 5000,
        sha256: 'two',
        crc32: 2,
        format: UploadImageFormat.png,
        width: 300,
        height: 400);
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services,
        session: UploadEditingSession(draft(assets: [ten, two]), editor()))));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('upload-review-files')));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Preview and order images'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Natural sort'));
    await tester.pumpAndSettle();
    expect(savedLocally.last.assets.map((a) => a.displayName),
        ['2.png', '10.png']);
    await tapVisible(tester, find.text('Remove from local upload list').first);
    expect(savedLocally.last.assets.map((a) => a.displayName), ['10.png']);
    expect(tenFile.existsSync(), isTrue);
    expect(twoFile.existsSync(), isTrue);
    expect(originalFile.existsSync(), isTrue);
    verifyNever(() => services.saveRemote(any()));
    await unmount(tester);
  });

  testWidgets('back navigation waits for local saving before leaving editor',
      (tester) async {
    final session = UploadEditingSession(draft(), editor());
    await tester.pumpWidget(host(Builder(
        builder: (context) => Scaffold(
            body: TextButton(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => UploadEditorScreen(
                            services: services, session: session))),
                child: const Text('Open editor'))))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    final title = find.byKey(const ValueKey('upload-field-gname_en'));
    await tester.enterText(title, 'Saved on back');
    final navigator = Navigator.of(tester.element(title));
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Open editor'), findsOneWidget);
    expect(savedLocally.last.title, 'Saved on back');
    await unmount(tester);
  });

  testWidgets(
      'pending creation survives refresh and never offers a blind second save',
      (tester) async {
    const pending = PendingUploadWrite('operation1', 'create', null, {
      'gname_en': ['Submitted title']
    });
    when(() => services.pendingWrite(any())).thenAnswer((_) async => pending);
    when(() => services.openDraft('101', 'draft1'))
        .thenAnswer((_) async => UploadEditingSession(draft(), editor()));
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services, session: UploadEditingSession(draft(), editor()))));
    await tester.pumpAndSettle();
    expect(find.text('Previous creation needs reconciliation'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-action-savebutton')))
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip('Refresh website state'));
    await tester.pumpAndSettle();
    expect(find.text('Previous creation needs reconciliation'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-action-savebutton')))
            .onPressed,
        isNull);
    verifyNever(() => services.saveRemote(any()));
    await unmount(tester);
  });

  testWidgets(
      'clearing an ineffective operation requires explicit verification and does not retry',
      (tester) async {
    PendingUploadWrite? pending =
        const PendingUploadWrite('operation1', 'create', null, {
      'gname_en': ['Submitted title']
    });
    when(() => services.pendingWrite(any())).thenAnswer((_) async => pending);
    when(() => services.retryAfterVerifiedNoChange(any(),
        confirmed: true,
        expectedOperationId: 'operation1')).thenAnswer((_) async {
      pending = null;
    });
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services, session: UploadEditingSession(draft(), editor()))));
    await tester.pumpAndSettle();
    await tapVisible(
        tester, find.byKey(const ValueKey('upload-pending-no-change')));
    expect(find.text('Confirm the request had no effect'), findsOneWidget);
    verifyNever(() => services.retryAfterVerifiedNoChange(any(),
        confirmed: true, expectedOperationId: 'operation1'));
    await tester.tap(find.widgetWithText(TextButton, 'Verified no effect'));
    await tester.pumpAndSettle();
    verify(() => services.retryAfterVerifiedNoChange(any(),
        confirmed: true, expectedOperationId: 'operation1')).called(1);
    expect(find.text('Previous creation needs reconciliation'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('upload-action-savebutton')))
            .onPressed,
        isNotNull);
    verifyNever(() => services.saveRemote(any()));
    await unmount(tester);
  });

  testWidgets(
      'unsupported image conversion needs confirmation and preserves the original on failure',
      (tester) async {
    const asset = PreparedUploadAsset(
        relativePath: 'imports/photo.heic',
        displayName: 'photo.heic',
        size: 5000,
        sha256: 'heic',
        crc32: 1,
        format: null,
        width: null,
        height: null,
        issues: [ValidationIssue('unsupported_image')]);
    final imports = Directory('${root.path}/imports')..createSync();
    final original = File('${imports.path}/photo.heic')
      ..writeAsBytesSync([1, 2, 3]);
    when(() => services.convertAsset(any(), any()))
        .thenThrow(const UploadFileException('unsupported_conversion'));
    await tester.pumpWidget(host(UploadEditorScreen(
        services: services,
        session: UploadEditingSession(draft(assets: [asset]), editor()))));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('upload-review-files')));
    await tapVisible(
        tester, find.widgetWithText(TextButton, 'Try converting to PNG'));
    verifyNever(() => services.convertAsset(any(), any()));
    await tester.tap(find.widgetWithText(FilledButton, 'Try conversion'));
    await tester.pumpAndSettle();
    verify(() => services.convertAsset(any(), any())).called(1);
    expect(find.textContaining('This device cannot convert'), findsOneWidget);
    expect(original.readAsBytesSync(), [1, 2, 3]);
    expect(find.text('1. photo.heic'), findsOneWidget);
    await unmount(tester);
  });
}
