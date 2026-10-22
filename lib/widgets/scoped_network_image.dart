import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../core/network/image_cache_scope.dart';

CachedNetworkImage scopedNetworkImage({
  required String imageUrl,
  required BaseCacheManager cacheManager,
  BoxFit? fit,
  PlaceholderWidgetBuilder? placeholder,
  LoadingErrorWidgetBuilder? errorWidget,
}) {
  final scope = ImageCacheScope.capture();
  return CachedNetworkImage(
    key: ValueKey('${scope.requestTag}:$imageUrl'),
    imageUrl: imageUrl,
    cacheKey: scope.key(imageUrl),
    httpHeaders: scope.headers,
    cacheManager: cacheManager,
    fit: fit,
    placeholder: placeholder,
    errorWidget: errorWidget,
  );
}

CachedNetworkImageProvider scopedNetworkImageProvider(String url,
    {required BaseCacheManager cacheManager}) {
  final scope = ImageCacheScope.capture();
  return CachedNetworkImageProvider(url,
      cacheManager: cacheManager,
      cacheKey: scope.key(url),
      headers: scope.headers);
}
