# Setup

## Production app

Tsuki is connected to the existing Firebase project `quiet-reader-app-26b7`.
Google Authentication, the Android signing fingerprints, Firestore rules and
indexes, and App Check registration are already configured. From `app`, run:

    flutter pub get
    flutter run

The normal build signs in with Google and syncs bookmarks, reading progress,
and settings. AniList and MangaDex remain the live content providers. If cloud
initialization fails, the app starts a local on-device profile so reading is not
blocked. To use the clearly labeled synthetic catalog for UI development:

    flutter run --dart-define=USE_DEMO_DATA=true

## Firebase administration

The owner account `blank00154@gmail.com` already has the required `appAccess`
custom claim. To authorize another account, authenticate with Application
Default Credentials and run:

    node backend/scripts/grant-access.mjs your@email.example

Deploy Firebase configuration from `firebase` with:

    firebase deploy --only auth,firestore:rules,firestore:indexes

The public Android Firebase values are embedded so an ordinary build works.
They can still be overridden with FIREBASE_PROJECT_ID, FIREBASE_APP_ID,
FIREBASE_API_KEY, FIREBASE_MESSAGING_SENDER_ID, and
GOOGLE_OAUTH_SERVER_CLIENT_ID dart defines.

App Check is registered with the Play Integrity provider, but enforcement is
intentionally off for the current sideloaded development-signed APK. Keep it
off until a private release certificate is configured and legitimate requests
are visible in App Check metrics. Never enable the debug provider in production
or commit a debug token.

The Node backend remains available for advanced hosted-provider workflows, but
the mobile app no longer needs it for account deletion. Settings deletes the
known Firestore user collections and Firebase Auth account directly under the
same owner-only rules.

If Firebase is absent or cannot initialize, the app deliberately retains the
usable on-device profile. This fallback does not grant access to Firestore.

Public client identifiers are not the security boundary. Authentication,
appAccess, rules, App Check, server validation, and IAM are.

## Android release signing

The repository builds a debug-signed release APK for convenient personal
sideloading when no key is configured. For distribution, create a private
keystore, copy `app/android/key.properties.example` to `key.properties`, and
fill in its four values. Both the properties file and keystores are ignored by
Git. Back up the keystore securely; losing it prevents updates to an installed
store app.

Use a supported JDK. If Flutter selected an incompatible installation, point it
to JDK 17 with `flutter config --jdk-dir=<path-to-jdk-17>` before building.

## Emulators

From firebase, install the Firebase CLI and rules-test dependencies, then run:

    firebase emulators:exec --only firestore "node --test tests/*.test.mjs"

Automated tests must use an emulator project only.

## Customization

- Accent/colors: app/lib/core/theme/app_theme.dart
- Sources: implement MangaSource and register it in the resolver
- Metadata: implement MetadataProvider
- Discover: implement RankingProvider
- Reader: features/reader/presentation/reader_screen.dart
- Schedule: inject a scheduler around backend/src/updater.mjs
