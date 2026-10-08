import 'package:dio/dio.dart';
import '../core/utils/search_queries.dart';
import '../core/utils/tag_search_query.dart';
import '../core/utils/eh_url_parser.dart';
import '../models/search_result.dart';
import 'search_repository.dart' show SearchRepository;
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../core/constants/app_constants.dart';
import 'package:drift/drift.dart';
import '../core/network/dio_client.dart';
import '../core/constants/api_endpoints.dart';
import '../core/parser/gallery_list_parser.dart';
import '../core/storage/database.dart';
import '../models/gallery_preview.dart';

class FavoritesRepository {
  final DioClient _dio;
  final AppDatabase _db;
  final _changes = ValueNotifier<int>(0);
  Listenable? get changes => _changes;
  Future<void> _cacheTail = Future.value();
  int _cacheGeneration = 0;

  FavoritesRepository(this._dio, this._db);

  // --- Cloud Favorites (requires login) ---

  Future<FavoritesResult> fetchCloudFavorites(
      {int page = 0,
      int cat = -1,
      String? nextUrl,
      CancelToken? cancelToken,
      String? keyword}) async {
    final query = keyword?.trim() ?? '';
    if (query.isEmpty) {
      return _fetchPage(
          page: page, cat: cat, nextUrl: nextUrl, cancelToken: cancelToken);
    }
    final site = AppConstants.baseUrl;
    final session = _dio.sessionRevision;
    final link = EhUrlParser.parseGalleryUrl(query);
    final gid = SearchRepository.parseGid(query);
    final queries = link != null
        ? ['gid:${link.$1}']
        : [...expandSearchQueries(query), if (gid != null) 'gid:$gid'];
    final normalized = queries.map(normalizeTagSearchQuery).toSet();
    String first(String q) =>
        Uri.parse(ApiEndpoints.favorites(cat: cat)).replace(queryParameters: {
          'f_search': q,
          'sn': 'on',
          'st': 'on',
          if (cat >= 0) 'favcat': '$cat'
        }).toString();
    final scope = {'site': site, 'query': query, 'category': cat};
    final result = await mergeSearchResults(
        initialUrls: normalized.map(first).toList(),
        scope: scope,
        cursorPrefix: 'oviewer-favorites-union:',
        cursor: nextUrl,
        page: page,
        resolveNext: (url) =>
            Uri.parse('$site/favorites.php').resolve(url).toString(),
        loadPage: (url) async {
          if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
          if (site != AppConstants.baseUrl || session != _dio.sessionRevision) {
            throw StateError('Favorites session expired');
          }
          final branch = Uri.parse(url).queryParameters['f_search'];
          if (!normalized.contains(branch))
            throw const FormatException('Invalid favorites query cursor');
          final r = await _fetchPage(
              cat: cat,
              page: page,
              nextUrl: url,
              cancelToken: cancelToken,
              keyword: branch);
          return SearchResult(
              galleries: r.galleries,
              totalPages: r.totalPages,
              totalResults: 0,
              nextPageUrl: r.nextPageUrl);
        });
    return FavoritesResult(
        galleries: result.galleries,
        totalPages: result.totalPages,
        nextPageUrl: result.nextPageUrl,
        requestUrl: nextUrl);
  }

  /// Every page stays on the selected site and favorite category. A server
  /// cursor supplies ordering/position, never a different account or category.
  Future<FavoritesResult> _fetchPage({
    int page = 0,
    int cat = -1,
    String? nextUrl,
    CancelToken? cancelToken,
    String? keyword,
  }) async {
    final first = ApiEndpoints.favorites(page: page, cat: cat);
    final origin = Uri.parse(AppConstants.baseUrl);
    String scoped(String link) {
      final uri = Uri.parse(first).resolve(link);
      if (uri.origin != origin.origin ||
          uri.path != '/favorites.php' ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('Invalid favorites page link');
      }
      final params = {...uri.queryParameters}..remove('favcat');
      if (cat >= 0) params['favcat'] = '$cat';
      params.remove('f_search');
      if (keyword != null) {
        params.addAll({'f_search': keyword, 'sn': 'on', 'st': 'on'});
      }
      return uri.replace(queryParameters: params).removeFragment().toString();
    }

    final url = scoped(nextUrl ?? first);
    final serverPage =
        int.tryParse(Uri.parse(url).queryParameters['page'] ?? '') ?? page;
    final html = cancelToken == null
        ? await _dio.get(url)
        : await _dio.get(url, cancelToken: cancelToken);
    final galleries = GalleryListParser.parse(html)
        .map((g) => g.copyWith(isFavorited: true, cloudFavorited: true))
        .toList();
    final document = html_parser.parse(html);
    if (galleries.isEmpty &&
        !RegExp(r'No hits found|no favorites|do not have any favorites',
                caseSensitive: false)
            .hasMatch(document.body?.text ?? '')) {
      throw const FormatException('Expected a favorites page');
    }
    final pageCount = GalleryListParser.parsePageCount(html);
    // #unext without href explicitly means the end in cursor-based layouts.
    final button = document.querySelector('#unext');
    String? next = button == null
        ? GalleryListParser.parseNextPageUrl(html)
        : button.attributes['href'];
    if (next != null && next.isNotEmpty) {
      next = scoped(next);
      final numericPage =
          int.tryParse(Uri.parse(next).queryParameters['page'] ?? '');
      if (numericPage != null && numericPage <= serverPage) next = null;
    } else {
      next = null;
      if (button == null &&
          document.querySelector('table.ptt a[href*="page="]') != null &&
          pageCount > serverPage + 1) {
        next = scoped(ApiEndpoints.favorites(page: serverPage + 1, cat: cat));
      }
    }
    if (const bool.fromEnvironment('FAVORITES_DIAGNOSTICS')) {
      final slots = RegExp(r'favcat=([0-9a-z]+)')
          .allMatches(html)
          .map((m) => m[1])
          .toSet();
      debugPrint(
          '[favorites-metric] site=${origin.host} category=$cat page=$page count=${galleries.length} next=${next != null} controls=$slots');
    }
    return FavoritesResult(
        galleries: galleries,
        totalPages: pageCount,
        nextPageUrl: next,
        requestUrl: url);
  }

