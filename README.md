# EcoSathi

An AI-powered waste governance platform.

## Local configuration

Client API identifiers are intentionally not committed. Provide them locally
when building:

```text
flutter run --dart-define=FIREBASE_API_KEY=... \
  --dart-define=GOOGLE_MAPS_API_KEY=...
```

For Android, `GOOGLE_MAPS_API_KEY` is read from the build environment. For
iOS, set the `GOOGLE_MAPS_API_KEY` Xcode build setting locally. Restrict the
Google Maps key by application identity or web referrer before using it.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
