# OViewer WebView 5.8 backport

Version: `5.8.0+oviewer.1`. The package name and all Dart APIs, MethodChannels,
Android code and bundled resources are unchanged. Root `pubspec.yaml` uses this
directory directly; no build step edits the global pub cache.

## Source and license

- Official archive: https://pub.dev/api/archives/flutter_inappwebview-5.8.0.tar.gz
- SHA-256: `d198297060d116b94048301ee6749cd2e7d03c1f2689783f52d210a6b7aba350`
- Upstream license: [Apache-2.0](LICENSE), preserved verbatim.
- Included: `lib/`, `android/`, `ios/`, `pubspec.yaml`, `README.md`, `CHANGELOG.md`, `LICENSE`.
- Excluded: example applications, test servers/certificates, upstream development tooling.
- `UPSTREAM.json` records every retained file with upstream and patched hashes.
  UTF-8 text uses LF for hashing; binary assets remain byte-exact.

## Allowed changes

1. `pubspec.yaml`: local build suffix and modification notice only.
2. `ios/Classes/InAppWebView/InAppWebView.swift`: conditional `evaluateJavaScript`
   override, backported from `flutter_inappwebview_ios` 1.1.2 (the Xcode 16 fix
   first shipped in 1.1.0; the old-compiler fallback was subsequently restored).
   Swift compiler 6+ uses `@MainActor @Sendable`; older compilers keep the
   original signature. Both branches preserve 5.8's `options` / Apple Pay
   behavior and forward to `super` identically.

Reference: https://pub.dev/packages/flutter_inappwebview_ios/changelog

Verify locally with `python -m scripts.verify_webview_vendor --check-resolution`.
Both CI workflows additionally use `--download-upstream` to verify the archive
hash, complete retained file inventory and exact permitted transformation.
Native compilation and iOS 12 device acceptance remain separate requirements.
