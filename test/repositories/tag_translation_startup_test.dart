import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/core/storage/tag_translation_cache.dart';
import 'package:oviewer/repositories/tag_translation_repository.dart';

class MockDio extends Mock implements DioClient {}

class MemoryTags extends TagTranslationCache {
  String? content;
  bool failWrite = false;
  int writes = 0;
  MemoryTags(this.content);
  @override
  Future<String?> read() async => content;
  @override
  Future<void> write(String json) async {
    if (failWrite) throw const FileSystemException('full');
    writes++;
    content = json;
  }
}

String dictionary(String name, {int count = 1}) => jsonEncode({
      'data': [
        {
          'namespace': 'artist',
          'data': {
            for (var i = 0; i < count; i++) 'key$i': {'name': '$name$i'}
          }
        }
      ]
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockDio dio;
  late LocalStorage storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'eh_tag_translations_cache': dictionary('legacy')});
    storage = LocalStorage();
    await storage.init();
    dio = MockDio();
    when(() => dio.get(any()))
        .thenAnswer((_) async => throw StateError('offline'));
  });
  test(
      'legacy migration writes verified file before removing preferences; callers share load',
      () async {
    final cache = MemoryTags(null);
    final repo = TagTranslationRepository(dio, storage, cache: cache);
    final first = repo.loadTranslations();
    expect(identical(first, repo.loadTranslations()), isTrue);
    await first;
    expect(cache.content, dictionary('legacy'));
    expect(cache.writes, 1);
    expect(storage.prefs.containsKey('eh_tag_translations_cache'), isFalse);
    expect(repo.getTranslation('artist', 'key0'), 'legacy0');
    final restarted = TagTranslationRepository(dio, storage, cache: cache);
    await restarted.loadTranslations();
    expect(restarted.getTranslation('artist', 'key0'), 'legacy0');
    repo.dispose();
    restarted.dispose();
  });
  test('failed migration retains the offline legacy copy and usable index',
      () async {
    final cache = MemoryTags(null)..failWrite = true;
    final repo = TagTranslationRepository(dio, storage, cache: cache);
    await repo.loadTranslations();
    expect(storage.prefs.containsKey('eh_tag_translations_cache'), isTrue);
    expect(cache.content, isNull);
    expect(repo.searchByTranslation('legacy'), hasLength(1));
    repo.dispose();
  });
  test(
      'corrupt file falls back to legacy data; invalid refresh preserves valid data',
      () async {
    final pending = Completer<String>();
    when(() => dio.get(any())).thenAnswer((_) => pending.future);
    final cache = MemoryTags('{broken');
    final repo = TagTranslationRepository(dio, storage, cache: cache);
    var notifications = 0;
    repo.addListener(() => notifications++);
    await repo.loadTranslations();
    final refresh = repo.refresh();
    pending.complete('{bad response');
    await refresh;
    expect(repo.getTranslation('artist', 'key0'), 'legacy0');
    expect(cache.content, dictionary('legacy'));
    expect(notifications, 1);
    repo.dispose();
  });
  test('refresh installs a complete new index and notifies listeners',
      () async {
    final pending = Completer<String>();
    when(() => dio.get(any())).thenAnswer((_) => pending.future);
    final repo = TagTranslationRepository(dio, storage,
        cache: MemoryTags(dictionary('local')));
    var notifications = 0;
    repo.addListener(() => notifications++);
    await repo.loadTranslations();
    final refresh = repo.refresh();
    expect(repo.getTranslation('artist', 'key0'), 'local0');
    pending.complete(dictionary('remote'));
    await refresh;
    expect(repo.getTranslation('artist', 'key0'), 'remote0');
    expect(notifications, 2);
    repo.dispose();
  });
  test(
      'large cached dictionary builds searchable normalized entries off the UI isolate',
      () async {
    final cache = MemoryTags(dictionary('translation', count: 60000));
    final repo = TagTranslationRepository(dio, storage, cache: cache);
    var ticks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    try {
      await repo.loadTranslations();
      expect(ticks, greaterThan(0));
      expect(repo.getTranslation('artist', 'key59999'), 'translation59999');
      expect(
          repo.searchByTranslation('TRANSLATION59999').single.key, 'key59999');
    } finally {
      timer.cancel();
      repo.dispose();
    }
  });
  test('file cache replacement survives reopening', () async {
    final dir = await Directory.systemTemp.createTemp('oviewer-tags-');
    final cache = TagTranslationCache(directory: () async => dir);
    try {
      await cache.write(dictionary('first'));
      await cache.write(dictionary('second'));
      expect(await TagTranslationCache(directory: () async => dir).read(),
          dictionary('second'));
      expect(await File('${dir.path}/tag-translations.json.tmp').exists(),
          isFalse);
    } finally {
      expect(dir.parent.absolute.path, Directory.systemTemp.absolute.path);
      await dir.delete(recursive: true);
    }
  });
}
