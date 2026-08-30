import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../core/constants/app_constants.dart';
import '../../core/network/cookie_manager.dart' as app;
import '../../core/network/dio_client.dart';
import '../../core/network/eh_image_cache_manager.dart';
import '../../core/network/system_proxy_detector.dart';
import '../../repositories/gallery_repository.dart';
import '../../repositories/settings_repository.dart';
import 'settings_event.dart';
import 'settings_state.dart';

class SettingsBloc extends Bloc<SettingsEvent, SettingsState> {
  final SettingsRepository _repository;

  SettingsBloc(this._repository) : super(const SettingsState()) {
    on<LoadSettings>(_onLoad);
    on<UpdateThemeMode>(_onTheme);
    on<UpdateReadingMode>(_onReading);
    on<UpdateDisplayMode>(_onDisplay);
    on<UpdateProxy>(_onProxy);
    on<ToggleAutoProxy>(_onToggleAutoProxy);
    on<UpdateCacheLimit>(_onCacheLimit);
    on<ToggleSiteMode>(_onToggleSite);
    on<SyncMyTags>(_onSyncMyTags);
    on<UpdateLocale>(_onUpdateLocale);
  }

  Future<void> _onLoad(LoadSettings event, Emitter<SettingsState> emit) async {
    final useEx = _repository.getUseExHentai();
    AppConstants.useExHentai = useEx;

    final proxy = _repository.getProxy();
    final autoProxy = _repository.getAutoProxy();

    // Auto-detect proxy and VPN status
    String? detectedProxy;
    bool vpnActive = false;
    if (autoProxy && (proxy == null || proxy.isEmpty)) {
      final result = await SystemProxyDetector.detect();
      detectedProxy = result.proxyUrl;
      vpnActive = result.vpnActive;
    }

    // Apply: manual proxy > auto-detected > direct
    final effectiveProxy =
        (proxy != null && proxy.isNotEmpty) ? proxy : detectedProxy;
    GetIt.I<DioClient>().setProxy(effectiveProxy);

    emit(SettingsState(
      themeMode: _repository.getThemeMode(),
      readingMode: _repository.getReadingMode(),
      displayMode: _repository.getDisplayMode(),
      cacheLimitMB: _repository.getCacheLimit(),
      proxyUrl: proxy,
      autoProxy: autoProxy,
      detectedProxy: detectedProxy,
      vpnActive: vpnActive,
      useExHentai: useEx,
      hiddenTags: _repository.getHiddenTags(),
      locale: _repository.getLocale(),
    ));
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

  Future<void> _onProxy(
    UpdateProxy event,
    Emitter<SettingsState> emit,
  ) async {
    await _repository.setProxy(event.proxyUrl);
    final effective =
        event.proxyUrl ?? (state.autoProxy ? state.detectedProxy : null);
    GetIt.I<DioClient>().setProxy(effective);
    emit(state.copyWith(proxyUrl: event.proxyUrl));
  }

  Future<void> _onToggleAutoProxy(
    ToggleAutoProxy event,
    Emitter<SettingsState> emit,
  ) async {
    await _repository.setAutoProxy(event.enabled);

    String? detectedProxy;
    bool vpnActive = false;
    if (event.enabled && (state.proxyUrl == null || state.proxyUrl!.isEmpty)) {
      final result = await SystemProxyDetector.detect();
      detectedProxy = result.proxyUrl;
      vpnActive = result.vpnActive;
    }

    final effective = (state.proxyUrl != null && state.proxyUrl!.isNotEmpty)
        ? state.proxyUrl
        : detectedProxy;
    GetIt.I<DioClient>().setProxy(effective);

    emit(state.copyWith(
      autoProxy: event.enabled,
      detectedProxy: detectedProxy,
      vpnActive: vpnActive,
    ));
  }

  Future<void> _onCacheLimit(
    UpdateCacheLimit event,
    Emitter<SettingsState> emit,
  ) async {
    await _repository.setCacheLimit(event.mb);
    emit(state.copyWith(cacheLimitMB: event.mb));
  }

  Future<void> _onToggleSite(
    ToggleSiteMode event,
    Emitter<SettingsState> emit,
  ) async {
    AppConstants.useExHentai = event.useExHentai;
    await _repository.setUseExHentai(event.useExHentai);
    // Site-specific image URLs must not survive a mode switch.
    await EhImageCacheManager.instance.emptyCache();
    // Sync login cookies to ExHentai domain when switching to EX
    if (event.useExHentai) {
      await GetIt.I<app.CookieManager>().syncCookiesToExHentai();
    }
    emit(state.copyWith(useExHentai: event.useExHentai));
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
