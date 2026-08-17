# Tsuki

Tsuki is an Android-first Flutter manga reader built around one calm loop:
**Search → Understand → Bookmark → Read**.

It presents canonical manga and chapters rather than websites. AniList supplies the
single consistent metadata/rating interpretation; MangaDex is the initial approved
English chapter/page source. Source selection, duplicate chapters, fallback,
progress, and tracked updates stay out of the user's way.

## Current implementation

- Premium dark, four-destination Android UI
- 300 ms cancellable suggestions and submitted cover grid
- Concise details, one bookmark action, and canonical chapter list
- Minimal Library with long-press drag removal and Undo
- Active/Caught Up dashboard
- Live Trending/Popular/Top Rated Discover stack powered by AniList
- Continuous vertical reader, bounded whole-chapter preloading, next-chapter prefetch, silent fallback, and automatic resume
- Google sign-in and Firestore sync through the deployed Tsuki project
- Deny-by-default rules, emulator tests, a production access gate, and account deletion
- Provider-neutral updater/matcher/resolver with SSRF and rate-limit defenses

The default build uses live AniList metadata/discovery, MangaDex English
chapters, Google sign-in, and Firestore sync. Known user data and the Firebase
account can be deleted directly from Settings; a paid private backend is not
required. If Firebase cannot initialize, the app retains a usable local profile.
Synthetic data is available only when demo mode is explicitly enabled.

## Run

1. Install Flutter stable and Android Studio.
2. Change directory to app.
3. Run: flutter pub get
4. Run: flutter run

Build a sideloadable APK with `flutter build apk --release`. A store release
must use your own private release signing key rather than the development key.

For cloud and signing details, continue with [Setup](docs/SETUP.md). Architecture and
trust boundaries are described in [Architecture](docs/ARCHITECTURE.md) and
[Security](docs/SECURITY.md).

## Screenshots

| Home | Search | Reader |
|---|---|---|
| Active/Caught Up dashboard | Suggestions and cover grid | Continuous vertical chapters |

Screenshot assets are intentionally left for branded fork builds; no copyrighted
manga pages or covers are bundled.

## Content and license

Code is MIT licensed. Manga content is not part of this repository and remains
provided by configured external services under their terms. A deployed reader
must retain MangaDex and scanlation-group attribution and comply with the current
MangaDex acceptable-use policy.
