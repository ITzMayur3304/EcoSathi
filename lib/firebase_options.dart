import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
    if (apiKey.isEmpty) {
      throw StateError(
        'FIREBASE_API_KEY is required. Pass it with --dart-define.',
      );
    }
    return const FirebaseOptions(
      apiKey: apiKey,
      appId: '1:135238273588:android:f8c7a8646892ccc89f1861',
      messagingSenderId: '135238273588',
      projectId: 'ecosathi-3baf0',
      storageBucket: 'ecosathi-3baf0.firebasestorage.app',
    );
  }
}
