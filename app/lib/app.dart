import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_controller.dart';
import 'core/state/providers.dart';
import 'core/theme/app_theme.dart';
import 'navigation/app_router.dart';

typedef _AuthSubmit = Future<void> Function({
  required String username,
  required String password,
});

class TsukiApp extends ConsumerStatefulWidget {
  const TsukiApp({super.key});

  @override
  ConsumerState<TsukiApp> createState() => _TsukiAppState();
}

class _TsukiAppState extends ConsumerState<TsukiApp> {
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authProvider);
    final router = ref.watch(routerProvider);

    ref.listen<AppSession>(authProvider, (previous, next) {
      if (previous?.status == SessionStatus.authenticating &&
          next.status == SessionStatus.ready) {
        router.go('/home');
      }
    });

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Tsuki',
      theme: AppTheme.dark,
      routerConfig: router,
      builder: (context, child) {
        final app = child ?? const SizedBox.expand();

        if (session.status == SessionStatus.ready) {
          return app;
        }

        if (session.status == SessionStatus.loading) {
          return const _SessionLoadingGate();
        }

        return Navigator(
          pages: [
            MaterialPage<void>(
              key: const ValueKey('access-gate'),
              child: _AccessGate(
                session: session,
                onSignIn: ({required username, required password}) {
                  return ref
                      .read(authProvider.notifier)
                      .signIn(username: username, password: password);
                },
                onRegister: ({required username, required password}) {
                  return ref
                      .read(authProvider.notifier)
                      .register(username: username, password: password);
                },
                onSignOut: () {
                  return ref.read(authProvider.notifier).signOut();
                },
              ),
            ),
          ],
          onDidRemovePage: (_) {},
        );
      },
    );
  }
}

