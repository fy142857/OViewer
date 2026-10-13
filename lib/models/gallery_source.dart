import '../core/constants/app_constants.dart';

/// The originating gallery site, not necessarily the image CDN's host.
enum GallerySource {
  eh,
  ex;

  String get baseUrl =>
      this == eh ? AppConstants.ehBaseUrl : AppConstants.exBaseUrl;
  String get label => this == eh ? 'E-Hentai (EH)' : 'ExHentai (EX)';
  String get shortName => name.toUpperCase();
  static GallerySource get current => AppConstants.useExHentai ? ex : eh;
  static GallerySource? parse(String? value) => switch (value) {
        'eh' => eh,
        'ex' => ex,
        _ => null,
      };
}
