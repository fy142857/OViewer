import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/search_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockDio extends Mock implements DioClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('existing searches survive growth past twenty and storage reload',
      () async {
    final original = List.generate(20, (i) => 'original $i');
    SharedPreferences.setMockInitialValues({'search_history': original});
    final storage = LocalStorage();
    await storage.init();
    final repository = SearchRepository(MockDio(), storage);

    for (var i = 0; i < 80; i++) {
      await repository.addSearchHistory('new $i');
    }
    final expected = [
      ...List.generate(80, (i) => 'new ${79 - i}'),
      ...original,
    ];
    expect(repository.getSearchHistory(), expected);
    await storage.prefs.reload();
    final reopened = LocalStorage();
    await reopened.init();
    expect(SearchRepository(MockDio(), reopened).getSearchHistory(), expected);

    await repository.addSearchHistory('original 19');
    expect(repository.getSearchHistory(),
        ['original 19', ...expected.where((value) => value != 'original 19')]);
    expect(repository.getSearchHistory(), hasLength(100));

    await repository.removeSearchHistory('new 40');
    expect(repository.getSearchHistory(), hasLength(99));
    expect(repository.getSearchHistory(), isNot(contains('new 40')));
    expect(repository.getSearchHistory(), contains('original 0'));
    await repository.clearSearchHistory();
    await storage.prefs.reload();
    expect(reopened.getSearchHistory(), isEmpty);
  });
}
