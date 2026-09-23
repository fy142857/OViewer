# OViewer

[中文](README.md) / **[English](README.en.md)**

OViewer (Old Viewer) is a Flutter manga reader for Android and iOS, with support for E-Hentai and ExHentai. Browse galleries, search by tags, manage favorites, and choose how you read.

The project targets **Android 5.0 and iOS 12.0** as its minimum OS versions, keeping older devices in mind.

## Browse and discover

- Explore the latest and popular galleries, your favorites, and your reading history.
- Switch between list and card views on the home and search screens. Cards adapt to the screen width while keeping portrait cover proportions.
- Find manga using keywords, categories, and minimum-rating filters.
- See matching search history first as you type, followed by tag suggestions.
- Search with Chinese tag translations, multiword tags, and tag aliases.
- Find similar galleries from a gallery's detail page, or tap a tag to explore further.
- Paste a gallery URL to open its details directly.

Gallery details include the cover, uploader, language, page count, tags, and thumbnails, along with ratings, comments, and comment voting.

## Read your way

Choose **left-to-right paging, right-to-left paging, or continuous vertical scrolling**.

Zoom into images and jump between pages using the progress slider or thumbnail strip. Opening a preview starts at the selected page, while the regular reading entry resumes your saved progress.

Tap the reading area to show or hide the controls and status bar. Images load on demand and are cached after loading successfully for reuse when you return. Leaving the reader stops unfinished image loads, and failed images can be retried with a tap.

## Favorites and history

After signing in, you can manage cloud favorites and recognize favorited galleries by the **red heart** in list and grid views.

If you add or remove a favorite on another device using the same account, pull to refresh the current list to update its marker.

Browsing history and reading progress are stored on the current device, making it easy to pick up where you left off. Reading progress does not yet sync across devices.

## Accounts and personalization

- Sign in through the embedded browser or enter Cookies manually.
- Switch between E-Hentai and ExHentai, subject to your account's access permissions.
- Choose a Chinese or English interface.
- Use a light or dark theme, or follow the system setting.
- Set your default reading mode, configure a proxy, and clear the image cache.
- My Tags, Title Language, and Image Size open the corresponding settings for the current site.

## Download and install

Find installation packages on the project's [Releases](https://github.com/fy142857/OViewer/releases) or [Actions](https://github.com/fy142857/OViewer/actions) page:

| Platform | Package | Installation |
|----------|---------|--------------|
| Android | APK | Download and install |
| iOS | Unsigned IPA | Complete the appropriate signing and installation process for your device |

Use Releases for published versions and Actions for development branch builds.

## Current limitations

- Downloads and offline reading are still being improved. Online reading is recommended for now.
- Browsing history and reading progress do not yet sync across devices.
- The cache size limit setting is saved, but automatic cleanup based on that limit is not yet implemented. You can clear the image cache manually.
- iOS 12 is the deployment target; compatibility still needs to be verified on individual devices.

## Technical architecture

OViewer uses Flutter for Android and iOS, with separate layers for the interface, state management, and data access. Pages use BLoC to manage interaction state, while repositories access the sites and local storage.

Each search page maintains its own state, so similar-gallery searches do not overwrite the original list. The reader loads resources on demand and distinguishes completed cache entries from unfinished requests to reduce repeated loading.

### Technology stack

| Area | Technology |
|------|------------|
| Framework | Flutter `>=3.13.0 <3.17.0` / Dart `>=3.1.0 <4.0.0` |
| State management | flutter_bloc 8.x + equatable |
| Dependency injection | get_it |
| Networking | dio, http, cookie_jar |
| Parsing | html, converting site pages into application data models |
| Local storage | drift (SQLite) + shared_preferences |
| Images and caching | cached_network_image + flutter_cache_manager |
| Reader interaction | photo_view + scrollable_positioned_list |
| Login and site settings | flutter_inappwebview 5.8.x |
| Automated builds | GitHub Actions, producing Android APKs and unsigned iOS IPAs |

Automated builds currently use Flutter 3.16.0. Chinese tag translations are provided by **EhTagTranslation**.

### Project structure

```text
lib/
├── main.dart                    # App initialization and dependency registration
├── app.dart                     # App configuration, themes, and global state
├── core/
│   ├── constants/               # Site URLs, endpoints, and app constants
│   ├── l10n/                    # Chinese / English interface strings
│   ├── network/                 # Requests, Cookies, proxies, and image loading
│   ├── parser/                  # Gallery, search, tag, and comment parsing
│   ├── router/                  # Page routes and lifecycle observation
│   ├── storage/                 # Database, preferences, and reader index cache
│   ├── theme/                   # Themes and colors
│   └── utils/                   # Links, titles, tag queries, and autocomplete
├── models/                      # Data models
├── repositories/                # Network and local data access
├── blocs/                       # Browsing, search, reader, and favorites state
├── widgets/                     # Reusable cards, thumbnails, rating widgets, etc.
└── screens/                     # Pages
    ├── home/                    # Home
    ├── search/                  # Search
    ├── gallery_detail/          # Gallery details
    ├── thumbnail_preview/       # Thumbnail preview
    ├── reader/                  # Reader
    ├── favorites/               # Favorites
    ├── history/                 # Browsing history
    ├── comments/                # Comments
    ├── download/                # Download management
    ├── login/                   # Login
    └── settings/                # App and site settings

android/                         # Android platform project
ios/                             # iOS platform project
test/                            # Unit and widget regression tests
.github/workflows/               # Android / iOS automated builds
```

## Feedback and contributions

Found a problem or have a feature suggestion? Please open an [Issue](https://github.com/fy142857/OViewer/issues). Pull requests are also welcome.

When reporting a problem, include the app version, device and OS version, and steps to reproduce it. Hide sensitive information such as account details and Cookies in screenshots.

## License

This project is licensed under the **Apache License 2.0**.

## Special thanks

Thank you to [EhTagTranslation/Database](https://github.com/EhTagTranslation/Database) for providing Chinese tag translations.
