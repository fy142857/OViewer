import '../../models/reader_page_layout.dart';
import '../../models/floating_back_settings.dart';
import 'package:equatable/equatable.dart';

const _sentinel = Object();

class SettingsState extends Equatable {
  final FloatingBackSettings floatingBack;
  final int themeMode; // 0=system, 1=light, 2=dark
  final ReaderPageTransition pageTransition;
  final bool savingPageTransition;
  final bool volumeKeys, savingVolumeKeys;
  final ReaderPageLayout pageLayout;
  final ReaderSpreadAlignment spreadAlignment;
  final int readingMode; // 0=LR, 1=RL, 2=vertical
  final int preloadCount;
  final bool savingPreloadCount;
  final int displayMode; // 0=list, 1=grid
  final int cacheLimitMB;
  final String? proxyUrl;
  final bool autoProxy;
  final String? detectedProxy; // system proxy detected at startup
  final bool vpnActive; // VPN interface detected (Clash VPN mode etc.)
  final bool useExHentai;
  final bool? pendingSite;
  final String? siteSwitchError;
  bool get switchingSite => pendingSite != null;
  bool get displayedSite => pendingSite ?? useExHentai;
  final List<String> hiddenTags;
  final String locale;

  const SettingsState({
    this.floatingBack = const FloatingBackSettings(),
    this.themeMode = 0,
    this.readingMode = 0,
    this.preloadCount = 1,
    this.savingPreloadCount = false,
    this.pageTransition = ReaderPageTransition.slide,
    this.savingPageTransition = false,
    this.volumeKeys = false,
    this.savingVolumeKeys = false,
    this.pageLayout = ReaderPageLayout.single,
    this.spreadAlignment = ReaderSpreadAlignment.width,
    this.displayMode = 0,
    this.cacheLimitMB = 500,
    this.proxyUrl,
    this.autoProxy = true,
    this.detectedProxy,
    this.vpnActive = false,
    this.useExHentai = false,
    this.pendingSite,
    this.siteSwitchError,
    this.hiddenTags = const [],
    this.locale = 'zh',
  });

  SettingsState copyWith({
    FloatingBackSettings? floatingBack,
    int? themeMode,
    int? readingMode,
    int? preloadCount,
    bool? savingPreloadCount,
    ReaderPageTransition? pageTransition,
    bool? savingPageTransition,
    bool? volumeKeys,
    bool? savingVolumeKeys,
    ReaderPageLayout? pageLayout,
    ReaderSpreadAlignment? spreadAlignment,
    int? displayMode,
    int? cacheLimitMB,
    Object? proxyUrl = _sentinel,
    bool? autoProxy,
    Object? detectedProxy = _sentinel,
    bool? vpnActive,
    bool? useExHentai,
    Object? pendingSite = _sentinel,
    Object? siteSwitchError = _sentinel,
    List<String>? hiddenTags,
    String? locale,
  }) {
    return SettingsState(
      floatingBack: floatingBack ?? this.floatingBack,
      themeMode: themeMode ?? this.themeMode,
      readingMode: readingMode ?? this.readingMode,
      preloadCount: preloadCount ?? this.preloadCount,
      savingPreloadCount: savingPreloadCount ?? this.savingPreloadCount,
      pageTransition: pageTransition ?? this.pageTransition,
      savingPageTransition: savingPageTransition ?? this.savingPageTransition,
      volumeKeys: volumeKeys ?? this.volumeKeys,
      savingVolumeKeys: savingVolumeKeys ?? this.savingVolumeKeys,
      pageLayout: pageLayout ?? this.pageLayout,
      spreadAlignment: spreadAlignment ?? this.spreadAlignment,
      displayMode: displayMode ?? this.displayMode,
      cacheLimitMB: cacheLimitMB ?? this.cacheLimitMB,
      proxyUrl: proxyUrl == _sentinel ? this.proxyUrl : proxyUrl as String?,
      autoProxy: autoProxy ?? this.autoProxy,
      detectedProxy: detectedProxy == _sentinel
          ? this.detectedProxy
          : detectedProxy as String?,
      vpnActive: vpnActive ?? this.vpnActive,
      useExHentai: useExHentai ?? this.useExHentai,
      pendingSite:
          pendingSite == _sentinel ? this.pendingSite : pendingSite as bool?,
      siteSwitchError: siteSwitchError == _sentinel
          ? this.siteSwitchError
          : siteSwitchError as String?,
      hiddenTags: hiddenTags ?? this.hiddenTags,
      locale: locale ?? this.locale,
    );
  }

  /// The effective proxy: manual proxy takes priority, then auto-detected.
  /// If VPN is active, no explicit proxy needed (traffic already routed).
  String? get effectiveProxy => proxyUrl ?? (autoProxy ? detectedProxy : null);

  @override
  List<Object?> get props => [
        floatingBack,
        themeMode,
        readingMode,
        preloadCount,
        savingPreloadCount,
        pageTransition,
        savingPageTransition,
        volumeKeys,
        savingVolumeKeys,
        pageLayout,
        spreadAlignment,
        displayMode,
        cacheLimitMB,
        proxyUrl,
        autoProxy,
        detectedProxy,
        vpnActive,
        useExHentai,
        pendingSite,
        siteSwitchError,
        hiddenTags,
        locale
      ];
}
