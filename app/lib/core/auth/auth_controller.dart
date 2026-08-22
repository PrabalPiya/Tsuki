import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../storage/user_store.dart';

enum SessionStatus {
  loading,
  authenticating,
  ready,
  signedOut,
  accessDenied,
  backendMissing,
  error,
}

class AppSession {
  const AppSession(
    this.status, {
    this.uid,
    this.username,
    this.message,
    this.isLocalProfile = false,
  });
  final SessionStatus status;
  final String? uid;
  final String? username;
  final String? message;
  final bool isLocalProfile;
}

class AuthController extends StateNotifier<AppSession> {
  AuthController(this._config)
    : super(const AppSession(SessionStatus.loading)) {
    _start();
  }
  final AppConfig _config;
  StreamSubscription<User?>? _subscription;
  Timer? _loadingFallback;
  static const _authTimeout = Duration(seconds: 12);
  static const _profileTimeout = Duration(seconds: 4);

  Future<void> _start() async {
    if (!_config.isFirebaseConfigured) {
      state = const AppSession(
        SessionStatus.backendMissing,
        message: 'Remote accounts are not configured.',
      );
      return;
    }
    _subscription = FirebaseAuth.instance.authStateChanges().listen(
      _handleUser,
    );
    _startLoadingFallback();
  }

