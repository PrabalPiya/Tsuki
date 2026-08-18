import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';

void main() {
  test('default build uses live providers instead of synthetic data', () {
    final config = AppConfig.fromEnvironment();
    expect(config.environment, AppEnvironment.production);
    expect(config.useDemoData, isFalse);
    expect(config.isFirebaseConfigured, isTrue);
    expect(config.firebaseProjectId, 'quiet-reader-app-26b7');
    expect(config.googleOAuthServerClientId, isNotEmpty);
  });

  test('production config cannot enable demo data', () {
    const config = AppConfig(
      environment: AppEnvironment.production,
      useDemoData: false,
      firebaseProjectId: '',
      firebaseAppId: '',
      firebaseApiKey: '',
      firebaseMessagingSenderId: '',
      backendBaseUrl: '',
    );
    expect(config.useDemoData, isFalse);
    expect(config.isFirebaseConfigured, isFalse);
  });
}
