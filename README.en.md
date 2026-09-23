# OViewer

[中文](README.md) / **[English](README.en.md)**

OViewer (Old Viewer) is a Flutter manga reader for E-Hentai and ExHentai on Android and iOS. The configured minimum OS versions are Android 5.0 (API 21) and iOS 12.0.

## Features

### Browsing and search

- Four home tabs: Latest, Popular, History, and Favorites, with list / grid layouts and loading placeholders.
- Keyword search, category and minimum-rating filters, and direct navigation by entering a gallery URL.
- Autocomplete shows matching local search history first, followed by tag suggestions, with duplicate candidates removed.
- Chinese tag translations and autocomplete. Multiword tags replace the complete matching phrase, respecting the cursor position and preserving other search conditions.
- Tag alias support: `artist:"moxueyin | jiuxueran$"` is submitted as `artist:"moxueyin$"`. History retains the original input.
- Similar-gallery and tag searches. Each search page owns its results and pagination state, preserving the original list and scroll position when navigating back.
- Gallery details, grouped tags, comments and voting, ratings, and a dedicated thumbnail preview screen. Sprite thumbnails are cropped correctly in portrait and landscape layouts.

### Reader

- Left-to-right, right-to-left, and continuous vertical reading, with zoom, a page slider, and a thumbnail strip.
- Opening a preview starts at the selected page; the regular reading entry restores saved progress.
- A single tap toggles the reader controls and system status bar together.
- Page indices and nearby resources load on demand. Recent index data from gallery details and previews is reused, avoiding a full-gallery index scan on entry.
- Leaving the reader immediately cancels unfinished full-image and thumbnail requests. They are requested again on demand when reopening.
- Successfully loaded images remain in the disk cache and are reused on valid cache hits. Failed or cancelled loads are not cached as successful results and can be retried on reopening or with the retry button.

### Accounts and settings

- WebView login and manual Cookie login, with E-Hentai / ExHentai switching.
- Local favorites, cloud favorite synchronization, browsing history, and reading progress.
- Loading, refreshing, or paginating a list reads cloud favorite markers for the red hearts in list and grid layouts. Favorite changes on other devices appear when the list is fetched again.
- Chinese / English UI, system / light / dark themes, and a default reading mode.
- My Tags, Title Language, and Image Size open the current site's settings. Login cookies are synchronized before the embedded page loads.
- Manual proxy configuration, automatic proxy detection, image cache clearing, and download storage usage.
- Download task lists, pause / resume controls, and progress tracking; see the limitations below.

## Current limitations

- Downloads need further work: image downloads currently pass through a text response before being written to disk, and completed tasks open the online reader. A reliable offline reading flow is not yet implemented, and downloads are not guaranteed to continue when the OS suspends the app.
- The cache size limit setting is saved but is not yet connected to disk-capacity-based eviction. Manual image cache clearing is available.
- iOS 12 is the deployment target, not a claim of testing on every device. Older OS support needs to be checked again when upgrading Flutter or plugins.

## Technology

| Area | Implementation |
|------|----------------|
| Framework | Flutter `>=3.13.0 <3.17.0`, Dart `>=3.1.0 <4.0.0`; CI uses Flutter 3.16.0 |
| State / dependency injection | flutter_bloc, equatable, get_it |
| Networking and parsing | dio, http, cookie_jar, html |
| Local storage | drift (SQLite), shared_preferences |
| Images and reading | cached_network_image, flutter_cache_manager, photo_view, scrollable_positioned_list |
| Embedded browser | flutter_inappwebview 5.8.x (constraint: `^5.8.0`) |
| Automated builds | GitHub Actions: Android APK and unsigned iOS IPA |

See [pubspec.yaml](pubspec.yaml) for constraints and [pubspec.lock](pubspec.lock) for resolved dependency versions.

## Project layout

```text
lib/
├── main.dart              # Initialization and dependency registration
├── app.dart               # App, themes, and global state
├── core/
│   ├── constants/         # Site and endpoint constants
│   ├── l10n/              # Chinese / English strings
│   ├── network/           # Cookies, proxies, image requests, reader sessions
│   ├── parser/            # Gallery, search, and tag HTML parsing
│   ├── router/            # Routes and page lifecycle observation
│   ├── storage/           # Database, preferences, reader index cache
│   ├── theme/             # Themes
│   └── utils/             # URLs, titles, tag queries, and autocomplete
├── models/                # Data models
├── repositories/          # Data access
├── blocs/                 # Page and business state
├── widgets/               # Reusable components
└── screens/               # Home, details, reader, search, settings, etc.

test/                      # Parser, repository, BLoC, network, and widget tests
.github/workflows/         # Android / iOS automated builds
```

## Development setup

- Use Flutter / Dart SDKs within the constraints above. CI pins Flutter 3.16.0.
- Android builds use JDK 17, Android SDK Platform 35, and Build Tools 35.0.0. The project configures AGP 8.6.1 and Gradle 8.7, with a minimum runtime API of 21.
- Local iOS builds require macOS, Xcode, and CocoaPods. CI uses macOS 14 / Xcode 15.4.

```bash
git clone https://github.com/fy142857/OViewer.git
cd OViewer
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

Generated database files are not committed. Run code generation before the first launch and after changing database models.

```bash
flutter test
flutter analyze
```

Tests cover search history and autocomplete, nested search navigation, reader positioning, request cancellation, image cache reuse, portrait / landscape thumbnails, Cookie synchronization, and HTML parsing. See [test/](test/) for the cases. Automated tests do not replace device testing. The current mobile build workflows do not run these tests or static analysis; run the relevant checks separately before committing.

## Building and installation

### Android APK

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`.

The current `release` build uses the debug signing configuration. Configure your own signing credentials before production distribution.

### Unsigned iOS IPA

On macOS, after installing dependencies and generating code, follow the current CI build procedure:

```bash
flutter build ios --release --no-codesign --config-only
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination generic/platform=iOS \
  -derivedDataPath build/ios/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO
mkdir -p build/ios/ipa/Payload
cp -R build/ios/DerivedData/Build/Products/Release-iphoneos/Runner.app build/ios/ipa/Payload/
(cd build/ios/ipa && zip -r OViewer.ipa Payload)
```

Output: `build/ios/ipa/OViewer.ipa`. An unsigned IPA requires an appropriate signing and installation process for the device; it is not a ready-to-install signed package. The deployment target is set to 12.0 in the [Podfile](ios/Podfile) and the iOS project.

### GitHub Actions

| Workflow | Output | Runner / toolchain |
|----------|--------|--------------------|
| [Build Android APK](.github/workflows/build_android.yml) | `app-release.apk` | ubuntu-latest / JDK 17 / Flutter 3.16.0 |
| [Build iOS IPA](.github/workflows/build_ios.yml) | `OViewer.ipa` (unsigned) | macos-14 / Xcode 15.4 / Flutter 3.16.0 |

- Builds run on pushes to `main` or `dev`, `v*` tag pushes, and pull requests targeting `main`.
- Branch pushes and PRs that only change Markdown, `docs/`, or `LICENSE*` files skip builds. These path filters do not affect tag pushes or manual runs.
- Manual run: repository Actions → select a workflow → Run workflow.
- Installers are uploaded as individual artifacts and retained for 30 days. Builds for `v*` tags also upload them to GitHub Releases.

To publish, use a version tag that does not already exist, for example:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## License

[Apache License 2.0](LICENSE)
