import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'core/auth/auth_controller.dart';
import 'core/state/providers.dart';
import 'core/theme/app_theme.dart';
import 'navigation/app_router.dart';

class TsukiApp extends ConsumerWidget {
  const TsukiApp({
    super.key,
  });

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) {
    final session = ref.watch(authProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Tsuki',
      theme: AppTheme.dark,
      routerConfig: router,
      builder: (
        context,
        child,
      ) {
        final app =
            child ?? const SizedBox.expand();

        if (session.status ==
                SessionStatus.ready ||
            session.status ==
                SessionStatus.loading) {
          return app;
        }

        return _AccessGate(
          session: session,
          onSignIn: () {
            ref
                .read(authProvider.notifier)
                .signIn();
          },
          onSignOut: () {
            ref
                .read(authProvider.notifier)
                .signOut();
          },
        );
      },
    );
  }
}

/* ===========================================================
 * AUTH / ACCESS SCREEN
 * ========================================================= */

class _AccessGate extends StatelessWidget {
  const _AccessGate({
    required this.session,
    required this.onSignIn,
    required this.onSignOut,
  });

  final AppSession session;

  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      body: DecoratedBox(
        decoration:
            const BoxDecoration(
          gradient:
              LinearGradient(
            begin:
                Alignment.topLeft,
            end:
                Alignment.bottomRight,
            colors: [
              AppColors.background,
              Color(
                0xFF12111C,
              ),
              AppColors.background,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding:
                  const EdgeInsets.all(
                24,
              ),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(
                  maxWidth: 420,
                ),
                child: Card(
                  child: Padding(
                    padding:
                        const EdgeInsets.fromLTRB(
                      24,
                      28,
                      24,
                      24,
                    ),
                    child: Column(
                      mainAxisSize:
                          MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/branding/tsuki_logo_transparent.png',
                          width: 125,
                          height: 125,
                          fit:
                              BoxFit.contain,
                        ),

                        const SizedBox(
                          height: 3,
                        ),

                        Text(
                          'Tsuki',
                          style: GoogleFonts.sora(
                            color: AppColors.text,
                            fontSize: 35,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.7,
                            height: 1,
                          ),
                        ),

                        const SizedBox(
                          height: 10,
                        ),

                        Text(
                          session.message ??
                              _message,
                          textAlign:
                              TextAlign.center,
                          style:
                              Theme.of(
                            context,
                          )
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color:
                                        AppColors
                                            .muted,
                                  ),
                        ),

                        if (session.status ==
                                SessionStatus
                                    .signedOut ||
                            session.status ==
                                SessionStatus
                                    .error) ...[
                          const SizedBox(
                            height: 28,
                          ),

                          SizedBox(
                            width:
                                double.infinity,
                            child:
                                FilledButton.icon(
                              onPressed:
                                  onSignIn,
                              icon:
                                  const Icon(
                                Icons
                                    .login_rounded,
                              ),
                              label:
                                  const Text(
                                'Continue with Google',
                              ),
                            ),
                          ),
                        ] else if (session
                                .status ==
                            SessionStatus
                                .accessDenied) ...[
                          const SizedBox(
                            height: 20,
                          ),

                          TextButton(
                            onPressed:
                                onSignOut,
                            child:
                                const Text(
                              'Use a different account',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _message =>
      switch (session.status) {
        SessionStatus.loading =>
          '',

        SessionStatus.signedOut =>
          'Sign in to start reading.',

        SessionStatus.backendMissing =>
          'Backend not configured.',

        SessionStatus.accessDenied =>
          'Access Denied.',

        SessionStatus.error =>
          'Sign in failed. Try again.',

        SessionStatus.ready =>
          '',
      };
}