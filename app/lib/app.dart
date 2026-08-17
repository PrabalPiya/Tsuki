import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/auth/auth_controller.dart';
import 'core/state/providers.dart';
import 'core/theme/app_theme.dart';
import 'navigation/app_router.dart';

class TsukiApp extends ConsumerWidget {
  const TsukiApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authProvider);
    if (session.status != SessionStatus.ready) {
      return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          home: _AccessGate(
              session: session,
              onSignIn: () => ref.read(authProvider.notifier).signIn(),
              onSignOut: () => ref.read(authProvider.notifier).signOut()));
    }
    return MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: 'Tsuki',
        theme: AppTheme.dark,
        routerConfig: ref.watch(routerProvider));
  }
}

class _AccessGate extends StatelessWidget {
  const _AccessGate(
      {required this.session, required this.onSignIn, required this.onSignOut});
  final AppSession session;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  @override
  Widget build(BuildContext context) => Scaffold(
      body: DecoratedBox(
          decoration: const BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                AppColors.background,
                Color(0xFF12111C),
                AppColors.background
              ])),
          child: SafeArea(
              child: Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Card(
                              child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(24, 28, 24, 24),
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                            width: 76,
                                            height: 76,
                                            decoration: BoxDecoration(
                                                color: AppColors.accent
                                                    .withValues(alpha: .16),
                                                borderRadius:
                                                    BorderRadius.circular(24),
                                                border: Border.all(
                                                    color: AppColors.outline)),
                                            child: const Icon(
                                                Icons.auto_stories_rounded,
                                                size: 38,
                                                color: AppColors.accent)),
                                        const SizedBox(height: 22),
                                        Text('Tsuki',
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineLarge),
                                        const SizedBox(height: 10),
                                        Text(session.message ?? _message,
                                            textAlign: TextAlign.center,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                    color: AppColors.muted)),
                                        if (session.status ==
                                                SessionStatus.loading ||
                                            session.status ==
                                                SessionStatus.backendMissing)
                                          const Padding(
                                              padding: EdgeInsets.only(top: 24),
                                              child:
                                                  CircularProgressIndicator()),
                                        if (session.status ==
                                                SessionStatus.signedOut ||
                                            session.status ==
                                                SessionStatus.error) ...[
                                          const SizedBox(height: 28),
                                          SizedBox(
                                              width: double.infinity,
                                              child: FilledButton.icon(
                                                  onPressed: onSignIn,
                                                  icon: const Icon(
                                                      Icons.login_rounded),
                                                  label: const Text(
                                                      'Continue with Google')))
                                        ] else if (session.status ==
                                            SessionStatus.accessDenied) ...[
                                          const SizedBox(height: 20),
                                          TextButton(
                                              onPressed: onSignOut,
                                              child: const Text(
                                                  'Use a different account'))
                                        ],
                                      ])))))))));

  String get _message => switch (session.status) {
        SessionStatus.loading => 'Preparing your library...',
        SessionStatus.signedOut =>
          'Sign in to sync bookmarks and reading progress.',
        SessionStatus.backendMissing =>
          'Backend not configured. See docs/SETUP.md.',
        SessionStatus.accessDenied =>
          'This account does not have production access.',
        SessionStatus.error => 'Sign in failed. Try again.',
        SessionStatus.ready => '',
      };
}
