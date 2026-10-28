import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/reader_menu.dart';

void main() {
  testWidgets(
      'reader popup opens and closes in 150ms without changing other menus',
      (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: Column(children: [
                    TextButton(
                        onPressed: () async {
                          selected = await showReaderMenu<int>(
                                  context: context,
                                  position: const RelativeRect.fromLTRB(
                                      500, 60, 20, 500),
                                  constraints: const BoxConstraints(
                                      minWidth: 210, maxWidth: 210),
                                  items: const [
                                    PopupMenuItem(
                                        value: 7, child: Text('Reader item'))
                                  ]) ??
                              0;
                        },
                        child: const Text('Reader')),
                    TextButton(
                        onPressed: () => showMenu<int>(
                                context: context,
                                position: const RelativeRect.fromLTRB(
                                    500, 60, 20, 500),
                                items: const [
                                  PopupMenuItem(
                                      value: 1, child: Text('Other item'))
                                ]),
                        child: const Text('Other')),
                  ]),
                ))));
    await tester.tap(find.text('Reader'));
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.text('Reader item')))!;
    expect(route, isA<ReaderMenuRoute<int>>());
    expect(route.transitionDuration, const Duration(milliseconds: 150));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 75));
    expect(route.animation!.value, closeTo(0.5, 0.01));
    await tester.pump(const Duration(milliseconds: 75));
    expect(route.animation!.value, closeTo(1, 0.001));
    // The simulation finalizes on the first tick past its exact endpoint.
    await tester.pump(const Duration(milliseconds: 1));
    expect(route.animation!.isCompleted, true);
    await tester.tap(find.text('Reader item'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(route.animation!.status, AnimationStatus.reverse);
    await tester.pump(const Duration(milliseconds: 76));
    await tester.pump();
    expect(find.text('Reader item'), findsNothing);
    expect(selected, 7);

    await tester.tap(find.text('Other'));
    await tester.pump();
    final other = ModalRoute.of(tester.element(find.text('Other item')))!;
    expect(other.transitionDuration, const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 500));
    await tester.pumpAndSettle();
    expect(find.text('Other item'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
