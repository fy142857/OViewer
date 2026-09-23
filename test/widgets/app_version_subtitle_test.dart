import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/widgets/app_version_subtitle.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('version lookup does not block and failure is localized',
      (tester) async {
    final response = Completer<dynamic>();
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => response.future);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(
      home: AppVersionSubtitle(
        description: 'OViewer',
        unavailableLabel: '版本信息不可用',
      ),
    ));
    expect(find.text('…\nOViewer'), findsOneWidget);
    response.completeError(PlatformException(code: 'unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('版本信息不可用\nOViewer'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
      home: AppVersionSubtitle(
        description: 'OViewer',
        unavailableLabel: 'Version information unavailable',
      ),
    ));
    expect(
        find.text('Version information unavailable\nOViewer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses package version and build number in either locale',
      (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'OViewer',
      packageName: 'com.oviewer.oviewer',
      version: '1.2.3',
      buildNumber: '42',
      buildSignature: '',
    );
    for (final label in ['版本信息不可用', 'Version information unavailable']) {
      await tester.pumpWidget(MaterialApp(
        home: AppVersionSubtitle(
          description: 'OViewer',
          unavailableLabel: label,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('1.2.3 (42)\nOViewer'), findsOneWidget);
      expect(find.textContaining('1.0.0'), findsNothing);
    }
  });

  testWidgets('missing package fields do not fabricate a version',
      (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'OViewer',
      packageName: 'com.oviewer.oviewer',
      version: '',
      buildNumber: '',
      buildSignature: '',
    );
    await tester.pumpWidget(const MaterialApp(
      home: AppVersionSubtitle(
        description: 'OViewer',
        unavailableLabel: '版本信息不可用',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('版本信息不可用\nOViewer'), findsOneWidget);
  });
}
