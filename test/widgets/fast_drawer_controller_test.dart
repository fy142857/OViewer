import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/fast_drawer_controller.dart';

void main() {
  testWidgets(
      'drawer animation follows the original trajectory in half the time',
      (tester) async {
    Future<List<double>> sample(bool fast, int milliseconds) async {
      final key = GlobalKey<DrawerControllerState>();
      const drawer = Drawer(child: Center(child: Text('Drawer content')));
      await tester.pumpWidget(MaterialApp(
          home: Stack(children: [
        const Scaffold(body: Text('Home')),
        if (fast)
          FastDrawerController(key: key, child: drawer)
        else
          DrawerController(
              key: key, alignment: DrawerAlignment.start, child: drawer),
      ])));
      final positions = <double>[];
      key.currentState!.open();
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(Duration(milliseconds: milliseconds));
        positions.add(tester.getTopLeft(find.byType(Drawer)).dx);
      }
      await tester.pumpAndSettle();
      key.currentState!.close();
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(Duration(milliseconds: milliseconds));
        positions.add(tester.getTopLeft(find.byType(Drawer)).dx);
      }
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      return positions;
    }

    final normal = await sample(false, 40);
    final fast = await sample(true, 20);
    for (var i = 0; i < normal.length; i++) {
      expect(fast[i], closeTo(normal[i], 0.01));
    }
  });

  testWidgets('edge drag, scrim and back retain Material drawer behavior',
      (tester) async {
    final key = GlobalKey<DrawerControllerState>();
    var opened = false;
    await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
      const Scaffold(body: Text('Home')),
      FastDrawerController(
          key: key,
          drawerCallback: (value) => opened = value,
          child: const Drawer(child: Text('Drawer content'))),
    ])));
    await tester.dragFrom(const Offset(2, 300), const Offset(280, 0));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    await tester.tapAt(const Offset(700, 300));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    key.currentState!.open();
    await tester.pumpAndSettle();
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
