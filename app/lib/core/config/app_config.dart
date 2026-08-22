import 'package:firebase_core/firebase_core.dart';

enum AppEnvironment { development, staging, production }

class AppConfig {
  const AppConfig({
    required this.environment,
    required this.useDemoData,
    required this.firebaseProjectId,
    required this.firebaseAppId,
    required this.firebaseApiKey,
    required this.firebaseMessagingSenderId,
    required this.backendBaseUrl,
    required this.remoteCatalogUrl,
  });
  factory AppConfig.fromEnvironment() {
    const name = String.fromEnvironment('APP_ENV', defaultValue: 'production');
    final environment = AppEnvironment.values.firstWhere(
      (v) => v.name == name,
      orElse: () => AppEnvironment.development,
    );
    const project = String.fromEnvironment(
          'FIREBASE_PROJECT_ID',
        ),
        app = String.fromEnvironment(
          'FIREBASE_APP_ID',
        ),
        key = String.fromEnvironment(
          'FIREBASE_API_KEY',
        ),
        sender = String.fromEnvironment(
          'FIREBASE_MESSAGING_SENDER_ID',
        ),
        backend = String.fromEnvironment('BACKEND_BASE_URL'),
        remoteCatalog = String.fromEnvironment('REMOTE_CATALOG_URL'),
        demo = bool.fromEnvironment('USE_DEMO_DATA', defaultValue: false);
    return AppConfig(
      environment: environment,
      useDemoData: environment == AppEnvironment.production ? false : demo,
      firebaseProjectId: project,
      firebaseAppId: app,
      firebaseApiKey: key,
      firebaseMessagingSenderId: sender,
      backendBaseUrl: backend,
      remoteCatalogUrl: remoteCatalog,
    );
  }
  final AppEnvironment environment;
  final bool useDemoData;
  final String firebaseProjectId,
      firebaseAppId,
      firebaseApiKey,
      firebaseMessagingSenderId,
      backendBaseUrl,
      remoteCatalogUrl;

  bool get isFirebaseConfigured =>
      firebaseProjectId.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseApiKey.isNotEmpty &&
      firebaseMessagingSenderId.isNotEmpty;
  bool get isBackendConfigured =>
      isFirebaseConfigured && backendBaseUrl.isNotEmpty;
  AppConfig withoutFirebase() => AppConfig(
    environment: environment,
    useDemoData: useDemoData,
    firebaseProjectId: '',
    firebaseAppId: '',
    firebaseApiKey: '',
    firebaseMessagingSenderId: '',
    backendBaseUrl: '',
    remoteCatalogUrl: remoteCatalogUrl,
  );
  FirebaseOptions get firebaseOptions => FirebaseOptions(
    projectId: firebaseProjectId,
    appId: firebaseAppId,
    apiKey: firebaseApiKey,
    messagingSenderId: firebaseMessagingSenderId,
  );
}
