import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/router/reader_route.dart';
import 'package:oviewer/core/router/app_page_route.dart';
import 'package:oviewer/core/router/route_observer.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  for (final sliver in [false, true]) {
    testWidgets(
        'reader keeps parent stable through late system bars (sliver=$sliver)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final insets =
          ValueNotifier<EdgeInsets>(const EdgeInsets.only(top: 24, bottom: 20));
      final nav = GlobalKey<NavigatorState>();
      final scroll = ScrollController(initialScrollOffset: 96);
      final source = AppPageRoute<void>(
          allowSnapshotting: false,
          builder: (_) => Scaffold(
              key: const ValueKey('source-scaffold'),
              appBar: sliver
                  ? null
                  : AppBar(
                      title:
                          const Text('Source', key: ValueKey('source-header'))),
              body: sliver
                  ? CustomScrollView(controller: scroll, slivers: [
                      const SliverAppBar(
                          pinned: true,
                          expandedHeight: 200,
                          title:
                              Text('Source', key: ValueKey('source-header'))),
                      SliverFixedExtentList(
                          itemExtent: 56,
                          delegate: SliverChildBuilderDelegate(
                              (_, i) => Text('row $i',
                                  key: ValueKey('source-row-$i')),
                              childCount: 40)),
                    ])
                  : ListView.builder(
                      controller: scroll,
                      itemCount: 40,
                      itemExtent: 56,
                      itemBuilder: (_, i) =>
                          Text('row $i', key: ValueKey('source-row-$i')))));
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [appRouteObserver],
          builder: (context, child) => ValueListenableBuilder<EdgeInsets>(
              valueListenable: insets,
              builder: (context, padding, _) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(padding: padding, viewPadding: padding),
                  child: child!)),
          onGenerateRoute: (_) => source));
      await tester.pumpAndSettle();
      final header =
          find.byKey(const ValueKey('source-header'), skipOffstage: false);
      final row =
          find.byKey(const ValueKey('source-row-4'), skipOffstage: false);
      final beforeHeader = tester.getRect(header),
          beforeRow = tester.getRect(row);
      final originalState =
          tester.state(find.byKey(const ValueKey('source-scaffold')));
      void unchanged() {
        expect(
            tester.state(find.byKey(const ValueKey('source-scaffold'),
                skipOffstage: false)),
            same(originalState));
        expect(tester.getRect(header), beforeHeader);
        expect(tester.getRect(row), beforeRow);
        expect(scroll.offset, 96);
      }

      for (var cycle = 0; cycle < 2; cycle++) {
        MediaQueryData? readerMedia;
        final reader = ReaderRoute<void>(builder: (context) {
          readerMedia = MediaQuery.of(context);
          return const Scaffold(backgroundColor: Colors.black);
        });
        nav.currentState!.push(reader);
        await tester.pump();
        insets.value = EdgeInsets.zero;
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          expect(source.secondaryAnimation!.value, 0,
              reason: 'Parent should not join reader zoom');
          expect(reader.animation!.value, greaterThan(0));
          expect(readerMedia!.padding, EdgeInsets.zero);
          unchanged();
        }
        await tester.pumpAndSettle();
        nav.currentState!.pop();
        await tester.pump();
        // The source is already visible, but Android has not restored bars yet.
        unchanged();
        await tester.pump(const Duration(milliseconds: 150));
        unchanged();
      }
      insets.value = const EdgeInsets.only(top: 24, bottom: 20);
      await tester.pumpAndSettle();
      unchanged();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      insets.dispose();
    });
  }

  testWidgets(
      'ordinary page transitions and live keyboard data remain unchanged',
      (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final media = ValueNotifier(const MediaQueryData(
        size: Size(400, 800),
        padding: EdgeInsets.only(top: 24, bottom: 20),
        viewPadding: EdgeInsets.only(top: 24, bottom: 20)));
    MediaQueryData? seen;
    final source = AppPageRoute<void>(builder: (context) {
      seen = MediaQuery.of(context);
      return const Scaffold(body: Text('source'));
    });
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [appRouteObserver],
        builder: (_, child) => ValueListenableBuilder<MediaQueryData>(
            valueListenable: media,
            builder: (_, data, __) => MediaQuery(data: data, child: child!)),
        onGenerateRoute: (_) => source));
    await tester.pumpAndSettle();
    nav.currentState!.push(AppPageRoute(builder: (_) => const Scaffold()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(source.secondaryAnimation!.value, greaterThan(0));
    media.value = media.value
        .copyWith(padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero);
    await tester.pumpAndSettle();
    expect(seen!.padding, EdgeInsets.zero);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    media.value = media.value.copyWith(
        padding: const EdgeInsets.only(top: 24, bottom: 20),
        viewPadding: const EdgeInsets.only(top: 24, bottom: 20));
    await tester.pump();
    nav.currentState!.push(ReaderRoute(builder: (_) => const Scaffold()));
    await tester.pumpAndSettle();
    media.value = media.value.copyWith(
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
        viewInsets: const EdgeInsets.only(bottom: 300),
        textScaleFactor: 1.3);
    await tester.pump();
    expect(seen!.padding.top, 24);
    expect(seen!.padding.bottom, 0);
    expect(seen!.viewInsets.bottom, 300);
    expect(seen!.textScaleFactor, 1.3);
    media.value = media.value.copyWith(
        size: const Size(800, 400),
        padding: const EdgeInsets.only(right: 24),
        viewPadding: const EdgeInsets.only(right: 24),
        viewInsets: EdgeInsets.zero);
    await tester.pump();
    expect(seen!.orientation, Orientation.landscape);
    expect(seen!.padding, const EdgeInsets.only(right: 24));
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    media.dispose();
  });
}
