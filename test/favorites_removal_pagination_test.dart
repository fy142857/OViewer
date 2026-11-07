import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/favorites/favorites_bloc.dart';
import 'package:oviewer/blocs/favorites/favorites_event.dart';
import 'package:oviewer/repositories/favorites_repository.dart';
import 'favorites_scope_test.dart' show Repo, result, flush;

void main() {
  setUpAll(() => registerFallbackValue(CancelToken()));
  for (final entry in FavoritesEntry.values) {
    test('remove on later pages preserves cursor and pending page: $entry',
        () async {
      final repo = Repo();
      final changes = ValueNotifier(0);
      ({int gid, bool removed})? change;
      when(() => repo.changes).thenReturn(changes);
      when(() => repo.lastChange).thenAnswer((_) => change);
      when(() => repo.rebuildCache(any(), isCurrent: any(named: 'isCurrent')))
          .thenAnswer((_) async {});
      when(() => repo.clearConfirmationCache()).thenAnswer((_) async {});
      final pending = Completer<FavoritesResult>();
      final calls = <String?>[];
      when(() => repo.fetchCloudFavorites(
          page: any(named: 'page'),
          cat: any(named: 'cat'),
          nextUrl: any(named: 'nextUrl'),
          cancelToken: any(named: 'cancelToken'))).thenAnswer((call) async {
        final next = call.namedArguments[#nextUrl] as String?;
        calls.add(next);
        if (next == 'third') return pending.future;
        return next == null
            ? result([1, 2], next: 'second')
            : result([3, 4], next: 'third');
      });
      final root = FavoritesBloc(repo);
      root.syncSession(site: 'eh', signedIn: true, revision: 1, account: 'a');
      await flush();
      final bloc = root.forEntry(entry);
      bloc.attachView();
      await flush();
      bloc.add(const LoadMoreFavorites());
      await flush();
      final bucket = bloc.scrollStorage;
      expect(bloc.state.favorites.map((g) => g.gid), [1, 2, 3, 4]);
      bloc.detachView();
      change = (gid: 3, removed: true);
      changes.value++;
      await flush();
      bloc.attachView();
      await flush();
      expect(calls, [null, 'second']);
      expect(bloc.scrollStorage, same(bucket));
      expect(bloc.state.currentPage, 1);
      expect(bloc.state.nextPageUrl, 'third');
      expect(bloc.state.favorites.map((g) => g.gid), [1, 2, 4]);
      bloc.add(const LoadMoreFavorites());
      await flush();
      change = (gid: 4, removed: true);
      changes.value++;
      await flush();
      pending.complete(result([3, 4, 5, 6]));
      await flush();
      expect(bloc.state.favorites.map((g) => g.gid), [1, 2, 5, 6]);
      expect(bloc.state.hasReachedEnd, isTrue);
      expect(bloc.state.isLoadingMore, isFalse);
      expect(bloc.scrollStorage, same(bucket));
      await root.close();
      changes.dispose();
    });
  }
}