  void _startLoadingFallback() {
    _loadingFallback?.cancel();
    _loadingFallback = Timer(_profileTimeout, () {
      if (!mounted || state.status != SessionStatus.loading) return;
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        state = const AppSession(SessionStatus.signedOut);
      } else {
        unawaited(_handleUser(user));
      }
    });
  }

  Future<void> _handleUser(User? user) async {
    _loadingFallback?.cancel();
    if (user == null) {
      state = const AppSession(SessionStatus.signedOut);
      return;
    }

    final fallbackUsername = user.email?.split('@').first;
    state = AppSession(
      SessionStatus.ready,
      uid: user.uid,
      username: fallbackUsername,
    );

    try {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get()
          .timeout(_profileTimeout);
      final username = profile.data()?['username'] as String?;
      if (!mounted || state.uid != user.uid || username == null) return;
      state = AppSession(
        SessionStatus.ready,
        uid: user.uid,
        username: username,
      );
    } catch (_) {
      // Profile enrichment is optional; authentication already succeeded.
    }
  }

  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    if (!_config.isFirebaseConfigured) {
      state = const AppSession(
        SessionStatus.backendMissing,
        message: 'Remote accounts are not configured.',
      );
      return;
    }

    final normalized = _normalizeUsername(username);
    if (normalized == null) {
      state = const AppSession(
        SessionStatus.error,
        message: 'Enter a valid username.',
      );
      return;
    }

    try {
      state = const AppSession(SessionStatus.authenticating);
      _startLoadingFallback();
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(
            email: _emailForUsername(normalized),
            password: password,
          )
          .timeout(_authTimeout);
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        _loadingFallback?.cancel();
        state = AppSession(
          SessionStatus.ready,
          uid: user.uid,
          username: normalized,
        );
        unawaited(_handleUser(user));
      }
    } on TimeoutException {
      _loadingFallback?.cancel();
      state = const AppSession(
        SessionStatus.error,
        message: 'Login is taking too long. Check your connection and retry.',
      );
    } on FirebaseAuthException catch (error) {
      _loadingFallback?.cancel();
      state = AppSession(SessionStatus.error, message: _signInMessage(error));
    } catch (_) {
      _loadingFallback?.cancel();
      state = const AppSession(
        SessionStatus.error,
        message: 'Login failed. Try again.',
      );
    }
  }

  Future<void> register({
    required String username,
    required String password,
  }) async {
    if (!_config.isFirebaseConfigured) {
      state = const AppSession(
        SessionStatus.backendMissing,
        message: 'Remote accounts are not configured.',
      );
      return;
    }

    final normalized = _normalizeUsername(username);
    if (normalized == null) {
      state = const AppSession(
        SessionStatus.error,
        message: 'Use 3-20 letters, numbers, or underscores.',
      );
      return;
    }
    if (password.length < 6) {
      state = const AppSession(
        SessionStatus.error,
        message: 'Password must be at least 6 characters.',
      );
      return;
    }

    try {
      state = const AppSession(SessionStatus.authenticating);
      _startLoadingFallback();
      final db = FirebaseFirestore.instance;
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
            email: _emailForUsername(normalized),
            password: password,
          )
          .timeout(_authTimeout);

      final uid = credential.user!.uid;
      _loadingFallback?.cancel();
      state = AppSession(SessionStatus.ready, uid: uid, username: normalized);
      unawaited(
        Future.wait([
          db.collection('usernames').doc(normalized).set({
            'uid': uid,
            'username': normalized,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)),
          db.collection('users').doc(uid).set({
            'username': normalized,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true)),
        ]).then<void>((_) {}, onError: (_, _) {}),
      );
    } on TimeoutException {
      _loadingFallback?.cancel();
      state = const AppSession(
        SessionStatus.error,
        message:
            'Registration is taking too long. Check your connection and retry.',
      );
    } on FirebaseAuthException catch (error) {
      _loadingFallback?.cancel();
      state = AppSession(SessionStatus.error, message: _registerMessage(error));
    } catch (_) {
      _loadingFallback?.cancel();
      state = const AppSession(
        SessionStatus.error,
        message: 'Registration failed. Try again.',
      );
    }
  }

  Future<void> signOut() async {
    if (!_config.isFirebaseConfigured) return;
    await FirebaseAuth.instance.signOut();
    state = const AppSession(SessionStatus.signedOut);
  }

  Future<String?> deleteAccount() async {
    if (!_config.isFirebaseConfigured) {
      return 'Cloud account is not configured.';
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return 'Sign in again to delete this account.';
      final document = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid);
      await _deleteCollection(document.collection('bookmarks'));
      await _deleteCollection(document.collection('progress'));
      await document.delete();
      final username = state.username ?? user.email?.split('@').first;
      if (username != null && username.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('usernames')
            .doc(username)
            .delete();
      }
      await LocalUserStore().clearSession(user.uid);
      await user.delete();
      state = const AppSession(SessionStatus.signedOut);
      return null;
    } on FirebaseAuthException catch (error) {
      if (error.code == 'requires-recent-login') {
        return 'For security, log out, sign in again, then retry deletion.';
      }
      return 'Account deletion failed. Try again.';
    } catch (_) {
      return 'Account deletion failed. Try again.';
    }
  }

  String? _normalizeUsername(String value) {
    final normalized = value.trim().toLowerCase();
    final valid = RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(normalized);
    return valid ? normalized : null;
  }

  String _emailForUsername(String username) {
    return '$username@accounts.tsuki.app';
  }

  String _signInMessage(FirebaseAuthException error) {
    return switch (error.code) {
      'invalid-credential' ||
      'user-not-found' ||
      'wrong-password' => 'Username or password is incorrect.',
      'too-many-requests' => 'Too many attempts. Try again later.',
      _ => 'Login failed. Try again.',
    };
  }

  String _registerMessage(FirebaseAuthException error) {
    return switch (error.code) {
      'email-already-in-use' => 'Username is already used.',
      'weak-password' => 'Password must be at least 6 characters.',
      _ => 'Registration failed. Try again.',
    };
  }

  Future<void> _deleteCollection(
    CollectionReference<Map<String, dynamic>> collection,
  ) async {
    while (true) {
      final page = await collection.limit(400).get();
      if (page.docs.isEmpty) return;
      final batch = FirebaseFirestore.instance.batch();
      for (final document in page.docs) {
        batch.delete(document.reference);
      }
      await batch.commit();
    }
  }

  @override
  void dispose() {
    _loadingFallback?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
