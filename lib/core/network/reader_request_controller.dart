import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

import 'image_http_client.dart';

/// Owns all cancellable network work started by one reader screen.
///
/// The Dio token cancels gallery HTML and thumbnail-page requests. The HTTP
/// client is used by reader image providers and is closed on exit to abort
/// both full-size images and thumbnail downloads.
class ReaderRequestController {
  ReaderRequestController({http.Client Function()? imageClientFactory})
      : _imageClientFactory = imageClientFactory ?? createImageHttpClient;

  final CancelToken cancelToken = CancelToken();
  final http.Client Function() _imageClientFactory;
  http.Client? _imageClient;
  final Set<void Function()> _cancelListeners = {};

  bool get isCancelled => cancelToken.isCancelled;

  http.Client get imageClient {
    if (isCancelled) {
      throw StateError('The reader image request has been cancelled.');
    }
    return _imageClient ??= _imageClientFactory();
  }

  void onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _cancelListeners.add(listener);
    }
  }

  /// Cancels Dio requests and closes the HTTP client used for image bytes.
  /// Closing an http.Client aborts active requests and makes queued requests
  /// fail before they can start downloading.
  void cancel() {
    if (isCancelled) return;
    cancelToken.cancel('Reader screen was closed.');
    _imageClient?.close();
    for (final listener in _cancelListeners) {
      listener();
    }
    _cancelListeners.clear();
  }
}
