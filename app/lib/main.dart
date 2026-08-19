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

  // Load the tiny source-verified chapter summaries before the first frame.
  // Previously-seen manga can therefore show their latest chapter number in
  // the Details info chip immediately, without waiting for a source request.
  await ChapterIndexCache.warmGlobalSummaries();

  var config = AppConfig.fromEnvironment();
  if (config.isFirebaseConfigured) {
    try {
      await Firebase.initializeApp(options: config.firebaseOptions);
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.playIntegrity,
      );
    } catch (error) {
      // A partially configured optional sync service must not prevent local
      // reading. AuthController will transparently start a local profile.
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
