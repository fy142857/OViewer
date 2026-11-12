import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/services/floating_back_keyboard.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/widgets/floating_back_host.dart';
import 'package:oviewer/widgets/floating_back_setting.dart';

const ballKey = ValueKey('floating-back-button');
const circleKey = ValueKey('floating-back-circle');

class RejectingSettings extends SettingsRepository {
  RejectingSettings(super.storage);
  @override
  Future<void> setFloatingBack(value) async => throw StateError('save failed');
}

void main() {
  SettingsBloc? bloc;
  SettingsRepository? repositoryOverride;
  late LocalStorage storage;
  late GlobalKey<NavigatorState> navigator;
  late ValueNotifier<EdgeInsets> keyboard;
  late ValueNotifier<EdgeInsets> padding;
  int hides = 0, rootBuilds = 0, exits = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = LocalStorage();
    await storage.init();
    bloc = null;
    repositoryOverride = null;
    navigator = GlobalKey<NavigatorState>();
    keyboard = ValueNotifier(EdgeInsets.zero);
    padding = ValueNotifier(EdgeInsets.zero);
    hides = rootBuilds = exits = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
  });
  tearDown(() async {
    await bloc?.close();
    keyboard.dispose();
    padding.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  Widget page(String title, {Widget? body, bool drawer = false}) => Scaffold(
      appBar: AppBar(title: Text(title)),
      drawer: drawer
          ? const Drawer(child: Center(child: Text('drawer contents')))
          : null,
      body: body ?? const SizedBox.expand());
  SettingsBloc settings() {
    final repo = repositoryOverride ?? SettingsRepository(storage);
    return bloc ??= SettingsBloc(repo,
        initialState: SettingsBloc.readSaved(repo).copyWith(locale: 'en'));
  }

  Widget app({Widget? home, EdgeInsets gestureInsets = EdgeInsets.zero}) =>
      BlocProvider.value(
          value: settings(),
          child: MaterialApp(
              navigatorKey: navigator,
              builder: (context, child) => ValueListenableBuilder<EdgeInsets>(
                  valueListenable: keyboard,
                  child: child,
                  builder: (context, insets, child) =>
                      ValueListenableBuilder<EdgeInsets>(
                          valueListenable: padding,
                          child: child,
                          builder: (context, safe, child) => MediaQuery(
                              data: MediaQuery.of(context).copyWith(
                                  viewInsets: insets,
                                  viewPadding: safe,
                                  systemGestureInsets: gestureInsets),
                              child: FloatingBackHost(
                                  navigatorKey: navigator,
                                  child: child!,
                                  hideKeyboard: () async {
                                    hides++;
                                    FocusManager.instance.primaryFocus
                                        ?.unfocus();
                                    keyboard.value = EdgeInsets.zero;
                                  })))),
              home: Builder(builder: (_) {
                rootBuilds++;
                return home ?? page('Home', drawer: true);
              })));
  Future<void> save({double? size, double? x, double? y, bool? enabled}) async {
    final done = Completer<void>();
    settings().add(
        UpdateFloatingBack(done, size: size, x: x, y: y, enabled: enabled));
    await done.future;
  }

  Future<void> open(Widget widget, WidgetTester tester) async {
    unawaited(navigator.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => widget)));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'global button pops page and popup, closes drawer, never exits Home',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byKey(ballKey), findsOneWidget);
    await open(page('Second'), tester);
    unawaited(showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Popup'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ballKey));
    await tester.pumpAndSettle();
    expect(find.text('Popup'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
    await tester.tap(find.byKey(ballKey));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('drawer contents'), findsOneWidget);
    await tester.tap(find.byKey(ballKey));
    await tester.pumpAndSettle();
    expect(find.text('drawer contents'), findsNothing);
    await tester.tap(find.byKey(ballKey));
    await tester.pumpAndSettle();
    expect(exits, 0);
    expect(find.text('Home'), findsOneWidget);
  });
  testWidgets(
      'return guard is respected and pending callbacks do not run twice',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final gate = Completer<bool>();
    var calls = 0;
    // ignore: deprecated_member_use
    await open(
        WillPopScope(
            onWillPop: () {
              calls++;
              return gate.future;
            },
            child: page('Sending')),
        tester);
    await tester.tap(find.byKey(ballKey));
    await tester.pump();
    await tester.tap(find.byKey(ballKey));
    await tester.pump();
    expect(calls, 1);
    gate.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Sending'), findsOneWidget);
  });
  testWidgets('keyboard consumes first tap and position returns after hiding',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await open(page('Input', body: const TextField()), tester);
    final before = tester.getRect(find.byKey(ballKey));
    keyboard.value = const EdgeInsets.only(bottom: 350);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(ballKey)).bottom, lessThan(before.bottom));
    await tester.tap(find.byKey(ballKey));
    await tester.pumpAndSettle();
    expect(hides, 1);
    expect(find.text('Input'), findsOneWidget);
    expect(tester.getRect(find.byKey(ballKey)), before);
    expect(storage.getFloatingBack().y, .7);
    await tester.tap(find.byKey(ballKey));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
  });
  testWidgets(
      'drag stays put, persists, does not pop or rebuild the underlying route',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.byKey(ballKey));
    final builds = rootBuilds;
    await tester.drag(find.byKey(ballKey), const Offset(-180, -120));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(find.byKey(ballKey));
    expect(after.dx, lessThan(before.dx - 100));
    expect(after.dy, lessThan(before.dy - 60));
    expect(rootBuilds, builds);
    expect(exits, 0);
    expect(storage.getFloatingBack().x, lessThan(1));
    await open(page('Second'), tester);
    expect(tester.getTopLeft(find.byKey(ballKey)), after);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(ballKey)), after);
  });
  testWidgets(
      'button bounds follow safe areas, size, rotation and keyboard without rewriting position',
      (tester) async {
    await save(x: 1, y: 1, size: 72);
    padding.value = const EdgeInsets.fromLTRB(24, 30, 20, 34);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester
        .pumpWidget(app(gestureInsets: const EdgeInsets.only(left: 40)));
    await tester.pumpAndSettle();
    Rect rect() => tester.getRect(find.byKey(ballKey));
    expect(rect().right, 368);
    expect(rect().bottom, 754);
    await tester.binding.setSurfaceSize(const Size(800, 400));
    await tester.pumpAndSettle();
    expect(rect().right, 768);
    expect(rect().bottom, 354);
    keyboard.value = const EdgeInsets.only(bottom: 200);
    await tester.pumpAndSettle();
    expect(rect().bottom, 188);
    await tester.drag(find.byKey(ballKey), const Offset(-2000, -2000));
    await tester.pumpAndSettle();
    expect(rect().left, 52);
    expect(rect().top, 42);
    expect(storage.getFloatingBack().x, 0);
    expect(storage.getFloatingBack().y, 0);
  });
  testWidgets(
      'slider previews immediately, commits on release, toggle preserves size and position',
      (tester) async {
    await tester.pumpWidget(
        app(home: page('Settings', body: const FloatingBackSetting())));
    await tester.pumpAndSettle();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('floating-back-size')));
    slider.onChanged!(64);
    await tester.pump();
    expect(tester.getSize(find.byKey(circleKey)).width, 64);
    expect(storage.getFloatingBack().size, 48);
    slider.onChangeEnd!(64);
    await tester.pumpAndSettle();
    expect(storage.getFloatingBack().size, 64);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byKey(ballKey), findsNothing);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('floating-back-size')))
            .onChanged,
        isNull);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(circleKey)).width, 64);
    expect(storage.getFloatingBack().y, .7);
  });
  testWidgets(
      '48 minimum hit target leaves unrelated taps and scrolls reachable',
      (tester) async {
    await save(size: 32);
    var taps = 0;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(app(
        home: page('Scroll',
            body: ListView(controller: scroll, children: [
              TextButton(
                  onPressed: () => taps++,
                  child: const Text('Underlying action')),
              const SizedBox(height: 1600),
            ]))));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(ballKey)), const Size(48, 48));
    expect(tester.getSize(find.byKey(circleKey)), const Size(32, 32));
    await tester.tap(find.text('Underlying action'));
    await tester.pump();
    expect(taps, 1);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(80));
    expect(exits, 0);
  });
  testWidgets('native keyboard bridge is used for application input',
      (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FloatingBackKeyboard.channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FloatingBackKeyboard.channel, null));
    await FloatingBackKeyboard.hide();
    expect(calls, ['hideKeyboard']);
  });

  testWidgets(
      'failed size preview and drag restore the last confirmed configuration',
      (tester) async {
    repositoryOverride = RejectingSettings(storage);
    await tester.pumpWidget(
        app(home: page('Settings', body: const FloatingBackSetting())));
    await tester.pumpAndSettle();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('floating-back-size')));
    slider.onChanged!(64);
    await tester.pump();
    expect(tester.getSize(find.byKey(circleKey)).width, 64);
    slider.onChangeEnd!(64);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(circleKey)).width, 48);
    expect(find.text('Could not save floating button settings. Please retry.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.byKey(ballKey));
    await tester.drag(find.byKey(ballKey), const Offset(-100, -80));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(ballKey)), before);
    expect(storage.getFloatingBack().x, 1);
    expect(find.text('Could not save floating button settings. Please retry.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'cancelled drag does not save or navigate; accessibility identifies the button',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Back (draggable)'), findsOneWidget);
      expect(
          tester
              .getSemantics(find.bySemanticsLabel('Back (draggable)'))
              .rect
              .size,
          const Size(48, 48));
      final before = tester.getTopLeft(find.byKey(ballKey));
      final pointer =
          await tester.startGesture(tester.getCenter(find.byKey(ballKey)));
      await pointer.moveBy(const Offset(-100, -80));
      await tester.pump();
      await pointer.moveBy(const Offset(-50, -40));
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(ballKey)), isNot(before));
      await pointer.cancel();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(ballKey)), before);
      expect(storage.prefs.containsKey('floating_back'), false);
      expect(exits, 0);
    } finally {
      semantics.dispose();
    }
  });
}
