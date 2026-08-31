import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

import 'image_http_client.dart';

/// Owns all cancellable network work started by one reader screen.
///
/// The Dio token cancels gallery HTML and thumbnail-page requests. The HTTP
/// client is used by cached_network_image's file service and is closed on exit
/// to abort active image-byte downloads as well.
class ReaderRequestController {
  ReaderRequestController({http.Client Function()? imageClientFactory})
      : _imageClientFactory = imageClientFactory ?? createImageHttpClient;

  final CancelToken cancelToken = CancelToken();
  final http.Client Function() _imageClientFactory;
  http.Client? _imageClient;

  bool get isCancelled => cancelToken.isCancelled;

  http.Client get imageClient {
    if (isCancelled) {
      throw StateError('The reader image request has been cancelled.');
    }
    return _imageClient ??= _imageClientFactory();
  }

  /// Associates an image URL with this reader session before it is handed to
  /// cached_network_image. The cache file service then selects this session's
  /// HTTP client for the request.
  void registerImageUrl(String url) {
    if (!isCancelled && url.isNotEmpty) {
      ReaderImageRequestRegistry.register(url, this);
    }
  }

  /// Cancels Dio requests and closes the HTTP client used for image bytes.
  /// Closing an http.Client aborts active requests and makes queued requests
  /// fail before they can start downloading.
  void cancel() {
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('Reader screen was closed.');
    }
    _imageClient?.close();
    ReaderImageRequestRegistry.releaseCancelledSession(this);
  }
}

/// Maps reader image URLs to the request controller that owns them.
///
/// The global image cache manager is shared by gallery lists and the reader.
/// This registry lets only reader-originated image requests use a cancellable
/// client, without interrupting image work on the screen beneath the reader.
class ReaderImageRequestRegistry {
  ReaderImageRequestRegistry._();

  static final Map<String, ReaderRequestController> _controllers = {};

  static void register(String url, ReaderRequestController controller) {
    _controllers[url] = controller;
  }

  static ReaderRequestController? controllerFor(String url) =>
      _controllers[url];

  /// Keep cancelled mappings briefly: flutter_cache_manager may have already
  /// queued a file request, and it must still select the closed client rather
  /// than fall back to the app-wide image client. New reader sessions replace
  /// matching URL mappings immediately.
  static void releaseCancelledSession(ReaderRequestController controller) {
    Timer(const Duration(seconds: 30), () {
      _controllers.removeWhere((_, value) => identical(value, controller));
    });
  }
}
