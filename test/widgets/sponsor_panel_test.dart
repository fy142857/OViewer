import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/services/sponsor_service.dart';
import 'package:oviewer/widgets/sponsor_panel.dart';

class Settings extends Mock implements SettingsBloc {}

class Service extends Mock implements SponsorService {}

Future<void> boot(WidgetTester tester, Service service,
    {double width = 360,
    double scale = 1,
    String locale = 'zh',
    bool dark = false}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final settings = Settings();
  when(() => settings.state).thenReturn(SettingsState(locale: locale));
  when(() => settings.stream).thenAnswer((_) => const Stream.empty());
  await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
      value: settings,
      child: MaterialApp(
          theme: dark
              ? ThemeData.dark(useMaterial3: true)
              : ThemeData(useMaterial3: true),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaleFactor: scale),
              child: child!),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: SponsorPanel(service: service))))));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => registerFallbackValue(SponsorPlatform.wechat));
  for (final width in [320.0, 800.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'equal square codes, WeChat left and Alipay right at $width/$scale',
          (tester) async {
        await boot(tester, Service(), width: width, scale: scale);
        final left = find.byKey(const ValueKey('sponsor-code-wechat'));
        final right = find.byKey(const ValueKey('sponsor-code-alipay'));
        final l = tester.getSize(left), r = tester.getSize(right);
        expect(l, r);
        expect(l.width, l.height);
        expect(tester.getTopLeft(left).dy, tester.getTopLeft(right).dy);
        expect(tester.getBottomRight(left).dx,
            lessThan(tester.getTopLeft(right).dx));
        for (final name in ['wechat', 'alipay']) {
          expect(
              tester
                  .getTopLeft(find.byKey(ValueKey('sponsor-action-$name')))
                  .dy,
              greaterThanOrEqualTo(tester
                  .getBottomRight(find.byKey(ValueKey('sponsor-code-$name')))
                  .dy));
        }
        expect(find.text('制作不易，您的支持是我开发的最大动力 (:3 」∠ )'), findsOneWidget);
        expect(tester.widget<Text>(find.text('保存图片跳转微信')).style!.color,
            const Color(0xFF2E7D32));
        expect(tester.widget<Text>(find.text('保存图片跳转支付宝')).style!.color,
            const Color(0xFF1565C0));
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('both providers and both operations start independently',
      (tester) async {
    final service = Service();
    final saves = {
      for (final p in SponsorPlatform.values) p: Completer<void>()
    };
    final opens = {
      for (final p in SponsorPlatform.values) p: Completer<bool>()
    };
    for (final p in SponsorPlatform.values) {
      when(() => service.saveCode(p)).thenAnswer((_) => saves[p]!.future);
      when(() => service.openApp(p)).thenAnswer((_) => opens[p]!.future);
    }
    await boot(tester, service);
    for (final p in SponsorPlatform.values) {
      await tester.tap(find.byKey(ValueKey('sponsor-action-${p.name}')));
      await tester.pump();
      verify(() => service.saveCode(p)).called(1);
      verify(() => service.openApp(p)).called(1);
    }
    saves[SponsorPlatform.wechat]!
        .completeError(PlatformException(code: 'permission_denied'));
    opens[SponsorPlatform.alipay]!.complete(false);
    await tester.pump();
    await tester.pump();
    expect(opens[SponsorPlatform.wechat]!.isCompleted, false);
    expect(saves[SponsorPlatform.alipay]!.isCompleted, false);
    opens[SponsorPlatform.wechat]!.complete(true);
    saves[SponsorPlatform.alipay]!.complete();
    await tester.pumpAndSettle();
    expect(find.text('无法保存赞助码，请在系统设置中允许保存图片'), findsOneWidget);
    for (final p in SponsorPlatform.values) {
      expect(
          tester
              .widget<TextButton>(
                  find.byKey(ValueKey('sponsor-action-${p.name}')))
              .onPressed,
          isNotNull);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed save still opens, and completion after dispose is safe',
      (tester) async {
    final service = Service();
    final opening = Completer<bool>();
    when(() => service.saveCode(SponsorPlatform.wechat))
        .thenThrow(StateError('disk'));
    when(() => service.openApp(SponsorPlatform.wechat))
        .thenAnswer((_) => opening.future);
    await boot(tester, service, locale: 'en', dark: true);
    expect(find.text('Save image & open WeChat'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sponsor-action-wechat')));
    await tester.pumpAndSettle();
    verify(() => service.openApp(SponsorPlatform.wechat)).called(1);
    expect(find.text('Could not save the WeChat code. Please retry.'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    opening.completeError(StateError('missing app'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('save result is deferred while another app is foreground',
      (tester) async {
    final service = Service();
    final saving = Completer<void>();
    when(() => service.saveCode(SponsorPlatform.alipay))
        .thenAnswer((_) => saving.future);
    when(() => service.openApp(SponsorPlatform.alipay))
        .thenAnswer((_) async => true);
    await boot(tester, service);
    await tester.tap(find.byKey(const ValueKey('sponsor-action-alipay')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    saving.complete();
    await tester.pump();
    expect(find.text('支付宝赞助码已保存到相册'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('支付宝赞助码已保存到相册'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
