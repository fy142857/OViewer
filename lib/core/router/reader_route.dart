import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Android returns immediately, before restored system bars can resize the
/// outgoing reader. Keep the native-style transition and back swipe on iOS.
class ReaderRoute<T> extends MaterialPageRoute<T> {
  ReaderRoute({required super.builder, super.settings});

  @override
  Duration get reverseTransitionDuration =>
      defaultTargetPlatform == TargetPlatform.android
          ? Duration.zero
          : super.reverseTransitionDuration;
}
