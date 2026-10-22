import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/network/cookie_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('oviewer-account-session-');
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });
  Future<CookieManager> manager() async {
    final cookies = CookieManager(clearBrowserAuthentication: () async {});
    await cookies.init();
    return cookies;
  }

  for (var cancelAt = 1; cancelAt <= 5; cancelAt++) {
    test(
        'cancellation at persistence checkpoint $cancelAt removes partial authentication',
        () async {
      final cookies = await manager();
      var checks = 0;
      var committed = false;
      await expectLater(
          cookies.saveLoginCookies(
              memberId: '123',
              passHash: 'test-hash',
              isCurrent: () => ++checks < cancelAt,
              onCommitted: () => committed = true),
          throwsStateError);
      expect(committed, isFalse);
      expect(await cookies.hasLoginCookies(), isFalse);
      final reopened = await manager();
      expect(await reopened.hasLoginCookies(), isFalse);
      expect(await reopened.getCookieHeader(Uri.parse('https://exhentai.org/')),
          isNot(contains('test-hash')));
    });
  }
  test('successful verified session survives restart and logout removes it',
      () async {
    final cookies = await manager();
    var committed = false;
    await cookies.saveLoginCookies(
        memberId: '123',
        passHash: 'test-hash',
        igneous: 'test-ex',
        isCurrent: () => true,
        onCommitted: () => committed = true);
    expect(committed, isTrue);
    final reopened = await manager();
    expect(await reopened.getMemberId(), '123');
    expect(await reopened.hasLoginCookies(), isTrue);
    await reopened.clearCookies();
    expect(await (await manager()).hasLoginCookies(), isFalse);
  });
}
