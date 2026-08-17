import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        return _AppLayer(
          session: session,
          app: child ?? const SizedBox.expand(),
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
 * APP LAYER
 * ========================================================= */

class _AppLayer extends StatefulWidget {
  const _AppLayer({
    required this.session,
    required this.app,
    required this.onSignIn,
    required this.onSignOut,
  });

  final AppSession session;
  final Widget app;

  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  @override
  State<_AppLayer> createState() =>
      _AppLayerState();
}

class _AppLayerState extends State<_AppLayer> {
  bool _splashMounted = true;
  bool _splashVisible = true;

  bool _exitScheduled = false;

  Timer? _exitTimer;

  late final DateTime _startedAt;

  static const Duration _minimumSplashDuration =
      Duration(
    milliseconds: 700,
  );

  static const Duration _splashFadeDuration =
      Duration(
    milliseconds: 420,
  );

  @override
  void initState() {
    super.initState();

    _startedAt = DateTime.now();

    WidgetsBinding.instance.addPostFrameCallback(
      (_) {
        if (!mounted) {
          return;
        }

        if (widget.session.status ==
            SessionStatus.ready) {
          _scheduleSplashExit();
        }
      },
    );
  }

  @override
  void didUpdateWidget(
    covariant _AppLayer oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.session.status !=
            SessionStatus.ready &&
        widget.session.status ==
            SessionStatus.ready) {
      _scheduleSplashExit();
    }
  }

  void _scheduleSplashExit() {
    if (_exitScheduled ||
        !_splashMounted) {
      return;
    }

    _exitScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback(
      (_) {
        if (!mounted) {
          return;
        }

        final elapsed =
            DateTime.now().difference(
          _startedAt,
        );

        final remaining =
            _minimumSplashDuration -
                elapsed;

        if (remaining > Duration.zero) {
          _exitTimer = Timer(
            remaining,
            _startSplashFade,
          );
        } else {
          _startSplashFade();
        }
      },
    );
  }

  void _startSplashFade() {
    if (!mounted ||
        !_splashMounted ||
        !_splashVisible) {
      return;
    }

    setState(() {
      _splashVisible = false;
    });
  }

  void _handleSplashFadeFinished() {
    if (!mounted ||
        _splashVisible) {
      return;
    }

    setState(() {
      _splashMounted = false;
    });
  }

  @override
  void dispose() {
    _exitTimer?.cancel();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final status =
        widget.session.status;

    final Widget content;

    if (status ==
            SessionStatus.ready ||
        status ==
            SessionStatus.loading) {
      content = widget.app;
    } else {
      content = _AccessGate(
        session: widget.session,
        onSignIn: widget.onSignIn,
        onSignOut: widget.onSignOut,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        content,

        if (_splashMounted)
          Positioned.fill(
            child: IgnorePointer(
              ignoring:
                  !_splashVisible,

              child: AnimatedOpacity(
                opacity:
                    _splashVisible
                        ? 1.0
                        : 0.0,

                duration:
                    _splashFadeDuration,

                curve:
                    Curves.easeOutCubic,

                onEnd:
                    _handleSplashFadeFinished,

                child:
                    const _TsukiSplash(),
              ),
            ),
          ),
      ],
    );
  }
}

/* ===========================================================
 * TSUKI SPLASH
 * ========================================================= */

class _TsukiSplash extends StatefulWidget {
  const _TsukiSplash();

  @override
  State<_TsukiSplash> createState() =>
      _TsukiSplashState();
}

class _TsukiSplashState
    extends State<_TsukiSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController
      _controller;

  late final Animation<double>
      _textOpacity;

  late final Animation<Offset>
      _textPosition;

  @override
  void initState() {
    super.initState();

    _controller =
        AnimationController(
      vsync: this,
      duration:
          const Duration(
        milliseconds: 480,
      ),
    );

    /*
     * The logo is deliberately NOT animated.
     *
     * Android already shows the same logo first.
     * Flutter immediately takes over with the logo
     * in the same position so it feels continuous.
     */

    _textOpacity =
        CurvedAnimation(
      parent:
          _controller,

      curve:
          const Interval(
        0.15,
        1.0,
        curve:
            Curves.easeOutCubic,
      ),
    );

    /*
     * Very tiny upward movement for the wordmark.
     */
    _textPosition =
        Tween<Offset>(
      begin:
          const Offset(
        0,
        0.07,
      ),

      end:
          Offset.zero,
    ).animate(
      CurvedAnimation(
        parent:
            _controller,

        curve:
            const Interval(
          0.15,
          1.0,
          curve:
              Curves.easeOutCubic,
        ),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return ColoredBox(
      color:
          AppColors.background,

      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize:
                MainAxisSize.min,

            children: [
              /*
               * Logo is already visible immediately.
               *
               * This makes the Android -> Flutter
               * transition look like the same screen.
               */
              Image.asset(
                'assets/branding/quiet_reader_icon.png',

                width:
                    104,

                height:
                    104,

                fit:
                    BoxFit.contain,
              ),

              const SizedBox(
                height:
                    18,
              ),

              FadeTransition(
                opacity:
                    _textOpacity,

                child:
                    SlideTransition(
                  position:
                      _textPosition,

                  child:
                      Text(
                    'Tsuki',

                    style:
                        Theme.of(
                      context,
                    )
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              color:
                                  AppColors.text,

                              fontWeight:
                                  FontWeight.w700,

                              letterSpacing:
                                  1.6,
                            ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
      body:
          DecoratedBox(
        decoration:
            const BoxDecoration(
          gradient:
              LinearGradient(
            begin:
                Alignment.topLeft,

            end:
                Alignment.bottomRight,

            colors:
                [
              AppColors.background,

              Color(
                0xFF12111C,
              ),

              AppColors.background,
            ],
          ),
        ),

        child:
            SafeArea(
          child:
              Center(
            child:
                Padding(
              padding:
                  const EdgeInsets.all(
                24,
              ),

              child:
                  ConstrainedBox(
                constraints:
                    const BoxConstraints(
                  maxWidth:
                      420,
                ),

                child:
                    Card(
                  child:
                      Padding(
                    padding:
                        const EdgeInsets.fromLTRB(
                      24,
                      28,
                      24,
                      24,
                    ),

                    child:
                        Column(
                      mainAxisSize:
                          MainAxisSize.min,

                      children: [
                        Image.asset(
                          'assets/branding/quiet_reader_icon.png',

                          width:
                              76,

                          height:
                              76,

                          fit:
                              BoxFit.contain,
                        ),

                        const SizedBox(
                          height:
                              22,
                        ),

                        Text(
                          'Tsuki',

                          style:
                              Theme.of(
                            context,
                          )
                                  .textTheme
                                  .headlineLarge,
                        ),

                        const SizedBox(
                          height:
                              10,
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
                                        AppColors.muted,
                                  ),
                        ),

                        if (session.status ==
                                SessionStatus.signedOut ||
                            session.status ==
                                SessionStatus.error) ...[
                          const SizedBox(
                            height:
                                28,
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
                                Icons.login_rounded,
                              ),

                              label:
                                  const Text(
                                'Continue with Google',
                              ),
                            ),
                          ),
                        ] else if (session.status ==
                            SessionStatus.accessDenied) ...[
                          const SizedBox(
                            height:
                                20,
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
          'Sign in to sync bookmarks and reading progress.',

        SessionStatus.backendMissing =>
          'Backend not configured. See docs/SETUP.md.',

        SessionStatus.accessDenied =>
          'This account does not have production access.',

        SessionStatus.error =>
          'Sign in failed. Try again.',

        SessionStatus.ready =>
          '',
      };
}