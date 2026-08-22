# Tsuki

Tsuki is an Android-first Flutter manga reader focused on a simple reading loop:

**Search -> Understand -> Bookmark -> Read**

The app treats manga as canonical titles instead of exposing the user to a list
of source websites. Metadata comes from AniList, while readable chapters are
resolved from supported external manga sources. Tsuki keeps source matching,
duplicate chapter handling, fallbacks, reading progress, and updates mostly out
of the way so the user can focus on reading.

## What It Does

- Search for manga using AniList metadata.
- Browse Discover sections for trending, popular, and top-rated titles.
- View concise manga details, cover art, ratings, descriptions, and chapter
  lists.
- Bookmark titles into a personal library.
- Track active reads, caught-up titles, and chapter progress.
- Read chapters in a continuous vertical reader.
- Resume from saved progress automatically.
- Cache manga metadata, chapter indexes, images, and local reading state.
- Sync bookmarks and progress with Firebase when remote accounts are configured.
- Continue with a local profile if Firebase is unavailable.
- Delete user data and the Firebase account from Settings.

## Supported Sources

Tsuki separates metadata from chapter/page sources:

- Metadata and rankings: AniList
- Chapter and page sources: MangaDex, ComicK, MangaPill, WeebCentral, and Asura
- Demo catalog: available only when explicitly enabled for non-production builds

The source layer is provider-neutral. The app resolves conservative title
matches, merges duplicate chapter entries, prefers reliable direct-readable
copies, and silently falls back to another source when a chapter copy fails.

## App Structure

The Flutter app lives in `app/` and is organized by feature and shared core
services:

```text
app/lib
  core/
    auth/        Firebase authentication session state
    config/      build-time app configuration
    data/        catalog orchestration and source merging
    models/      manga, chapter, and reading progress models
    network/     shared HTTP and source failure handling
    state/       Riverpod providers and app state
    storage/     local cache, Firestore sync, and user storage
    theme/       visual theme
  features/
    discover/    rankings and discovery UI
    home/        active and caught-up dashboard
    library/     bookmarked titles
    manga_details/
    reader/      source adapters and reading UI
    search/      AniList search and metadata
    settings/
  navigation/    app shell and routes
  shared/        demo data, summaries, and reusable widgets
```

Supporting directories:

```text
backend/   Optional Node/Firebase Admin backend utilities
firebase/  Firestore rules, indexes, and emulator tests
.github/   CI, catalog publishing, CodeQL, and dependency automation
```

## Requirements

- Flutter stable
- Dart SDK supplied by Flutter
- Android Studio or Android SDK tooling
- Node.js 22 or newer for backend and Firestore rules tests
- Firebase CLI for Firestore emulator tests

Do not run `dart pub get` for the Flutter app. Use `flutter pub get` from the
`app/` directory so Flutter SDK dependencies can resolve correctly.

## Getting Started

Install Flutter, then run the app:

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

Release builds intended for distribution should use a private signing key. Do
not distribute builds signed only with local development credentials.

## Configuration

Runtime configuration is read from Dart compile-time environment values in
`app/lib/core/config/app_config.dart`.

Common values:

```text
APP_ENV                 development, staging, or production
USE_DEMO_DATA           enables demo data outside production
FIREBASE_PROJECT_ID     Firebase project ID
FIREBASE_APP_ID         Firebase app ID
FIREBASE_API_KEY        Firebase API key
FIREBASE_MESSAGING_SENDER_ID
BACKEND_BASE_URL        optional backend URL
REMOTE_CATALOG_URL      optional hosted catalog URL
```

Example development run with demo data:

```sh
cd app
flutter run --dart-define=APP_ENV=development --dart-define=USE_DEMO_DATA=true
```

Production mode always disables demo data, even if `USE_DEMO_DATA=true` is
provided.

## Firebase And User Data

Tsuki can use Firebase Authentication and Cloud Firestore for remote accounts,
bookmarks, and reading progress. If Firebase is not configured or cannot
initialize, the app falls back to a usable local profile.

Firestore data is scoped under each authenticated user. The Firebase rules are
deny-by-default and tested with the emulator test suite in `firebase/`.

Users can delete their account data from Settings. Account deletion removes
stored bookmarks, progress, profile data, username mapping, local session data,
and then deletes the Firebase Auth user when re-authentication requirements are
satisfied.

## Development Commands

Flutter app:

```sh
cd app
flutter pub get
dart format --output=none .
flutter analyze
flutter test
```

Optional backend:

```sh
cd backend
npm ci
npm test
npm start
```

Firestore rules:

```sh
cd firebase
npm ci --ignore-scripts
npm test
```

## CI

GitHub Actions runs:

- Flutter dependency resolution, formatting, analysis, and tests
- Backend Node tests
- Firestore emulator rules tests
- CodeQL scanning
- Scheduled catalog generation and GitHub Pages artifact deployment

The catalog workflow uses Flutter dependency resolution because the app depends
on Flutter SDK packages.

## Content, Attribution, And License

This repository contains application code only. Manga pages, covers, metadata,
and chapters are provided by configured external services and remain subject to
their own licenses and terms.

Deployed builds must retain required source and scanlation-group attribution and
must comply with each source provider's acceptable-use policy.

The code in this repository is licensed under the MIT License.
