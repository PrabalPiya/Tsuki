import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';

void main() {
  test('default build uses live providers without bundled Firebase config', () {
    final config = AppConfig.fromEnvironment();
    expect(config.environment, AppEnvironment.production);
    expect(config.useDemoData, isFalse);
    expect(config.isFirebaseConfigured, isFalse);
    expect(config.firebaseProjectId, isEmpty);
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
      remoteCatalogUrl: '',
    );
    expect(config.useDemoData, isFalse);
    expect(config.isFirebaseConfigured, isFalse);
  });
}
