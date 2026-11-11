import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_cache_manager/src/storage/cache_object.dart';
import 'package:oviewer/core/network/eh_image_cache_manager.dart';

class LifecycleCache extends EhImageCacheManager {
  final bool failDeletion;
  LifecycleCache(Config config, this.failDeletion)
      : super.forTesting(config, retainEngine: true);
  @override
  Future<void> removeClearEntry(CacheObject entry) async {
    if (failDeletion) throw const FileSystemException('blocked');
    await super.removeClearEntry(entry);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final failure in ['none', 'retain', 'delete', 'ios']) {
    test('clear lifecycle releases its owner (scenario=$failure)', () async {
      final directory =
          await Directory.systemTemp.createTemp('cache-lifecycle-');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final methods = <String>[];
      final gate = Completer<void>();
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path);
      messenger.setMockMethodCallHandler(
          const MethodChannel('oviewer/image_cache'), (call) async {
        methods.add(call.method);
        if (call.method == 'retain') await gate.future;
        return null;
      });
      debugDefaultTargetPlatformOverride =
          failure == 'ios' ? TargetPlatform.iOS : TargetPlatform.android;
      final manager = LifecycleCache(
          Config('images',
              repo: JsonCacheInfoRepository.withFile(
                  File('${directory.path}/index.json'))),
          failure == 'delete');
      try {
        await manager.putFile('image', Uint8List(1));
        final task = manager.emptyCache();
        final result = failure == 'retain'
            ? expectLater(task, throwsA(isA<PlatformException>()))
            : failure == 'delete'
                ? expectLater(task, throwsA(isA<FileSystemException>()))
                : task;
        await Future<void>.delayed(Duration.zero);
        if (failure != 'ios') {
          expect(methods, ['retain']);
          expect(manager.clearing.value, true);
          expect(identical(task, manager.emptyCache()), true);
        }
        if (failure == 'retain') {
          gate.completeError(StateError('retain failed'));
        } else {
          gate.complete();
        }
        await result;
        expect(manager.clearing.value, false);
        expect(
            methods,
            failure == 'ios'
                ? []
                : failure == 'retain'
                    ? ['retain']
                    : ['retain', 'release']);
        expect(await manager.getSizeBytes(),
            failure == 'retain' || failure == 'delete' ? 1 : 0);
      } finally {
        await manager.dispose();
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(
            const MethodChannel('oviewer/image_cache'), null);
        messenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
        await directory.delete(recursive: true);
      }
    });
  }
}
