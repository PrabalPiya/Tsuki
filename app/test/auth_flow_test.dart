import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsuki/app.dart';
import 'package:tsuki/core/auth/auth_controller.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/state/providers.dart';
import 'package:tsuki/navigation/app_router.dart';

const _testConfig = AppConfig(
  environment: AppEnvironment.development,
  useDemoData: true,
  firebaseProjectId: '',
  firebaseAppId: '',
  firebaseApiKey: '',
  firebaseMessagingSenderId: '',
  backendBaseUrl: '',
  remoteCatalogUrl: '',
);

class _FakeAuthController extends AuthController {
  _FakeAuthController() : super(_testConfig) {
    state = const AppSession(SessionStatus.signedOut);
  }

  int registerCalls = 0;

  @override
  Future<void> register({
    required String username,
    required String password,
  }) async {
    registerCalls++;
    state = const AppSession(SessionStatus.authenticating);
  }

  @override
  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    state = const AppSession(SessionStatus.authenticating);
    state = AppSession(SessionStatus.ready, uid: 'reader', username: username);
  }

  void failRegistration() {
    state = const AppSession(
      SessionStatus.error,
      message: 'Registration failed. Try again.',
    );
  }
}

GoRouter _testRouter({String initialLocation = '/home'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('Home route')),
      ),
      GoRoute(
        path: '/search',
        builder: (_, _) => const Scaffold(body: Text('Search route')),
      ),
    ],
  );
}

void main() {
  testWidgets('authentication layout remains usable on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final auth = _FakeAuthController();
    final router = _testRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((_) => auth),
          routerProvider.overrideWithValue(router),
        ],
        child: const TsukiApp(),
      ),
    );
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    final button = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(button);
    await tester.pump();

    expect(button, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('registration validates locally and keeps its mode on failure', (
    tester,
  ) async {
    final auth = _FakeAuthController();
    final router = _testRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((_) => auth),
          routerProvider.overrideWithValue(router),
        ],
        child: const TsukiApp(),
      ),
    );
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'reader_name');
    await tester.enterText(fields.at(1), 'secret1');
    await tester.enterText(fields.at(2), 'secret2');
    final createAccountButton = find.widgetWithText(
      FilledButton,
      'Create account',
    );
    await tester.ensureVisible(createAccountButton);
    await tester.tap(createAccountButton);
    await tester.pump();

    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(auth.registerCalls, 0);

    await tester.enterText(fields.at(2), 'secret1');
    await tester.ensureVisible(createAccountButton);
    await tester.tap(createAccountButton);
    await tester.pump();
    expect(find.text('Creating account...'), findsOneWidget);
    expect(auth.registerCalls, 1);

    auth.failRegistration();
    await tester.pumpAndSettle();
    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('Registration failed. Try again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-password')), findsOneWidget);
  });

  testWidgets('successful login redirects to home', (tester) async {
    final auth = _FakeAuthController();
    final router = _testRouter(initialLocation: '/search');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((_) => auth),
          routerProvider.overrideWithValue(router),
        ],
        child: const TsukiApp(),
      ),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'reader_name');
    await tester.enterText(fields.at(1), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Home route'), findsOneWidget);
    expect(find.text('Search route'), findsNothing);
  });
}
