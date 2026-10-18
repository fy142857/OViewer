import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/router/reader_route.dart';
import 'package:oviewer/core/router/route_observer.dart';
import 'package:oviewer/widgets/reader_presentation.dart';

void main() {
  late List<String> modes;
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  setUp(() {
    modes = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode')
        modes.add(call.arguments as String);
      return null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  testWidgets(
      'fullscreen settles before readiness and repeated control state is idempotent',
      (tester) async {
    ReaderPresentationState? owner;
    await tester.pumpWidget(
        MaterialApp(home: ReaderPresentation(child: Builder(builder: (context) {
      owner = ReaderPresentation.maybeOf(context);
      return Text(owner!.ready ? 'ready' : 'waiting');
    }))));
    expect(find.text('waiting'), findsOneWidget);
    await frames(tester);
    expect(find.text('ready'), findsOneWidget);
    owner!.showControls(false);
    owner!.showControls(false);
    await tester.pump();
    expect(modes, ['SystemUiMode.immersiveSticky']);
    owner!.showControls(true);
    owner!.showControls(true);
    await tester.pump();
    expect(modes, ['SystemUiMode.immersiveSticky', 'SystemUiMode.edgeToEdge']);
    expect(find.text('ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'return before fullscreen completes cannot reopen or show late reader',
      (tester) async {
    final pending = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        modes.add(call.arguments as String);
        if (call.arguments == 'SystemUiMode.immersiveSticky')
          await pending.future;
      }
      return null;
    });
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [appRouteObserver],
        home: const Scaffold(body: Text('home'))));
    nav.currentState!.push(ReaderRoute(builder: (_) => const Text('reader')));
    await tester.pump();
    nav.currentState!.pop();
    await tester.pump();
    pending.complete();
    await frames(tester);
    expect(modes.last, 'SystemUiMode.edgeToEdge');
    expect(find.text('reader'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
        'reader retains native forward transition and platform exit ($platform)',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final route = ReaderRoute(builder: (_) => const Text('reader'));
      expect(route.transitionDuration, const Duration(milliseconds: 300));
      expect(route.allowSnapshotting, platform != TargetPlatform.android);
      expect(
          route.reverseTransitionDuration,
          platform == TargetPlatform.android
              ? Duration.zero
              : const Duration(milliseconds: 300));
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [appRouteObserver],
          home: const Scaffold()));
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.iOS) {
        final gesture = await tester.startGesture(const Offset(2, 300));
        await gesture.moveBy(const Offset(30, 0));
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(find.text('reader'), findsOneWidget);
        await tester.dragFrom(const Offset(2, 300), const Offset(650, 0));
      } else {
        nav.currentState!.pop();
      }
      await tester.pumpAndSettle();
      expect(find.text('reader'), findsNothing);
      expect(modes.last, 'SystemUiMode.edgeToEdge');
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
