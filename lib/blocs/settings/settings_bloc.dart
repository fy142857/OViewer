import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../core/constants/app_constants.dart';
import '../../core/storage/reader_index_cache.dart';
import '../../core/storage/reader_reentry_cache.dart';
import '../../core/network/cookie_manager.dart' as app;
import '../../core/network/dio_client.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../core/network/system_proxy_detector.dart';
import '../../core/network/network_preparation.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/settings_repository.dart';
import 'settings_event.dart';
import 'settings_state.dart';

class SettingsBloc extends Bloc<SettingsEvent, SettingsState> {
  final SettingsRepository _repository;
  final Future<void> Function(int) _applyCacheLimit;
  bool _changingCacheLimit = false;
  final NetworkPreparation? _network;
  final bool _hasInitialSettings;
  int _proxyRevision = 0;
  bool _changingSite = false;
  final Future<void> Function() _syncSiteCookies;
  final int? Function() _sessionRevision;

  SettingsBloc(this._repository,
      {Future<void> Function(int)? applyCacheLimit,
      Future<void> Function()? syncSiteCookies,
      int? Function()? sessionRevision,
      SettingsState? initialState,
      NetworkPreparation? network})
      : _network = network,
        _syncSiteCookies = syncSiteCookies ??
            (() => GetIt.I<app.CookieManager>().syncCookiesToExHentai()),
        _sessionRevision = sessionRevision ??
            (() => GetIt.I<app.CookieManager>().sessionRevision),
        _hasInitialSettings = initialState != null,
        _applyCacheLimit = applyCacheLimit ??
            ((mb) => EhImageCacheManager.instance.applyLimitMB(mb)),
        super(initialState ?? const SettingsState()) {
    _network?.addListener(_networkChanged);
    on<NetworkPreparationChanged>((event, emit) {
      final network = _network;
      if (network != null)
        emit(state.copyWith(
            detectedProxy: network.result.proxyUrl,
            vpnActive: network.result.vpnActive));
    });
    on<LoadSettings>(_onLoad);
    on<UpdateThemeMode>(_onTheme);
    on<UpdateReadingMode>(_onReading);
    on<UpdateReaderPreloadCount>((event, emit) async {
      if (state.savingPreloadCount) {
        event.completer?.complete();
        return;
      }
      emit(state.copyWith(savingPreloadCount: true));
      try {
        await _repository.setReaderPreloadCount(event.count);
        emit(state.copyWith(
            preloadCount: event.count, savingPreloadCount: false));
        event.completer?.complete();
      } catch (error, stack) {
        emit(state.copyWith(savingPreloadCount: false));
        event.completer?.completeError(error, stack);
      }
    });
    on<UpdateReaderSpreadAlignment>((event, emit) async {
      await _repository.setReaderSpreadAlignment(event.alignment);
      emit(state.copyWith(spreadAlignment: event.alignment));
    });
    on<UpdateReaderPageLayout>((event, emit) async {
      await _repository.setReaderPageLayout(event.layout);
      emit(state.copyWith(pageLayout: event.layout));
    });
    on<UpdateDisplayMode>(_onDisplay);
    on<UpdateProxy>(_onProxy);
    on<ToggleAutoProxy>(_onToggleAutoProxy);
    on<UpdateCacheLimit>(_onCacheLimit);
    on<ToggleSiteMode>(_onToggleSite);
    on<SyncMyTags>(_onSyncMyTags);
    on<UpdateLocale>(_onUpdateLocale);
  }

  static SettingsState readSaved(SettingsRepository repository) =>
      SettingsState(
        themeMode: repository.getThemeMode(),
        readingMode: repository.getReadingMode(),
        preloadCount: repository.getReaderPreloadCount(),
        pageLayout: repository.getReaderPageLayout(),
        spreadAlignment: repository.getReaderSpreadAlignment(),
        displayMode: repository.getDisplayMode(),
        cacheLimitMB: repository.getCacheLimit(),
        proxyUrl: repository.getProxy(),
        autoProxy: repository.getAutoProxy(),
        useExHentai: repository.getUseExHentai(),
        hiddenTags: repository.getHiddenTags(),
        locale: repository.getLocale(),
      );

  void _networkChanged() {
    if (!isClosed) add(NetworkPreparationChanged());
  }

  @override
  Future<void> close() {
    _network?.removeListener(_networkChanged);
    return super.close();
  }

  Future<void> _onLoad(LoadSettings event, Emitter<SettingsState> emit) async {
    if (!_hasInitialSettings) emit(readSaved(_repository));
    AppConstants.useExHentai = state.useExHentai;
    // Production shares the already scheduled startup probe. It never launches
    // a second probe or replaces theme/language after an asynchronous wait.
    if (_network != null) return;
    final revision = _proxyRevision;
    final result =
        state.autoProxy && (state.proxyUrl == null || state.proxyUrl!.isEmpty)
            ? await SystemProxyDetector.detect()
            : const AutoProxyResult(proxyUrl: null, vpnActive: false);
    if (revision != _proxyRevision || emit.isDone) return;
    GetIt.I<DioClient>().setProxy(state.proxyUrl ?? result.proxyUrl);
    emit(state.copyWith(
        detectedProxy: result.proxyUrl, vpnActive: result.vpnActive));
  }

