import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/reader_entry_diagnostics.dart';
import '../../widgets/reader_presentation.dart';

/// Android returns immediately, before restored system bars can resize the
/// outgoing reader. Keep the native-style transition and back swipe on iOS.
class ReaderRoute<T> extends MaterialPageRoute<T> {
  final ReaderEntryDiagnostics diagnostics;
  ReaderRoute(
      {required WidgetBuilder builder,
      super.settings,
      ReaderEntryDiagnostics? diagnostics})
      : diagnostics = diagnostics ?? ReaderEntryDiagnostics(),
        super(
          allowSnapshotting: defaultTargetPlatform != TargetPlatform.android,
          builder: (context) => ReaderPresentation(
              diagnostics:
                  (ModalRoute.of(context) as ReaderRoute?)?.diagnostics,
              child: Builder(builder: builder)),
        );

  @override
  void dispose() {
    diagnostics.dispose();
    super.dispose();
  }

  @override
  // Keep the reader's own zoom, but do not zoom the Android page behind it.
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) =>
      defaultTargetPlatform != TargetPlatform.android &&
      super.canTransitionFrom(previousRoute);

  @override
  Duration get reverseTransitionDuration =>
      defaultTargetPlatform == TargetPlatform.android
          ? Duration.zero
          : super.reverseTransitionDuration;
}
