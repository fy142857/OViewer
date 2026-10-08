import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/services/sponsor_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oviewer-sponsor-test-');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SponsorService.channel, null);
    await root.delete(recursive: true);
  });
  for (final p in SponsorPlatform.values) {
    test('saves original ${p.name} bytes and removes only its temporary folder',
        () async {
      final expected = await File(p.asset).readAsBytes();
      final keep = File('${root.path}/keep.txt');
      await keep.writeAsString('keep');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SponsorService.channel, (call) async {
        expect(call.method, 'saveImage');
        final args = call.arguments as Map;
        expect(args['mime'], p.mime);
        expect(args['name'], startsWith('OViewer_sponsor_${p.name}_'));
        expect(args['name'], endsWith('.${p.extension}'));
        expect(await File(args['path'] as String).readAsBytes(), expected);
        return 'saved';
      });
      await SponsorService(temporaryDirectory: () async => root).saveCode(p);
      final remaining = await root.list().toList();
      expect(remaining.length, 1);
      expect(FileSystemEntity.identicalSync(remaining.single.path, keep.path),
          true);
    });
  }
  test('platform failure propagates and still cleans temporary data', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SponsorService.channel, (call) async => 'permission_denied');
    await expectLater(
        SponsorService(temporaryDirectory: () async => root)
            .saveCode(SponsorPlatform.wechat),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'permission_denied')));
    expect(await root.list().toList(), isEmpty);
  });
  test(
      'successful native save receives notification text without a second Dart notification call',
      () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SponsorService.channel, (call) async {
      methods.add(call.method);
      expect((call.arguments as Map)['notificationBody'], 'Saved');
      return 'saved';
    });
    await SponsorService(temporaryDirectory: () async => root)
        .saveCode(SponsorPlatform.wechat, notificationBody: 'Saved');
    expect(methods, ['saveImage']);
  });
  test('notification authorization failure is independent of saving', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SponsorService.channel, (call) async {
      if (call.method == 'prepareNotifications')
        throw PlatformException(code: 'denied');
      return 'saved';
    });
    final service = SponsorService(temporaryDirectory: () async => root);
    expect(await service.prepareNotifications(), false);
    await service.saveCode(SponsorPlatform.alipay, notificationBody: 'Saved');
    expect(await root.list().toList(), isEmpty);
  });
  test('app launch uses only the selected provider and returns platform result',
      () async {
    final service = SponsorService();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SponsorService.channel, (call) async {
      expect(call.method, 'openApp');
      return call.arguments == 'wechat';
    });
    expect(await service.openApp(SponsorPlatform.wechat), true);
    expect(await service.openApp(SponsorPlatform.alipay), false);
  });
}
