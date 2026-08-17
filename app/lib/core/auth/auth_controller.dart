import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config/app_config.dart';
import '../storage/user_store.dart';

enum SessionStatus {
  loading,
  ready,
  signedOut,
  accessDenied,
  backendMissing,
  error
}

class AppSession {
  const AppSession(this.status,
      {this.uid, this.message, this.isLocalProfile = false});
  final SessionStatus status;
  final String? uid;
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
  Future<void> _start() async {
    if (!_config.isFirebaseConfigured) {
      state = const AppSession(SessionStatus.ready,
          uid: 'local-user', isLocalProfile: true);
      return;
    }
    _subscription =
        FirebaseAuth.instance.authStateChanges().listen(_handleUser);
  }

  Future<void> _handleUser(User? user) async {
    if (user == null) {
      state = const AppSession(SessionStatus.signedOut);
      return;
    }
    final claims =
        (await user.getIdTokenResult(true)).claims ?? const <String, dynamic>{};
    final allowed = _config.environment != AppEnvironment.production ||
        claims['appAccess'] == true;
    state = allowed
        ? AppSession(SessionStatus.ready, uid: user.uid)
        : const AppSession(SessionStatus.accessDenied,
            message: 'This account is not authorized for this backend.');
  }

  Future<void> signIn() async {
    if (!_config.isFirebaseConfigured) return;
    try {
      final google = await GoogleSignIn(
              serverClientId: _config.googleOAuthServerClientId.isEmpty
                  ? null
                  : _config.googleOAuthServerClientId)
          .signIn();
      if (google == null) return;
      final auth = await google.authentication;
      await FirebaseAuth.instance.signInWithCredential(
          GoogleAuthProvider.credential(
              accessToken: auth.accessToken, idToken: auth.idToken));
    } catch (_) {
      state = const AppSession(SessionStatus.error,
          message: 'Sign in failed. Try again.');
    }
  }

  Future<void> signOut() async {
    if (!_config.isFirebaseConfigured) return;
    await Future.wait(
        [FirebaseAuth.instance.signOut(), GoogleSignIn().signOut()]);
    state = const AppSession(SessionStatus.signedOut);
  }

  Future<String?> deleteAccount() async {
    if (!_config.isFirebaseConfigured) {
      return 'Cloud account is not configured.';
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return 'Sign in again to delete this account.';
      final document =
          FirebaseFirestore.instance.collection('users').doc(user.uid);
      await _deleteCollection(document.collection('bookmarks'));
      await _deleteCollection(document.collection('progress'));
      await document.delete();
      await const LocalUserStore().clearSession(user.uid);
      await user.delete();
      await GoogleSignIn().signOut();
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

  Future<void> _deleteCollection(
      CollectionReference<Map<String, dynamic>> collection) async {
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
    _subscription?.cancel();
    super.dispose();
  }
}
