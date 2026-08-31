import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/state/providers.dart';
import 'core/storage/chapter_index_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 120
    ..maximumSizeBytes = 128 << 20;

  // Start loading the tiny source-verified chapter summaries before runApp.
  // Previously-seen manga can therefore show their latest chapter number in
  // the Details info chip immediately, without waiting for a source request.
  unawaited(
    ChapterIndexCache.warmGlobalSummaries().catchError((error) {
      debugPrint('Chapter summary warmup skipped: $error');
    }),
  );

  var config = AppConfig.fromEnvironment();
  try {
    // Firebase Core reads bundled Android resources locally. Do not turn a
    // slow cold/debug start into a permanently account-less app by timing this
    // initialization out.
    final firebaseApp = await (config.isFirebaseConfigured
        ? Firebase.initializeApp(options: config.firebaseOptions)
        : Firebase.initializeApp());
    if (!config.isFirebaseConfigured) {
      config = config.withFirebaseOptions(firebaseApp.options);
    }
  } catch (error, stackTrace) {
    // An absent or invalid sync service must not block the rest of startup.
    debugPrint('Cloud sync initialization failed: $error\n$stackTrace');
    config = config.withoutFirebase();
  }

  if (config.isFirebaseConfigured) {
    try {
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: false,
      );
    } catch (error) {
      // Settings can already be locked after a hot restart. That does not mean
      // Firebase Auth or the account service is unavailable.
      debugPrint('Firestore settings unchanged: $error');
    }

    unawaited(
      FirebaseAppCheck.instance
          .activate(androidProvider: AndroidProvider.playIntegrity)
          .timeout(const Duration(seconds: 6))
          .catchError((error) {
            debugPrint('App Check initialization skipped: $error');
          }),
    );
  }

  runApp(
    ProviderScope(
      overrides: [appConfigProvider.overrideWithValue(config)],
      child: const TsukiApp(),
    ),
  );
}
