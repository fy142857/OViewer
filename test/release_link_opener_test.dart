import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/services/release_link_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final uri =
      Uri.parse('https://github.com/fy142857/OViewer/releases/tag/v1.2.0');
  tearDown(() =>
      messenger.setMockMethodCallHandler(ReleaseLinkOpener.channel, null));

  test('passes release URL and propagates native success or failure', () async {
    for (final opened in [true, false]) {
      messenger.setMockMethodCallHandler(ReleaseLinkOpener.channel,
          (call) async {
        expect(call.method, 'open');
        expect(call.arguments, uri.toString());
        return opened;
      });
      expect(await ReleaseLinkOpener().open(uri), opened);
    }
  });
  test('platform and missing plugin failures return false', () async {
    messenger.setMockMethodCallHandler(ReleaseLinkOpener.channel,
        (_) async => throw PlatformException(code: 'failed'));
    expect(await ReleaseLinkOpener().open(uri), false);
    messenger.setMockMethodCallHandler(ReleaseLinkOpener.channel, null);
    expect(await ReleaseLinkOpener().open(uri), false);
  });
  test('rejects URLs outside the repository before calling native code',
      () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(ReleaseLinkOpener.channel, (_) async {
      calls++;
      return true;
    });
    for (final url in [
      'http://github.com/fy142857/OViewer/releases/tag/v1',
      'https://github.com.evil.test/fy142857/OViewer/releases/tag/v1',
      'https://user@github.com/fy142857/OViewer/releases/tag/v1',
      'https://github.com:444/fy142857/OViewer/releases/tag/v1',
      'https://github.com/other/repo/releases/tag/v1',
      'https://github.com/fy142857/OViewer/releases/tag/v1?redirect=elsewhere',
    ]) {
      expect(await ReleaseLinkOpener().open(Uri.parse(url)), false);
    }
    expect(calls, 0);
  });
}
