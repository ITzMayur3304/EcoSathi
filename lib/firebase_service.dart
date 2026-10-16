import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';

class EcoSathiFirebaseService {
  static Future<void> initialize() async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  static FirebaseAuth get auth => FirebaseAuth.instance;
  static FirebaseFirestore get firestore => FirebaseFirestore.instance;
  static User? get currentUser => auth.currentUser;

  static Future<void> signOut() => auth.signOut();

  static Future<UserCredential> signIn(String email, String password) {
    return auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  static Future<UserCredential> register(String email, String password) {
    return auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  static Future<void> saveUserProfile(String uid, String name, String email) {
    return firestore.collection('users').doc(uid).set({
      'full_name': name,
      'email': email,
      'role': 'citizen',
      'created_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<DocumentSnapshot<Map<String, dynamic>>> getUserProfile(
    String uid,
  ) {
    return firestore.collection('users').doc(uid).get();
  }

  static Future<void> submitComplaint({
    required String userId,
    required String wasteType,
    required String address,
    required double latitude,
    required double longitude,
    required String imageUrl,
    required bool isPriority,
    String description = '',
  }) {
    final doc = firestore.collection('complaints').doc();
    return doc.set({
      'id': doc.id,
      'user_id': userId,
      'waste_type': wasteType,
      'description': description,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'image_url': imageUrl,
      'is_priority': isPriority,
      'status': 'Pending',
      'municipality': '',
      'remarks': '',
      'upvotes': 0,
      'assigned_worker': '',
      'proof_image_url': '',
      'area_type': 'residential',
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> updateComplaintStatus(
    String complaintId,
    String newStatus,
  ) {
    return firestore.collection('complaints').doc(complaintId).update({
      'status': newStatus,
    });
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> getComplaintsStream() {
    return firestore
        .collection('complaints')
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> getUserComplaintsStream(
    String userId,
  ) {
    return firestore
        .collection('complaints')
        .where('user_id', isEqualTo: userId)
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> getComplaintStream(
    String complaintId,
  ) {
    return firestore.collection('complaints').doc(complaintId).snapshots();
  }
}
