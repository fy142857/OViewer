import 'package:flutter/material.dart';
import '../core/l10n/s.dart';

class GalleryWarningView extends StatelessWidget {
  final String message;
  final VoidCallback onContinue;
  const GalleryWarningView(
      {super.key, required this.message, required this.onContinue});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
        appBar: AppBar(title: Text(s.galleryContentWarning)),
        body: Center(
            child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.warning_amber_rounded, size: 48),
                  const SizedBox(height: 16),
                  Text(s.galleryWarningExplanation),
                  if (message.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(message)
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                      key: const ValueKey('continue-gallery'),
                      onPressed: onContinue,
                      child: Text(s.continueGallery)),
                  TextButton(
                      onPressed: () => Navigator.maybePop(context),
                      child: Text(s.cancel)),
                ]))));
  }
}