class _SessionLoadingGate extends StatelessWidget {
  const _SessionLoadingGate();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.background,
              Color(0xFF12111C),
              AppColors.background,
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/branding/tsuki_logo_transparent.png',
                width: 110,
                height: 110,
                cacheWidth: 384,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 18),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthPanel extends StatelessWidget {
  const _AuthPanel({
    required this.compact,
    required this.loading,
    required this.registering,
    required this.status,
    required this.username,
    required this.password,
    required this.confirmPassword,
    required this.usernameFocus,
    required this.passwordFocus,
    required this.confirmPasswordFocus,
    required this.obscurePassword,
    required this.usernameError,
    required this.passwordError,
    required this.confirmPasswordError,
    required this.formError,
    required this.submit,
    required this.toggleObscurePassword,
    required this.toggleMode,
    required this.signOut,
  });

  final bool compact;
  final bool loading;
  final bool registering;
  final SessionStatus status;
  final TextEditingController username;
  final TextEditingController password;
  final TextEditingController confirmPassword;
  final FocusNode usernameFocus;
  final FocusNode passwordFocus;
  final FocusNode confirmPasswordFocus;
  final bool obscurePassword;
  final String? usernameError;
  final String? passwordError;
  final String? confirmPasswordError;
  final String? formError;
  final Future<void> Function() submit;
  final VoidCallback toggleObscurePassword;
  final VoidCallback toggleMode;
  final Future<void> Function() signOut;

  @override
  Widget build(BuildContext context) {
    if (status == SessionStatus.accessDenied) {
      return _AuthUnavailable(
        icon: Icons.lock_person_rounded,
        title: 'This account cannot be used',
        message: 'Sign in with another account to continue.',
        action: OutlinedButton.icon(
          onPressed: signOut,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Use another account'),
        ),
      );
    }
    if (status == SessionStatus.backendMissing) {
      return const _AuthUnavailable(
        icon: Icons.cloud_off_rounded,
        title: 'Accounts are unavailable',
        message: 'The account service has not been configured for this build.',
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment<bool>(
              value: false,
              icon: Icon(Icons.login_rounded, size: 18),
              label: Text('Log in'),
            ),
            ButtonSegment<bool>(
              value: true,
              icon: Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: Text('Register'),
            ),
          ],
          selected: {registering},
          showSelectedIcon: false,
          onSelectionChanged: loading ? null : (_) => toggleMode(),
        ),
        SizedBox(height: compact ? 22 : 30),
        Text(
          registering ? 'Create your account' : 'Welcome back',
          style: TextStyle(
            color: AppColors.text,
            fontSize: compact ? 24 : 28,
            height: 1.15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          registering
              ? 'Keep your library and reading progress in sync.'
              : 'Continue where you left off.',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: AppColors.muted),
        ),
        SizedBox(height: compact ? 20 : 26),
        AutofillGroup(
          child: Column(
            children: [
              _AuthTextField(
                label: 'Username',
                hint: 'Your username',
                icon: Icons.person_rounded,
                controller: username,
                focusNode: usernameFocus,
                enabled: !loading,
                textInputAction: TextInputAction.next,
                autofillHints: [
                  registering
                      ? AutofillHints.newUsername
                      : AutofillHints.username,
                ],
                errorText: usernameError,
                supportingText: registering
                    ? '3-20 letters, numbers, or underscores'
                    : null,
                onSubmitted: (_) => passwordFocus.requestFocus(),
              ),
              const SizedBox(height: 12),
              _AuthTextField(
                label: 'Password',
                hint: registering ? 'At least 6 characters' : 'Your password',
                icon: Icons.lock_rounded,
                controller: password,
                focusNode: passwordFocus,
                enabled: !loading,
                obscureText: obscurePassword,
                textInputAction: registering
                    ? TextInputAction.next
                    : TextInputAction.done,
                autofillHints: [
                  registering
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                errorText: passwordError,
                suffix: IconButton(
                  onPressed: loading ? null : toggleObscurePassword,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: AppColors.muted,
                  ),
                  icon: Icon(
                    obscurePassword
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                  tooltip: obscurePassword ? 'Show password' : 'Hide password',
                ),
                onSubmitted: (_) => registering
                    ? confirmPasswordFocus.requestFocus()
                    : loading
                    ? null
                    : submit(),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: registering
                    ? Padding(
                        key: const ValueKey('confirm-password'),
                        padding: const EdgeInsets.only(top: 12),
                        child: _AuthTextField(
                          label: 'Confirm password',
                          hint: 'Enter your password again',
                          icon: Icons.verified_user_rounded,
                          controller: confirmPassword,
                          focusNode: confirmPasswordFocus,
                          enabled: !loading,
                          obscureText: obscurePassword,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.newPassword],
                          errorText: confirmPasswordError,
                          onSubmitted: (_) => loading ? null : submit(),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: formError == null
              ? const SizedBox(key: ValueKey('no-form-error'))
              : Container(
                  key: ValueKey(formError),
                  margin: const EdgeInsets.only(top: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.danger.withValues(alpha: .36),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        size: 18,
                        color: AppColors.danger,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          formError!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppColors.text,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        SizedBox(height: formError == null ? 20 : 14),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: loading ? null : submit,
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    registering
                        ? Icons.arrow_forward_rounded
                        : Icons.login_rounded,
                  ),
            label: Text(
              loading
                  ? registering
                        ? 'Creating account...'
                        : 'Signing in...'
                  : registering
                  ? 'Create account'
                  : 'Log in',
            ),
          ),
        ),
      ],
    );
  }
}

class _AuthUnavailable extends StatelessWidget {
  const _AuthUnavailable({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 34, color: AppColors.accentWarm),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 7),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: AppColors.muted),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}

class _AuthTextField extends StatelessWidget {
  const _AuthTextField({
    required this.label,
    required this.hint,
    required this.icon,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.textInputAction,
    required this.autofillHints,
    required this.errorText,
    required this.onSubmitted,
    this.supportingText,
    this.obscureText = false,
    this.suffix,
  });

  final String label;
  final String hint;
  final IconData icon;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final TextInputAction textInputAction;
  final Iterable<String> autofillHints;
  final String? errorText;
  final ValueChanged<String> onSubmitted;
  final String? supportingText;
  final bool obscureText;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    final borderColor = hasError
        ? AppColors.danger
        : AppColors.outline.withValues(alpha: .72);
    final focusedBorderColor = hasError ? AppColors.danger : AppColors.accent;

    OutlineInputBorder border(Color color, double width) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: AppColors.text, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 7),
        TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          obscureText: obscureText,
          textInputAction: textInputAction,
          autofillHints: autofillHints,
          autocorrect: false,
          enableSuggestions: !obscureText,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: AppColors.raised.withValues(alpha: .72),
            prefixIcon: Icon(icon, size: 19),
            suffixIcon: suffix,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 16,
            ),
            border: border(borderColor, 1),
            enabledBorder: border(borderColor, 1),
            focusedBorder: border(focusedBorderColor, 1.5),
            disabledBorder: border(AppColors.outline, 1),
            errorBorder: border(AppColors.danger, 1.2),
            focusedErrorBorder: border(AppColors.danger, 1.5),
          ),
          onSubmitted: onSubmitted,
        ),
        SizedBox(
          height: errorText != null || supportingText != null ? 20 : 0,
          child: Padding(
            padding: const EdgeInsets.only(left: 2, top: 5),
            child: Align(
              alignment: Alignment.topLeft,
              child: Text(
                errorText ?? supportingText ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasError ? AppColors.danger : AppColors.muted,
                  fontSize: 11,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/* ===========================================================
 * AUTH / ACCESS SCREEN
 * ========================================================= */

class _AccessGate extends StatefulWidget {
  const _AccessGate({
    required this.session,
    required this.onSignIn,
    required this.onRegister,
    required this.onSignOut,
  });

  final AppSession session;
  final _AuthSubmit onSignIn;
  final _AuthSubmit onRegister;
  final Future<void> Function() onSignOut;

  @override
  State<_AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<_AccessGate> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmPasswordFocus = FocusNode();
  String? _hiddenUsernameErrorMessage;
  String? _hiddenPasswordErrorMessage;
  String? _localUsernameError;
  String? _localPasswordError;
  String? _localConfirmPasswordError;
  bool _registering = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _username.addListener(_hideUsernameErrorAfterEdit);
    _password.addListener(_hidePasswordErrorAfterEdit);
    _confirmPassword.addListener(_clearConfirmPasswordError);
  }

  @override
  void dispose() {
    _username.removeListener(_hideUsernameErrorAfterEdit);
    _password.removeListener(_hidePasswordErrorAfterEdit);
    _confirmPassword.removeListener(_clearConfirmPasswordError);
    _username.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _confirmPasswordFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AccessGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.message != widget.session.message) {
      _hiddenUsernameErrorMessage = null;
      _hiddenPasswordErrorMessage = null;
    }
  }

  void _hideUsernameErrorAfterEdit() {
    if (_localUsernameError != null) {
      setState(() => _localUsernameError = null);
    }
    final message = widget.session.message;
    if (message == null || _hiddenUsernameErrorMessage == message) return;
    if (_usernameErrorMessage(message) == null) return;
    setState(() {
      _hiddenUsernameErrorMessage = message;
    });
  }

  void _hidePasswordErrorAfterEdit() {
    if (_localPasswordError != null) {
      setState(() => _localPasswordError = null);
    }
    final message = widget.session.message;
    if (message == null || _hiddenPasswordErrorMessage == message) return;
    if (_passwordErrorMessage(message) == null) return;
    setState(() {
      _hiddenPasswordErrorMessage = message;
    });
  }

  void _clearConfirmPasswordError() {
    if (_localConfirmPasswordError == null) return;
    setState(() => _localConfirmPasswordError = null);
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text;
    final validUsername = RegExp(r'^[a-zA-Z0-9_]{3,20}$').hasMatch(username);
    final usernameError = validUsername
        ? null
        : 'Use 3-20 letters, numbers, or underscores.';
    final passwordError = password.isEmpty
        ? 'Enter your password.'
        : _registering && password.length < 6
        ? 'Use at least 6 characters.'
        : null;
    final confirmPasswordError =
        _registering && _confirmPassword.text != password
        ? 'Passwords do not match.'
        : null;

    setState(() {
      _localUsernameError = usernameError;
      _localPasswordError = passwordError;
      _localConfirmPasswordError = confirmPasswordError;
      _hiddenUsernameErrorMessage = null;
      _hiddenPasswordErrorMessage = null;
    });

    if (usernameError != null ||
        passwordError != null ||
        confirmPasswordError != null) {
      if (usernameError != null) {
        _usernameFocus.requestFocus();
      } else if (passwordError != null) {
        _passwordFocus.requestFocus();
      } else {
        _confirmPasswordFocus.requestFocus();
      }
      return;
    }

    _usernameFocus.unfocus();
    _passwordFocus.unfocus();
    _confirmPasswordFocus.unfocus();

    if (_registering) {
      await widget.onRegister(username: username, password: password);
    } else {
      await widget.onSignIn(username: username, password: password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final loading = session.status == SessionStatus.authenticating;
    final usernameError = _localUsernameError ?? _usernameError(session);
    final passwordError = _localPasswordError ?? _passwordError(session);
    final confirmPasswordError = _localConfirmPasswordError;
    final formError = _formError(session);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: ColoredBox(
        color: AppColors.background,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 700;
              final logoSize = compact ? 64.0 : 82.0;
              final horizontalPadding = compact ? 16.0 : 24.0;
              const cardMaxWidth = 440.0;

              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  compact ? 14 : 28,
                  horizontalPadding,
                  24 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - (compact ? 28 : 56),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: cardMaxWidth),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Image.asset(
                                'assets/branding/tsuki_logo_transparent.png',
                                width: logoSize,
                                height: logoSize,
                                cacheWidth: 384,
                                fit: BoxFit.contain,
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Tsuki',
                                    style: TextStyle(
                                      color: AppColors.text,
                                      fontSize: compact ? 27 : 31,
                                      fontWeight: FontWeight.w800,
                                      height: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    'MANGA READER',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: AppColors.accentWarm,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SizedBox(height: compact ? 18 : 26),
                          Container(
                            width: double.infinity,
                            padding: EdgeInsets.all(compact ? 20 : 26),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.outline),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x52000000),
                                  blurRadius: 28,
                                  offset: Offset(0, 16),
                                ),
                              ],
                            ),
                            child: _AuthPanel(
                              compact: compact,
                              loading: loading,
                              registering: _registering,
                              status: session.status,
                              username: _username,
                              password: _password,
                              confirmPassword: _confirmPassword,
                              usernameFocus: _usernameFocus,
                              passwordFocus: _passwordFocus,
                              confirmPasswordFocus: _confirmPasswordFocus,
                              obscurePassword: _obscurePassword,
                              usernameError: usernameError,
                              passwordError: passwordError,
                              confirmPasswordError: confirmPasswordError,
                              formError: formError,
                              submit: _submit,
                              toggleObscurePassword: () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                              toggleMode: () {
                                setState(() {
                                  final message = widget.session.message;
                                  _registering = !_registering;
                                  _localUsernameError = null;
                                  _localPasswordError = null;
                                  _localConfirmPasswordError = null;
                                  _confirmPassword.clear();
                                  _usernameFocus.unfocus();
                                  _passwordFocus.unfocus();
                                  _confirmPasswordFocus.unfocus();
                                  _hiddenUsernameErrorMessage = message;
                                  _hiddenPasswordErrorMessage = message;
                                });
                              },
                              signOut: widget.onSignOut,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String? _usernameError(AppSession session) {
    final message = session.message ?? '';
    if (_hiddenUsernameErrorMessage == message) return null;
    if (!_registering && message.contains('Username is already used')) {
      return null;
    }
    return _usernameErrorMessage(message);
  }

  String? _passwordError(AppSession session) {
    final message = session.message ?? '';
    if (_hiddenPasswordErrorMessage == message) return null;
    return _passwordErrorMessage(message);
  }

  String? _usernameErrorMessage(String message) {
    if (message.contains('Username is already used')) {
      return 'Username is already used';
    }
    if (message.contains('valid username') ||
        message.contains('letters, numbers, or underscores')) {
      return message;
    }
    if (message.contains('Username or password')) {
      return 'Check username';
    }
    return null;
  }

  String? _passwordErrorMessage(String message) {
    if (message.contains('Password must')) return message;
    if (message.contains('Username or password')) return 'Check password';
    return null;
  }

  String? _formError(AppSession session) {
    final message = session.message;
    if (message == null || message.isEmpty) return null;
    if (!_registering && message.contains('Username is already used')) {
      return null;
    }
    if (_hiddenUsernameErrorMessage == message ||
        _hiddenPasswordErrorMessage == message) {
      return null;
    }
    if (_usernameError(session) != null || _passwordError(session) != null) {
      return null;
    }
    if (session.status == SessionStatus.error ||
        session.status == SessionStatus.backendMissing ||
        session.status == SessionStatus.accessDenied) {
      return message;
    }
    return null;
  }
}
