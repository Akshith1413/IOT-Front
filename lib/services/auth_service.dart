import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Stream of auth changes
  Stream<User?> get user => _auth.authStateChanges();

  // Sign in with email and password
  Future<UserCredential?> signInWithEmailAndPassword(
      String email, String password) async {
    try {
      UserCredential result = await _auth.signInWithEmailAndPassword(
          email: email, password: password);
      return result;
    } catch (e) {
      rethrow;
    }
  }

  // Register with email and password
  Future<UserCredential?> registerWithEmailAndPassword(
      String email, String password, String name) async {
    try {
      UserCredential result = await _auth.createUserWithEmailAndPassword(
          email: email, password: password);
      User? user = result.user;

      if (user != null) {
        // Create user document in Firestore
        try {
          await _firestore.collection('users').doc(user.uid).set({
            'uid': user.uid,
            'email': email,
            'name': name,
            'createdAt': FieldValue.serverTimestamp(),
          });
          
          // Update display name
          await user.updateDisplayName(name);
        } catch (e) {
          // If Firestore write fails, we should still return the user but maybe log the error
          // or throw if strict consistency is required. For now, we print it.
          print("Error writing to Firestore: $e");
          // Consider deleting the user if profile creation fails to ensure atomicity,
          // but for simple apps, just logging is often enough or UI can retry profile creation.
        }
      }
      
      return result;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'weak-password') {
        throw 'The password provided is too weak.';
      } else if (e.code == 'email-already-in-use') {
        throw 'The account already exists for that email.';
      } else if (e.code == 'invalid-email') {
        throw 'The email address is not valid.';
      }
      throw e.message ?? 'An unknown error occurred.';
    } catch (e) {
      rethrow;
    }
  }

  // Sign out
  Future<void> signOut() async {
    await _auth.signOut();
  }

  // Get current user
  User? get currentUser => _auth.currentUser;
}
