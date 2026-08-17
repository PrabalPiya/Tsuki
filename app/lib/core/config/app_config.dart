import 'package:firebase_core/firebase_core.dart';

enum AppEnvironment { development, staging, production }

class AppConfig {
  const AppConfig(
      {required this.environment,
      required this.useDemoData,
      required this.firebaseProjectId,
      required this.firebaseAppId,
      required this.firebaseApiKey,
      required this.firebaseMessagingSenderId,
      required this.backendBaseUrl,
      this.googleOAuthServerClientId = ''});
  factory AppConfig.fromEnvironment() {
    const name = String.fromEnvironment('APP_ENV', defaultValue: 'production');
    final environment = AppEnvironment.values.firstWhere((v) => v.name == name,
        orElse: () => AppEnvironment.development);
    const project = String.fromEnvironment('FIREBASE_PROJECT_ID',
            defaultValue: 'quiet-reader-app-26b7'),
        app = String.fromEnvironment('FIREBASE_APP_ID',
            defaultValue: '1:348316155116:android:48f1884387f456a2bb39c9'),
        key = String.fromEnvironment('FIREBASE_API_KEY',
            defaultValue: 'AIzaSyD15TzUFztqM1OUZ82r_4S67-E982_SO3Q'),
        sender = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID',
            defaultValue: '348316155116'),
        googleClient = String.fromEnvironment('GOOGLE_OAUTH_SERVER_CLIENT_ID',
            defaultValue:
                '348316155116-nm7eobqepr5t9bfeoc5pn8i9nk7cqjmt.apps.googleusercontent.com'),
        backend = String.fromEnvironment('BACKEND_BASE_URL'),
        demo = bool.fromEnvironment('USE_DEMO_DATA', defaultValue: false);
    return AppConfig(
        environment: environment,
        useDemoData: environment == AppEnvironment.production ? false : demo,
        firebaseProjectId: project,
        firebaseAppId: app,
        firebaseApiKey: key,
        firebaseMessagingSenderId: sender,
        backendBaseUrl: backend,
        googleOAuthServerClientId: googleClient);
  }
  final AppEnvironment environment;
  final bool useDemoData;
  final String firebaseProjectId,
      firebaseAppId,
      firebaseApiKey,
      firebaseMessagingSenderId,
      backendBaseUrl;
  final String googleOAuthServerClientId;
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
      googleOAuthServerClientId: '');
  FirebaseOptions get firebaseOptions => FirebaseOptions(
      projectId: firebaseProjectId,
      appId: firebaseAppId,
      apiKey: firebaseApiKey,
      messagingSenderId: firebaseMessagingSenderId);
}
