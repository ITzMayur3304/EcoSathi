# EcoSathi

EcoSathi is a Flutter-based waste management app that helps citizens report
local waste problems and helps municipalities track and respond to them.
The goal is simple: make it easier to report an issue, share the exact
location, follow progress, and keep communities cleaner.

## What the app does

- Lets citizens create an account and sign in securely.
- Captures waste complaints with photos, descriptions, and location details.
- Uses maps and device location to identify the complaint area.
- Shows complaint status and reporting history.
- Provides separate citizen and municipality experiences.
- Stores user profiles and complaint data with Firebase.
- Supports notifications and image uploads for the reporting workflow.

## Built with

- Flutter and Dart
- Firebase Authentication
- Cloud Firestore
- Firebase Storage and Cloud Messaging
- Google Maps
- Geolocator
- Image Picker

## Getting started

### Requirements

- Flutter SDK compatible with Dart `3.13.2` or newer
- Android Studio or Xcode, depending on your target platform
- A Firebase project
- A Google Maps API key with restrictions configured for your app

### Install dependencies

```bash
flutter pub get
```

### Configure local API values

API values are deliberately not committed to this repository. Create your
local configuration from [.env.example](.env.example), then pass the values
to Flutter when running the app:

```bash
flutter run \
  --dart-define=FIREBASE_API_KEY=your_firebase_api_key \
  --dart-define=GOOGLE_MAPS_API_KEY=your_google_maps_api_key
```

For Android, the Maps key is read from the `GOOGLE_MAPS_API_KEY` build
environment variable. For iOS, set `GOOGLE_MAPS_API_KEY` as a local Xcode
build setting. For web, replace the local placeholder in the web build
configuration with a key restricted to your deployment domains.

Never commit API keys, Firebase service-account files, private keys, or other
credentials. Restrict client API keys by package name, signing certificate,
bundle identifier, or web referrer as appropriate.

## Run and test

Run the application:

```bash
flutter run
```

Run the test suite:

```bash
flutter test
```

Check the project for analyzer issues:

```bash
flutter analyze
```

## Project structure

```text
lib/
  main.dart                 App screens and application flow
  firebase_options.dart     Firebase configuration from build-time values
  services/                 Firebase and data-access services
android/                    Android application configuration
ios/                        iOS application configuration
web/                        Flutter web entry point
test/                       Flutter tests
```
