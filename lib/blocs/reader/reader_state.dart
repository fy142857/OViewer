import '../../models/reader_page_layout.dart';
import '../../models/reader_preload_window.dart';
import 'package:equatable/equatable.dart';
import '../../models/gallery_image.dart';
import '../../models/reader_page_resource.dart';
import '../../models/offline_book.dart';
import '../../core/parser/gallery_detail_parser.dart';

enum ReaderStatus { initial, loading, ready, contentWarning, error, deleted }

class ReaderState extends Equatable {
  final OfflineBook? offlineBook;
  final ReaderStatus status;
  final int gid;
  final String token;
  final int currentPage;
  final int totalPages;
  final Map<int, GalleryImage> loadedImages;
  final Map<int, ThumbnailInfo> thumbnails;
  final Set<int> loadingThumbnails;
  final Set<int> failedThumbnails;
  final Set<int> loadingIndices;
  final Set<int> failedIndices;
  final Map<int, int> imageAttempts;
  final Map<int, ReaderPageResource> readyResources;
  final Set<int> cacheOnlyPages;
  final bool showUI;
  final ReaderPageLayout pageLayout;
  final ReaderSpreadAlignment spreadAlignment;
  final int readingMode; // 0=LR, 1=RL, 2=vertical
  final int preloadCount;
  final Set<int> visiblePages;
  final String? errorMessage;

  const ReaderState({
    this.offlineBook,
    this.status = ReaderStatus.initial,
    this.gid = 0,
    this.token = '',
    this.currentPage = 0,
    this.totalPages = 0,
    this.loadedImages = const {},
    this.thumbnails = const {},
    this.loadingThumbnails = const {},
    this.failedThumbnails = const {},
    this.loadingIndices = const {},
    this.failedIndices = const {},
    this.imageAttempts = const {},
    this.readyResources = const {},
    this.cacheOnlyPages = const {},
    this.showUI = false,
    this.readingMode = 0,
    this.preloadCount = 1,
    this.visiblePages = const {},
    this.pageLayout = ReaderPageLayout.single,
    this.spreadAlignment = ReaderSpreadAlignment.width,
    this.errorMessage,
  });

  ReaderSpreads get spreads => ReaderSpreads(totalPages, pageLayout);
  ReaderPreloadWindow get preloadWindow =>
      ReaderPreloadWindow(spreads, currentPage, preloadCount,
          visiblePages: visiblePages, expandAroundVisible: readingMode == 2);

  GalleryImage? get currentImage => loadedImages[currentPage];

  ReaderState copyWith({
    OfflineBook? offlineBook,
    ReaderStatus? status,
    int? gid,
    String? token,
    int? currentPage,
    int? totalPages,
    Map<int, GalleryImage>? loadedImages,
    Map<int, ThumbnailInfo>? thumbnails,
    Set<int>? loadingThumbnails,
    Set<int>? failedThumbnails,
    Set<int>? loadingIndices,
    Set<int>? failedIndices,
    Map<int, int>? imageAttempts,
    Map<int, ReaderPageResource>? readyResources,
    Set<int>? cacheOnlyPages,
    bool? showUI,
    int? readingMode,
    int? preloadCount,
    Set<int>? visiblePages,
    ReaderPageLayout? pageLayout,
    ReaderSpreadAlignment? spreadAlignment,
    String? errorMessage,
  }) {
    return ReaderState(
      offlineBook: offlineBook ?? this.offlineBook,
      status: status ?? this.status,
      gid: gid ?? this.gid,
      token: token ?? this.token,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      loadedImages: loadedImages ?? this.loadedImages,
      thumbnails: thumbnails ?? this.thumbnails,
      loadingThumbnails: loadingThumbnails ?? this.loadingThumbnails,
      failedThumbnails: failedThumbnails ?? this.failedThumbnails,
      loadingIndices: loadingIndices ?? this.loadingIndices,
      failedIndices: failedIndices ?? this.failedIndices,
      imageAttempts: imageAttempts ?? this.imageAttempts,
      readyResources: readyResources ?? this.readyResources,
      cacheOnlyPages: cacheOnlyPages ?? this.cacheOnlyPages,
      showUI: showUI ?? this.showUI,
      readingMode: readingMode ?? this.readingMode,
      preloadCount: preloadCount ?? this.preloadCount,
      visiblePages: visiblePages ?? this.visiblePages,
      pageLayout: pageLayout ?? this.pageLayout,
      spreadAlignment: spreadAlignment ?? this.spreadAlignment,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [
        offlineBook,
        status,
        gid,
        token,
        currentPage,
        totalPages,
        loadedImages,
        thumbnails,
        loadingThumbnails,
        failedThumbnails,
        loadingIndices,
        failedIndices,
        imageAttempts,
        readyResources,
        cacheOnlyPages,
        showUI,
        readingMode,
        preloadCount,
        visiblePages,
        pageLayout,
        spreadAlignment,
        errorMessage,
      ];
}
