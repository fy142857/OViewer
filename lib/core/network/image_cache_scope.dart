import 'dart:convert';
import '../constants/app_constants.dart';

/// Disk identity survives navigation; request identity does not survive a switch.
class ImageCacheScope {
  static const header = 'X-OViewer-Image-Scope';
  static String _session = 'uninitialized';
  static int _sessionRevision = 0;
  static bool _ready = true;
  final String site;
  final String session;
  final int siteRevision;
  final int sessionRevision;

  const ImageCacheScope._(
      this.site, this.session, this.siteRevision, this.sessionRevision);

  factory ImageCacheScope.capture() => ImageCacheScope._(AppConstants.baseUrl,
      _session, AppConstants.siteRevision, _sessionRevision);

  static void setSession(String value, {bool ready = true}) {
    _session = value;
    _ready = ready;
    _sessionRevision++;
  }

  String key(String resource) =>
      'image-scope-v1:${jsonEncode([session, site, resource])}';
  String get requestTag =>
      jsonEncode([site, session, siteRevision, sessionRevision]);
  Map<String, String> get headers => {header: requestTag};

  factory ImageCacheScope.fromTag(String tag) {
    final values = jsonDecode(tag) as List;
    return ImageCacheScope._(values[0] as String, values[1] as String,
        values[2] as int, values[3] as int);
  }

  bool get isCurrent =>
      _ready &&
      site == AppConstants.baseUrl &&
      session == _session &&
      siteRevision == AppConstants.siteRevision &&
      sessionRevision == _sessionRevision;

  void ensureCurrent() {
    if (!isCurrent) throw ImageScopeExpired();
  }
}

class ImageScopeExpired extends StateError {
  ImageScopeExpired() : super('Image scope expired');
}
