//a reusable authentication service class
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  String _cleanEmail(String email) => email.trim().toLowerCase();

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Future<bool> signIn(String email, String password) async {
    final cleanedEmail = _cleanEmail(email);

    final rawPassword = password;

    if (cleanedEmail.isEmpty || rawPassword.isEmpty) {
      debugPrint("LOGIN ERROR: missing email or password");
      return false;
    }

    try {
      await _auth.signInWithEmailAndPassword(
        email: cleanedEmail,
        password: rawPassword,
      );
      return true;
    } on FirebaseAuthException catch (e) {
      debugPrint("LOGIN ERROR: ${e.code} - ${e.message}");
      return false;
    } catch (e) {
      debugPrint("UNKNOWN LOGIN ERROR: $e");
      return false;
    }
  }

  Future<void> sendPasswordResetSecure(String email) async {
    final cleanedEmail = _cleanEmail(email);

    if (cleanedEmail.isEmpty) {
      throw FirebaseAuthException(code: "missing-email");
    }

    try {
      await _auth.sendPasswordResetEmail(email: cleanedEmail);
      debugPrint("RESET: request sent (Firebase accepted request).");
    } on FirebaseAuthException catch (e) {
      debugPrint("RESET ERROR: ${e.code} - ${e.message}");

      if (e.code == "network-request-failed" ||
          e.code == "too-many-requests" ||
          e.code == "internal-error") {
        throw e;
      }

      return;
    } catch (e) {
      debugPrint("UNKNOWN RESET ERROR: $e");
      throw FirebaseAuthException(code: "unknown");
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }
}