  Future<void> _onTheme(
    UpdateThemeMode event,
    Emitter<SettingsState> emit,
  ) async {
    await _repository.setThemeMode(event.mode);
    emit(state.copyWith(themeMode: event.mode));
  }

  Future<void> _onReading(
    UpdateReadingMode event,
    Emitter<SettingsState> emit,
  ) async {
    await _repository.setReadingMode(event.mode);
    emit(state.copyWith(readingMode: event.mode));
  }

  Future<void> _onDisplay(
    UpdateDisplayMode event,
    Emitter<SettingsState> emit,
  ) async {
    await _repository.setDisplayMode(event.mode);
    emit(state.copyWith(displayMode: event.mode));
  }

  Future<void> _onProxy(UpdateProxy event, Emitter<SettingsState> emit) async {
    final revision = ++_proxyRevision;
    emit(state.copyWith(proxyUrl: event.proxyUrl));
    final preparing = _network?.configure(
        manualProxy: state.proxyUrl, autoProxy: state.autoProxy);
    await Future.wait([
      _repository.setProxy(event.proxyUrl),
      if (preparing != null) preparing,
    ]);
    if (revision != _proxyRevision || emit.isDone) return;
    if (_network == null) GetIt.I<DioClient>().setProxy(state.effectiveProxy);
  }

  Future<void> _onToggleAutoProxy(
      ToggleAutoProxy event, Emitter<SettingsState> emit) async {
    final revision = ++_proxyRevision;
    emit(state.copyWith(autoProxy: event.enabled));
    final preparing = _network?.configure(
        manualProxy: state.proxyUrl, autoProxy: state.autoProxy);
    await Future.wait([
      _repository.setAutoProxy(event.enabled),
      if (preparing != null) preparing,
    ]);
    if (revision != _proxyRevision || emit.isDone || _network != null) return;
    final result =
        state.autoProxy && (state.proxyUrl == null || state.proxyUrl!.isEmpty)
            ? await SystemProxyDetector.detect()
            : const AutoProxyResult(proxyUrl: null, vpnActive: false);
    if (revision != _proxyRevision || emit.isDone) return;
    GetIt.I<DioClient>().setProxy(state.proxyUrl ?? result.proxyUrl);
    emit(state.copyWith(
        detectedProxy: result.proxyUrl, vpnActive: result.vpnActive));
  }

  Future<void> _onCacheLimit(
    UpdateCacheLimit event,
    Emitter<SettingsState> emit,
  ) async {
    if (_changingCacheLimit) {
      event.completer
          ?.completeError(StateError('Cache limit change in progress'));
      return;
    }
    _changingCacheLimit = true;
    try {
      if (![100, 200, 500, 1000, 2000].contains(event.mb)) {
        throw ArgumentError.value(event.mb, 'mb');
      }
      await _repository.setCacheLimit(event.mb);
      emit(state.copyWith(cacheLimitMB: event.mb));
      await _applyCacheLimit(event.mb);
      event.completer?.complete();
    } catch (error, stack) {
      event.completer?.completeError(error, stack);
    } finally {
      _changingCacheLimit = false;
    }
  }

  Future<void> _onToggleSite(
    ToggleSiteMode event,
    Emitter<SettingsState> emit,
  ) async {
    if (_changingSite || event.useExHentai == state.useExHentai) return;
    _changingSite = true;
    final previous = state.useExHentai;
    final revision = _sessionRevision();
    emit(state.copyWith(pendingSite: event.useExHentai, siteSwitchError: null));
    var saved = false;
    try {
      if (event.useExHentai) await _syncSiteCookies();
      if (revision != _sessionRevision() || emit.isDone) {
        throw StateError('Site preparation expired');
      }
      await _repository.setUseExHentai(event.useExHentai);
      saved = true;
      if (revision != _sessionRevision() || emit.isDone) {
        throw StateError('Site preparation expired');
      }
      // Only memory/index invalidation belongs on the switching path. Scoped
      // disk entries remain available when returning to this site.
      ReaderIndexCache.shared.clear();
      ReaderReentryCache.shared.clear();
      AppConstants.useExHentai = event.useExHentai;
      emit(state.copyWith(
          useExHentai: event.useExHentai,
          pendingSite: null,
          siteSwitchError: null));
    } catch (_) {
      if (saved) {
        try {
          await _repository.setUseExHentai(previous);
        } catch (_) {
          // Keep the running app on its last valid site; allow an explicit retry.
        }
      }
      if (!emit.isDone) {
        emit(state.copyWith(pendingSite: null, siteSwitchError: 'failed'));
      }
    } finally {
      _changingSite = false;
    }
  }

  Future<void> _onSyncMyTags(
    SyncMyTags event,
    Emitter<SettingsState> emit,
  ) async {
    try {
      final galleryRepo = GetIt.I<GalleryRepository>();
      final hiddenTags = await galleryRepo.fetchMyTags();
      await _repository.setHiddenTags(hiddenTags);
      emit(state.copyWith(hiddenTags: hiddenTags));
    } catch (_) {
      // Silently fail — keep existing hidden tags
    }
  }

  Future<void> _onUpdateLocale(
    UpdateLocale event,
    Emitter<SettingsState> emit,
  ) async {
    await _repository.setLocale(event.locale);
    emit(state.copyWith(locale: event.locale));
  }
}