  Future<void> clearConfirmationCache() {
    _cacheGeneration++;
    final work = _cacheTail.then((_) => _db.clearLocalFavorites());
    _cacheTail = work.catchError((Object _) {});
    return work;
  }

  /// Add to cloud favorites (auto-caches locally)
  Future<void> addCloudFavorite(int gid, String token,
      {int slot = 0, GalleryPreview? preview}) async {
    if (slot < 0 || slot > 9) throw ArgumentError.value(slot);
    final cacheGeneration = _cacheGeneration;
    final session = _dio.sessionRevision;
    bool current() =>
        cacheGeneration == _cacheGeneration && session == _dio.sessionRevision;
    // Write local cache first so other screens see the update immediately
    if (preview != null) {
      await _db.addLocalFavorite(LocalFavoritesCompanion(
        gid: Value(preview.gid),
        token: Value(preview.token),
        title: Value(preview.title),
        thumbUrl: Value(preview.thumbUrl),
        category: Value(preview.category),
        rating: Value(preview.rating),
        fileCount: Value(preview.fileCount),
        slot: Value(slot),
        addedAt: Value(DateTime.now()),
      ));
    }
    try {
      if (!current()) throw StateError('Favorites session expired');
      final url = ApiEndpoints.addFavorite(gid, token);
      await _dio.post(url,
          data: FormData.fromMap({
            'favcat': slot.toString(),
            'favnote': '',
            'apply': 'Add to Favorites',
            'update': '1',
          }));
      if (current()) _changes.value++;
    } catch (_) {
      // Revert local cache on API failure
      if (current()) await _db.removeLocalFavorite(gid);
      rethrow;
    }
  }

  /// Remove cloud favorite (auto-removes local cache)
  Future<void> removeCloudFavorite(int gid, String token) async {
    final cacheGeneration = _cacheGeneration;
    final session = _dio.sessionRevision;
    bool current() =>
        cacheGeneration == _cacheGeneration && session == _dio.sessionRevision;
    // Save existing entry for rollback, then remove immediately
    final existing = await _db.getLocalFavorite(gid);
    if (!current()) throw StateError('Favorites session expired');
    await _db.removeLocalFavorite(gid);
    try {
      if (!current()) throw StateError('Favorites session expired');
      final url = ApiEndpoints.addFavorite(gid, token);
      await _dio.post(url,
          data: FormData.fromMap({
            'favcat': 'favdel',
            'apply': 'Apply Changes',
            'update': '1',
          }));
      if (current()) _changes.value++;
    } catch (_) {
      // Revert local cache on API failure
      if (existing != null && current()) {
        await _db.addLocalFavorite(LocalFavoritesCompanion(
          gid: Value(existing.gid),
          token: Value(existing.token),
          title: Value(existing.title),
          thumbUrl: Value(existing.thumbUrl),
          category: Value(existing.category),
          rating: Value(existing.rating),
          fileCount: Value(existing.fileCount),
          slot: Value(existing.slot),
          addedAt: Value(existing.addedAt),
        ));
      }
      rethrow;
    }
  }

  // --- Local cache (used by _markFavorites) ---

  Future<Set<int>> getLocalFavoriteGids() => _db.getLocalFavoriteGids();

  /// Reconcile only galleries present in a fresh response. Other pages are
  /// not evidence of removal, and unknown markup must not erase local state.
  Future<void> cacheFavoriteStates(List<GalleryPreview> galleries) async {
    await rebuildCache(
        galleries.where((g) => g.cloudFavorited == true).toList());
    for (final gallery in galleries) {
      if (gallery.cloudFavorited == false) {
        await _db.removeLocalFavorite(gallery.gid);
      }
    }
  }

  /// Merge a page of confirmed cloud favorites without erasing other pages.
  Future<void> rebuildCache(List<GalleryPreview> galleries,
      {bool Function()? isCurrent}) {
    final generation = _cacheGeneration;
    final work = _cacheTail.then((_) async {
      for (final g in galleries) {
        if (generation != _cacheGeneration || isCurrent?.call() == false) {
          return;
        }
        // This cache records membership, not evidence that every item is slot 0.
        final existing = await _db.getLocalFavorite(g.gid);
        if (generation != _cacheGeneration || isCurrent?.call() == false) {
          return;
        }
        await _db.addLocalFavorite(LocalFavoritesCompanion(
            gid: Value(g.gid),
            token: Value(g.token),
            title: Value(g.title),
            thumbUrl: Value(g.thumbUrl),
            category: Value(g.category),
            rating: Value(g.rating),
            fileCount: Value(g.fileCount),
            slot: Value(existing?.slot ?? -1),
            addedAt: Value(DateTime.now())));
      }
    });
    _cacheTail = work.catchError((Object _) {});
    return work;
  }
}

class FavoritesResult {
  final List<GalleryPreview> galleries;
  final int totalPages;
  final String? nextPageUrl;
  final String? requestUrl;

  const FavoritesResult(
      {required this.galleries,
      required this.totalPages,
      this.nextPageUrl,
      this.requestUrl});
}
