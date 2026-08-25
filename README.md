# Tsuki

Tsuki is an Android-first, open-source Flutter manga reader. It combines manga
metadata with chapters from multiple sources, giving users one clean library,
continuous reading, and synced progress.

## Download

[Download Tsuki v1 for Android](https://github.com/PrabalPiya/Tsuki/raw/refs/heads/main/releases/tsuki_v1.apk)

The release-signed APK requires Android 7.0 or newer. Android may ask you to
allow installation from your browser or file manager.

## Features

- Search and discover manga using AniList metadata and rankings.
- View manga details, ratings, descriptions, and merged chapter lists.
- Bookmark manga in a personal library.
- Sync bookmarks and reading progress per Firebase account.
- Resume chapters from saved progress in a continuous vertical reader.
- Cache metadata, chapter indexes, images, and local reading state.
- Fall back between supported chapter sources when a copy is unavailable.

## Sources

- Metadata and rankings: AniList
- Chapters and pages: MangaDex, Demonic Scans, Manganato, and Asura Scans

Tsuki does not host manga content. Covers, metadata, chapters, and pages remain
the property of their respective providers and creators.

## Development

Requirements: Flutter stable, Android SDK, and Node.js 22 or newer.

```sh
cd app
flutter pub get
flutter run
```

Build a release APK:

```sh
cd app
flutter build apk --release
```

Distribution builds should use a private release signing key configured in
`app/android/key.properties`.

## Firebase Configuration

Account login, bookmark sync, and reading-progress sync require Firebase
Authentication and Cloud Firestore. Add your Android Firebase configuration at
`app/android/app/google-services.json`; a sanitized example is included beside
it.

Runtime settings are provided through Dart compile-time values such as
`APP_ENV`, `USE_DEMO_DATA`, `BACKEND_BASE_URL`, and `REMOTE_CATALOG_URL`.
Production mode always disables demo data.

Firestore data is separated by authenticated user UID. Security rules and
emulator tests are available in `firebase/`.

## Project Layout

```text
app/       Flutter Android application
backend/   Optional Node/Firebase Admin utilities
firebase/  Firestore rules, indexes, and tests
```

## License

Source code is available under the [MIT License](LICENSE).
