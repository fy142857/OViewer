import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/core/router/open_history_entry.dart';
import 'package:oviewer/core/storage/database.dart';
import 'package:oviewer/models/gallery_source.dart';
import 'package:oviewer/models/offline_book.dart';
import 'package:oviewer/repositories/offline_repository.dart';

class Repository extends Mock implements OfflineRepository {}

class Book extends Mock implements OfflineBook {}

void main() {
  tearDown(() async => GetIt.I.reset());
  for (final knownSource in [true, false]) {
    testWidgets(
        'shared history resolver opens cached reader before details (known=$knownSource)',
        (tester) async {
      final source = knownSource ? GallerySource.eh : null;
      final repository = Repository();
      when(() => repository.initialize()).thenAnswer((_) async {});
      when(() => repository.matching(42, 'abc', source: source))
          .thenAnswer((_) async => knownSource ? [Book()] : [Book(), Book()]);
      GetIt.I.registerSingleton<OfflineRepository>(repository);
      final entry = HistoryEntry(
          gid: 42,
          token: 'abc',
          title: 'Book',
          thumbUrl: '',
          category: 'Misc',
          rating: 0,
          fileCount: 1,
          lastReadPage: 0,
          totalPages: 1,
          lastReadAt: DateTime(2026),
          source: source?.name);
      RouteSettings? opened;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => openHistoryEntry(context, entry),
                      child: const Text('Open history')))),
          onGenerateRoute: (route) {
            opened = route;
            return MaterialPageRoute(
                builder: (_) => const Scaffold(body: Text('Local reader')));
          }));
      await tester.tap(find.text('Open history'));
      await tester.pumpAndSettle();
      expect(opened!.name, '/reader');
      expect((opened!.arguments as Map)['source'], source);
      expect(find.text('Local reader'), findsOneWidget);
      verify(() => repository.matching(42, 'abc', source: source)).called(1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
