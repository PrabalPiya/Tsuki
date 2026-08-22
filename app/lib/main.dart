import 'dart:async';

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
  if (config.isFirebaseConfigured) {
    try {
      await Firebase.initializeApp(options: config.firebaseOptions)
          .timeout(const Duration(seconds: 6));
      unawaited(
        FirebaseAppCheck.instance
            .activate(androidProvider: AndroidProvider.playIntegrity)
            .timeout(const Duration(seconds: 6))
            .catchError((error) {
              debugPrint('App Check initialization skipped: $error');
            }),
      );
    } catch (error) {
      // A partially configured optional sync service must not block startup.
      debugPrint('Cloud sync initialization failed: $error');
      config = config.withoutFirebase();
    }
  }

  runApp(
    ProviderScope(
      overrides: [appConfigProvider.overrideWithValue(config)],
      child: const TsukiApp(),
    ),
  );
}
