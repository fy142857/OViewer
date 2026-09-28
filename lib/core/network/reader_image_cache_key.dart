/// H@H /h and /om routes can serve the same image through different hosts and
/// expiring access paths. The displayed file descriptor includes its content
/// hash, byte size, dimensions and format; keep all of these in the cache key.
String readerImageCacheKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !uri.host.toLowerCase().endsWith('.hath.network')) return url;
  final parts = uri.pathSegments;
  String? descriptor;
  if (parts.length >= 2 && parts[0] == 'h') descriptor = parts[1];
  // /om/session/original-file/displayed-file/resolution/access-key/filename
  if (parts.length >= 4 && parts[0] == 'om') descriptor = parts[3];
  if (descriptor == null ||
      !RegExp(r'^[a-f0-9]{40}-\d+-\d+-\d+-[a-z0-9]+$').hasMatch(descriptor)) {
    return url;
  }
  return 'reader-hath-v1:$descriptor';
}
