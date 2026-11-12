import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/features/uploads/rules/rule_notice.dart';
import 'package:oviewer/features/uploads/rules/upload_rules.dart';

Widget host(
  Widget child, {
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
}) =>
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(colorSchemeSeed: Colors.blue, brightness: brightness),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(12), child: child),
            ),
          ),
        ),
      ),
    );

void main() {
  test('every field/action location has complete, traceable bilingual help',
      () {
    expect(
        UploadRules.all.map((r) => r.id).toSet(), UploadRuleId.values.toSet());
    expect(UploadRules.all.length, UploadRuleId.values.length);
    for (final location in UploadRuleLocation.values) {
      expect(UploadRules.forLocation(location), isNotEmpty,
          reason: 'No contextual help at ${location.name}');
    }
    for (final rule in UploadRules.all) {
      expect(UploadRules.byId(rule.id), same(rule));
      expect(rule.locations, isNotEmpty);
      expect(rule.details, isNotEmpty);
      expect(rule.sources, isNotEmpty);
      expect(DateTime.tryParse(rule.checkedOn), isNotNull);
      final texts = [
        rule.title,
        rule.summary,
        ...rule.alwaysVisible,
        ...rule.details,
        ...rule.sources.map((s) => s.title),
      ];
      for (final text in texts) {
        expect(text.zh.trim(), isNotEmpty, reason: rule.id.name);
        expect(text.en.trim(), isNotEmpty, reason: rule.id.name);
        expect(text.inLanguage('zh'), text.zh);
        expect(text.inLanguage('en'), text.en);
      }
      for (final source in rule.sources) {
        expect(source.uri.scheme, 'https');
        expect(source.uri.userInfo, isEmpty);
        expect(
            source.uri.host,
            isIn(const {
              'ehwiki.org',
              'e-hentai.org',
              'upld.e-hentai.org',
              'forums.e-hentai.org',
              'developer.android.com',
              'developer.apple.com',
            }));
      }
    }
  });

  test('context selection is immutable and contains no unrelated rules', () {
    final deletion = UploadRules.forLocation(UploadRuleLocation.delete);
    expect(deletion.map((r) => r.id), [UploadRuleId.deletion]);
    expect(() => deletion.clear(), throwsUnsupportedError);
    final bulk = UploadRules.forLocation(UploadRuleLocation.bulk);
    expect(bulk.map((r) => r.id).toSet(), {
      UploadRuleId.deletion,
      UploadRuleId.disown,
      UploadRuleId.bulkActions,
    });
    for (final rule in UploadRules.all
        .where((r) => r.severity == UploadRuleSeverity.danger)) {
      expect(rule.alwaysVisible, isNotEmpty,
          reason: '${rule.id.name} must explain consequences before expanding');
    }
  });

  for (final language in ['en', 'zh']) {
    testWidgets('disown consequences stay visible when collapsed ($language)',
        (tester) async {
      final rule = UploadRules.byId(UploadRuleId.disown);
      await tester.pumpWidget(host(
        RuleNotice(rule: rule, onOpenSource: (_) {}),
        language: language,
      ));
      for (final consequence in rule.alwaysVisible) {
        expect(find.text(consequence.inLanguage(language)), findsOneWidget);
      }
      expect(find.text(rule.details.first.inLanguage(language)), findsNothing);
      await tester.tap(find.byKey(const ValueKey('upload-rule-toggle-disown')));
      await tester.pump();
      expect(
          find.text(rule.details.first.inLanguage(language)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('upload-rule-toggle-disown')));
      await tester.pump();
      expect(find.text(rule.details.first.inLanguage(language)), findsNothing);
      for (final consequence in rule.alwaysVisible) {
        expect(find.text(consequence.inLanguage(language)), findsOneWidget);
      }
    });
  }

  testWidgets('field notices show only their assigned rules and source links',
      (tester) async {
    Uri? opened;
    await tester.pumpWidget(host(RuleNotices(
      location: UploadRuleLocation.delete,
      initiallyExpanded: true,
      onOpenSource: (uri) => opened = uri,
    )));
    expect(find.byType(RuleNotice), findsOneWidget);
    final source = find.byKey(const ValueKey('upload-rule-source-deletion-0'));
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pump();
    expect(opened, UploadRules.byId(UploadRuleId.deletion).sources.single.uri);
    expect(find.textContaining('Checked 2026-11-12'), findsOneWidget);
    expect(find.textContaining('Official gallery management guide'),
        findsOneWidget);
  });

  testWidgets(
      'opening a source is serialized and errors disclose only public URL',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    final rule = UploadRules.byId(UploadRuleId.folders);
    await tester.pumpWidget(host(RuleNotice(
      rule: rule,
      initiallyExpanded: true,
      onOpenSource: (_) {
        calls++;
        return pending.future;
      },
    )));
    final source = find.byKey(const ValueKey('upload-rule-source-folders-0'));
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pump();
    expect(tester.widget<TextButton>(source).onPressed, isNull);
    expect(calls, 1);
    pending.completeError(StateError('secret-session-token'));
    await tester.pump();
    expect(tester.widget<TextButton>(source).onPressed, isNotNull);
    expect(find.textContaining('secret-session-token'), findsNothing);
    expect(find.byKey(const ValueKey('upload-rule-source-error-folders')),
        findsOneWidget);
    expect(find.textContaining(rule.sources.first.url), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending source completion is safe after the rule is removed',
      (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(host(RuleNotice(
      rule: UploadRules.byId(UploadRuleId.folders),
      initiallyExpanded: true,
      onOpenSource: (_) => pending.future,
    )));
    final source = find.byKey(const ValueKey('upload-rule-source-folders-0'));
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('source failed'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the rule resets old expanded text and source error',
      (tester) async {
    const key = ValueKey('same-rule-slot');
    await tester.pumpWidget(host(RuleNotice(
      key: key,
      rule: UploadRules.byId(UploadRuleId.folders),
      initiallyExpanded: true,
      onOpenSource: (_) => throw StateError('failed'),
    )));
    final source = find.byKey(const ValueKey('upload-rule-source-folders-0'));
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    final rule = UploadRules.byId(UploadRuleId.description);
    await tester.pumpWidget(host(RuleNotice(
      key: key,
      rule: rule,
      onOpenSource: (_) {},
    )));
    expect(find.text(rule.title.en), findsOneWidget);
    expect(find.text(rule.details.first.en), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('locale changes update an already-expanded notice',
      (tester) async {
    final rule = UploadRules.byId(UploadRuleId.description);
    Widget notice() => RuleNotice(
          key: const ValueKey('description'),
          rule: rule,
          initiallyExpanded: true,
          onOpenSource: (_) {},
        );
    await tester.pumpWidget(host(notice()));
    expect(find.text(rule.details.first.en), findsOneWidget);
    await tester.pumpWidget(host(notice(), language: 'zh'));
    await tester.pumpAndSettle();
    expect(find.text(rule.details.first.zh), findsOneWidget);
    expect(find.text(rule.details.first.en), findsNothing);
  });

  for (final language in ['en', 'zh']) {
    testWidgets(
        'all detailed rules fit narrow large-text dark screens ($language)',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final rule in UploadRules.all) {
        await tester.pumpWidget(host(
          RuleNotice(
            key: ValueKey(rule.id),
            rule: rule,
            initiallyExpanded: true,
            onOpenSource: (_) {},
          ),
          language: language,
          brightness: Brightness.dark,
          scale: 2,
        ));
        expect(tester.takeException(), isNull, reason: rule.id.name);
      }
    });
  }
}
