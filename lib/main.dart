import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'services/firebase_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const Color kPrimary = Color(0xFF00B83F);
const Color kPrimaryDark = Color(0xFF006B2D);
const Color kSurface = Color(0xFFF5F9F6);
const Color kCardBorder = Color(0xFFD1E8D5);
const Color kAccentLight = Color(0xFFE8F5E9);

// ─────────────────────────────────────────────────────────────────────────────
// Utility: Reverse geocode via Nominatim
// ─────────────────────────────────────────────────────────────────────────────

Future<String> reverseGeocodeWithNominatim(Position position) async {
  final uri = Uri.parse(
    'https://nominatim.openstreetmap.org/reverse?format=jsonv2'
    '&lat=${position.latitude}&lon=${position.longitude}'
    '&zoom=18&addressdetails=1',
  );
  try {
    final response = await http.get(uri, headers: {
      'User-Agent': 'EcoSathi/1.0 (contact@ecosathi.app)',
      'Accept-Language': 'en',
    });
    if (response.statusCode != 200) return 'Current location detected';
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return 'Current location detected';
    final address = decoded['address'];
    if (address is! Map<String, dynamic>) return 'Current location detected';
    final parts = <String?>[
      address['suburb'] as String?,
      address['neighbourhood'] as String?,
      address['village'] as String?,
      address['town'] as String?,
      address['city'] as String?,
      address['state'] as String?,
      address['country'] as String?,
    ];
    final readable =
        parts.whereType<String>().where((s) => s.trim().isNotEmpty).join(', ');
    return readable.isNotEmpty ? readable : 'Current location detected';
  } catch (_) {
    return 'Current location detected';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility: Image compression & base64 encoding for Firestore
// ─────────────────────────────────────────────────────────────────────────────

/// Compresses the image, resizes via [ImagePicker] quality settings,
/// and encodes to a data-URI safe for Firestore's ~1 MiB doc limit.
/// Throws [StateError] if the encoded payload is still too large.
Future<String> imageToFirestoreBase64(XFile file) async {
  final sourceBytes = await file.readAsBytes();

  // Re-encode through Flutter's image codec at reduced quality if large
  Uint8List finalBytes = sourceBytes;
  if (sourceBytes.length > 400000) {
    // Decode → re-encode at lower quality via codec
    try {
      final codec = await ui.instantiateImageCodec(
        sourceBytes,
        targetWidth: 800,
        targetHeight: 800,
      );
      final frame = await codec.getNextFrame();
      final byteData =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        finalBytes = byteData.buffer.asUint8List();
      }
      frame.image.dispose();
      codec.dispose();
    } catch (_) {
      // Fall back to original bytes if codec fails
    }
  }

  final encoded = base64Encode(finalBytes);
  // Firestore doc limit ~1 MiB. Image + other fields must fit.
  // Allow up to ~700 KB for image payload.
  if (encoded.length > 700000) {
    throw StateError(
      'Image is too large even after compression. '
      'Please capture a smaller or lower-resolution image.',
    );
  }
  return 'data:image/jpeg;base64,$encoded';
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility: Friendly Firebase error messages
// ─────────────────────────────────────────────────────────────────────────────

String friendlyAuthError(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'This email is already registered.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'network-request-failed':
        return 'Network error. Check your internet connection.';
      default:
        return error.message ?? 'Authentication failed.';
    }
  }
  final msg = error.toString();
  if (msg.contains('network')) return 'Network error. Check your connection.';
  return msg.length > 120 ? '${msg.substring(0, 120)}…' : msg;
}

// ─────────────────────────────────────────────────────────────────────────────
// Glossy Notification System
// ─────────────────────────────────────────────────────────────────────────────

enum NotificationType { success, error, warning, info }

/// Shows a compact, glossy, non-blocking floating notification.
/// Automatically dismisses after [duration]. Does not cover the full screen.
Future<void> showAppNotification(
  BuildContext context, {
  required String title,
  required String message,
  bool isError = false,
  NotificationType type = NotificationType.success,
}) async {
  // Map legacy isError param
  final effectiveType = isError ? NotificationType.error : type;

  final overlay = Overlay.of(context);
  late final OverlayEntry entry;

  Color bgColor;
  Color borderColor;
  Color iconColor;
  IconData iconData;

  switch (effectiveType) {
    case NotificationType.success:
      bgColor = const Color(0xFFE7FFF0);
      borderColor = const Color(0xFF9BDEAD);
      iconColor = const Color(0xFF009A38);
      iconData = Icons.check_circle_outline;
    case NotificationType.error:
      bgColor = const Color(0xFFFFE8E8);
      borderColor = const Color(0xFFFFA6A6);
      iconColor = const Color(0xFFD32F2F);
      iconData = Icons.error_outline;
    case NotificationType.warning:
      bgColor = const Color(0xFFFFF8E1);
      borderColor = const Color(0xFFFFCC02);
      iconColor = const Color(0xFFF57C00);
      iconData = Icons.warning_amber_outlined;
    case NotificationType.info:
      bgColor = const Color(0xFFE3F2FD);
      borderColor = const Color(0xFF90CAF9);
      iconColor = const Color(0xFF1565C0);
      iconData = Icons.info_outline;
  }

  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      top: MediaQuery.paddingOf(ctx).top + 10,
      left: 14,
      right: 14,
      child: Material(
        color: Colors.transparent,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, -20 * (1 - value)),
              child: child,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: bgColor.withOpacity(0.88),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor, width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.10),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(iconData, color: iconColor, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: iconColor,
                            ),
                          ),
                          Text(
                            message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        if (entry.mounted) entry.remove();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child:
                            Icon(Icons.close, size: 16, color: Colors.black45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  await Future<void>.delayed(const Duration(seconds: 3));
  if (entry.mounted) entry.remove();
}

// ─────────────────────────────────────────────────────────────────────────────
// App Entry
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EcoSathiFirebaseService.initialize();
  runApp(const EcoSathiApp());
}

enum Role { citizen, municipality }

class EcoSathiApp extends StatelessWidget {
  const EcoSathiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EcoSathi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kSurface,
        primaryColor: kPrimary,
        textTheme: GoogleFonts.poppinsTextTheme(),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Colors.black87),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4CAF50),
          primary: kPrimary,
          secondary: kPrimaryDark,
          surface: kSurface,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth Gate – persists session, routes by role
// ─────────────────────────────────────────────────────────────────────────────

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: EcoSathiFirebaseService.auth.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: kPrimary)),
          );
        }
        final user = snapshot.data;
        if (user == null) return const SplashScreen();
        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: EcoSathiFirebaseService.firestore
              .collection('users')
              .doc(user.uid)
              .get(),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body:
                    Center(child: CircularProgressIndicator(color: kPrimary)),
              );
            }
            final role = profileSnapshot.data?.data()?['role'];
            return role == 'municipality'
                ? const MunicipalityDashboard()
                : const CitizenSessionHome();
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Citizen Session Home – wraps CitizenShell, shows welcome once
// ─────────────────────────────────────────────────────────────────────────────

class CitizenSessionHome extends StatefulWidget {
  const CitizenSessionHome({super.key});

  @override
  State<CitizenSessionHome> createState() => _CitizenSessionHomeState();
}

class _CitizenSessionHomeState extends State<CitizenSessionHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        showAppNotification(
          context,
          title: 'Welcome back',
          message: 'Signed in as citizen.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => const CitizenShell();
}

// ─────────────────────────────────────────────────────────────────────────────
// Citizen Shell – bottom nav with 4 tabs
// ─────────────────────────────────────────────────────────────────────────────

class CitizenShell extends StatefulWidget {
  const CitizenShell({super.key});
  @override
  State<CitizenShell> createState() => _CitizenShellState();
}

class _CitizenShellState extends State<CitizenShell> {
  int _idx = 0;

  final _pages = const [
    CitizenHomeScreen(),
    WasteInformationScreen(),
    PastReportsScreen(),
    MapScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // PopScope prevents Android back button from returning to login
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: _pages[_idx],
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 8,
                offset: Offset(0, -2),
              ),
            ],
          ),
          child: NavigationBar(
            height: 64,
            selectedIndex: _idx,
            onDestinationSelected: (i) => setState(() => _idx = i),
            backgroundColor: Colors.white,
            indicatorColor: kAccentLight,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined, size: 22),
                selectedIcon: Icon(Icons.home, color: kPrimaryDark, size: 22),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.recycling_outlined, size: 22),
                selectedIcon:
                    Icon(Icons.recycling, color: kPrimaryDark, size: 22),
                label: 'Waste',
              ),
              NavigationDestination(
                icon: Icon(Icons.assignment_outlined, size: 22),
                selectedIcon:
                    Icon(Icons.assignment, color: kPrimaryDark, size: 22),
                label: 'Reports',
              ),
              NavigationDestination(
                icon: Icon(Icons.map_outlined, size: 22),
                selectedIcon: Icon(Icons.map, color: kPrimaryDark, size: 22),
                label: 'Map',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Splash Screen – role selection
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: kAccentLight,
                      shape: BoxShape.circle,
                      border: Border.all(color: kPrimary.withOpacity(0.3)),
                    ),
                    child: const Icon(Icons.eco, size: 44, color: kPrimary),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'EcoSathi',
                    style: GoogleFonts.poppins(
                      fontSize: 32,
                      color: kPrimaryDark,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Smart Waste Management',
                    style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Colors.black54,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 48),
                  // Citizen button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const LoginScreen(role: Role.citizen),
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: kPrimary,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.person_outline, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'I am a Citizen',
                            style: GoogleFonts.poppins(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Municipality button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const LoginScreen(role: Role.municipality),
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: kPrimary, width: 1.5),
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.business_outlined,
                              color: kPrimary, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'I am Municipality',
                            style: GoogleFonts.poppins(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: kPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable: Styled Text Field
// ─────────────────────────────────────────────────────────────────────────────

Widget _styledField({
  required IconData icon,
  required String hint,
  required TextEditingController controller,
  bool obscure = false,
  Widget? suffix,
  TextInputType? keyboardType,
}) {
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 400),
    child: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFCCCCCC)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(icon, size: 20, color: kPrimary),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboardType,
              decoration: InputDecoration(
                hintText: hint,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                hintStyle:
                    const TextStyle(fontSize: 14, color: Colors.black45),
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          if (suffix != null) suffix,
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Login Screen
// ─────────────────────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.role});
  final Role role;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  bool hidePass = true;
  bool loading = false;

  @override
  void dispose() {
    emailCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCitizen = widget.role == Role.citizen;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, color: kPrimaryDark, size: 22),
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // Gradient background
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFE8FFF0),
                      kSurface,
                      const Color(0xFFEAF7FF),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: kPrimary,
                    child: Icon(
                      isCitizen ? Icons.person : Icons.account_balance,
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Login to EcoSathi',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.poppins(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: kPrimaryDark,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isCitizen
                        ? 'Sign in as citizen'
                        : 'Sign in as municipality',
                    style: GoogleFonts.poppins(
                        fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 32),
                  _styledField(
                    icon: Icons.email_outlined,
                    hint: 'Email address',
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 14),
                  _styledField(
                    icon: Icons.lock_outline,
                    hint: 'Password',
                    controller: passCtrl,
                    obscure: hidePass,
                    suffix: IconButton(
                      onPressed: () =>
                          setState(() => hidePass = !hidePass),
                      icon: Icon(
                        hidePass ? Icons.visibility : Icons.visibility_off,
                        size: 20,
                        color: kPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: loading ? null : _login,
                        style: FilledButton.styleFrom(
                          backgroundColor: kPrimary,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : Text(
                                'Login',
                                style: GoogleFonts.poppins(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (isCitizen)
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RegisterScreen(),
                        ),
                      ),
                      child: Text(
                        "Don't have an account? Register here",
                        style: GoogleFonts.poppins(
                          color: kPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _login() async {
    final email = emailCtrl.text.trim();
    final password = passCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      showAppNotification(context,
          title: 'Missing fields',
          message: 'Enter both email and password.',
          isError: true);
      return;
    }
    setState(() => loading = true);
    try {
      final cred = await EcoSathiFirebaseService.signIn(email, password);
      if (!mounted) return;

      // Verify role matches selection
      final profileDoc = await EcoSathiFirebaseService.firestore
          .collection('users')
          .doc(cred.user!.uid)
          .get();
      final role = profileDoc.data()?['role'] ?? 'citizen';

      if (widget.role == Role.municipality && role != 'municipality') {
        await EcoSathiFirebaseService.signOut();
        if (!mounted) return;
        showAppNotification(context,
            title: 'Access denied',
            message: 'This account is not a municipality user.',
            isError: true);
        return;
      }
      if (widget.role == Role.citizen && role == 'municipality') {
        await EcoSathiFirebaseService.signOut();
        if (!mounted) return;
        showAppNotification(context,
            title: 'Access denied',
            message: 'Municipality accounts should use the municipality login.',
            isError: true);
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => role == 'municipality'
              ? const MunicipalityDashboard()
              : const CitizenSessionHome(),
        ),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotification(context,
          title: 'Login failed',
          message: friendlyAuthError(e),
          isError: true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Register Screen
// ─────────────────────────────────────────────────────────────────────────────

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final nameCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();
  bool hidePass = true;
  bool hideConfirm = true;
  bool loading = false;

  @override
  void dispose() {
    nameCtrl.dispose();
    emailCtrl.dispose();
    passCtrl.dispose();
    confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, color: kPrimaryDark, size: 22),
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFE8FFF0),
                      kSurface,
                      const Color(0xFFEAF7FF),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  const CircleAvatar(
                    radius: 28,
                    backgroundColor: kPrimary,
                    child: Icon(Icons.person_add, size: 28, color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Create Account',
                    style: GoogleFonts.poppins(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: kPrimaryDark,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Register as citizen',
                    style: GoogleFonts.poppins(
                        fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 24),
                  _styledField(
                    icon: Icons.person_outline,
                    hint: 'Full name',
                    controller: nameCtrl,
                  ),
                  const SizedBox(height: 12),
                  _styledField(
                    icon: Icons.email_outlined,
                    hint: 'Email address',
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 12),
                  _styledField(
                    icon: Icons.lock_outline,
                    hint: 'Password (min 6 characters)',
                    controller: passCtrl,
                    obscure: hidePass,
                    suffix: IconButton(
                      onPressed: () =>
                          setState(() => hidePass = !hidePass),
                      icon: Icon(
                        hidePass ? Icons.visibility : Icons.visibility_off,
                        size: 20,
                        color: kPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _styledField(
                    icon: Icons.lock_outline,
                    hint: 'Confirm password',
                    controller: confirmCtrl,
                    obscure: hideConfirm,
                    suffix: IconButton(
                      onPressed: () =>
                          setState(() => hideConfirm = !hideConfirm),
                      icon: Icon(
                        hideConfirm ? Icons.visibility : Icons.visibility_off,
                        size: 20,
                        color: kPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: loading ? null : _register,
                        style: FilledButton.styleFrom(
                          backgroundColor: kPrimary,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : Text(
                                'Create Account',
                                style: GoogleFonts.poppins(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Already have an account? Login here',
                      style: GoogleFonts.poppins(
                        color: kPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _register() async {
    final name = nameCtrl.text.trim();
    final email = emailCtrl.text.trim();
    final password = passCtrl.text;
    final confirm = confirmCtrl.text;

    if (name.isEmpty || email.isEmpty) {
      showAppNotification(context,
          title: 'Missing fields',
          message: 'Please fill all fields.',
          isError: true);
      return;
    }
    if (password.length < 6) {
      showAppNotification(context,
          title: 'Weak password',
          message: 'Password must be at least 6 characters.',
          isError: true);
      return;
    }
    if (password != confirm) {
      showAppNotification(context,
          title: 'Passwords do not match',
          message: 'Re-enter your password carefully.',
          isError: true);
      return;
    }

    setState(() => loading = true);
    try {
      final cred = await EcoSathiFirebaseService.register(email, password);
      await EcoSathiFirebaseService.saveUserProfile(
          cred.user!.uid, name, email);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const CitizenSessionHome()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      showAppNotification(context,
          title: 'Registration failed',
          message: friendlyAuthError(e),
          isError: true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Citizen Home Screen
// ─────────────────────────────────────────────────────────────────────────────

class CitizenHomeScreen extends StatelessWidget {
  const CitizenHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: kAccentLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.eco, size: 20, color: kPrimary),
            ),
            const SizedBox(width: 8),
            Text(
              'EcoSathi',
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: kPrimaryDark,
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: kPrimaryDark, size: 22),
            onSelected: (value) async {
              if (value != 'logout') return;
              await EcoSathiFirebaseService.signOut();
              if (!context.mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const SplashScreen()),
                (route) => false,
              );
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 18, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Logout', style: TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFE8F8EC), Color(0xFFF8FFF9)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kCardBorder),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.eco, size: 42, color: kPrimary),
                    const SizedBox(height: 8),
                    Text(
                      'Welcome, Citizen!',
                      style: GoogleFonts.poppins(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: kPrimaryDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Help keep your neighbourhood clean',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Report complaint button
              _actionCard(
                context,
                icon: Icons.camera_alt_outlined,
                label: 'Report Complaint',
                subtitle: 'Report waste issues in your area',
                color: kPrimary,
                onTap: () async {
                  final submitted =
                      await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                        builder: (_) => const ReportComplaintScreen()),
                  );
                  if (submitted == true && context.mounted) {
                    showAppNotification(
                      context,
                      title: 'Complaint submitted',
                      message: 'Municipality can now review your report.',
                    );
                  }
                },
              ),
              const SizedBox(height: 10),

              // View map button
              _actionCard(
                context,
                icon: Icons.map_outlined,
                label: 'View Map',
                subtitle: 'View all complaints on map',
                color: kPrimaryDark,
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const MapScreen())),
              ),
              const SizedBox(height: 18),

              // Waste info section
              Text(
                'Waste Information',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: kPrimaryDark,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Separate waste correctly for a cleaner city.',
                style: GoogleFonts.poppins(
                    fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 10),
              _miniInfoCard(Icons.water_drop_outlined, 'Wet Waste',
                  'Food scraps, kitchen waste'),
              _miniInfoCard(Icons.inventory_2_outlined, 'Dry Waste',
                  'Paper, plastic, metal, glass'),
              _miniInfoCard(Icons.electrical_services_outlined, 'E-Waste',
                  'Phones, cables, batteries'),
              _miniInfoCard(Icons.warning_amber_outlined, 'Hazardous',
                  'Chemicals, sharps, damaged items'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, size: 26, color: Colors.white),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: GoogleFonts.poppins(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniInfoCard(IconData icon, String title, String subtitle) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kCardBorder),
      ),
      child: Row(
        children: [
          Icon(icon, size: 24, color: kPrimary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.poppins(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Waste Information Screen
// ─────────────────────────────────────────────────────────────────────────────

class WasteInformationScreen extends StatelessWidget {
  const WasteInformationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Waste Information',
          style: GoogleFonts.poppins(
              fontSize: 18, fontWeight: FontWeight.w700, color: kPrimaryDark),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // Intro card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFFE8FFF0), Color(0xFFF7FFFA)]),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kCardBorder),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: kPrimary,
                  child:
                      const Icon(Icons.recycling, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sort waste at source',
                          style: GoogleFonts.poppins(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(
                          'Keep wet, dry, electronic and hazardous waste separate.',
                          style: GoogleFonts.poppins(
                              fontSize: 11, color: Colors.black54)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _wasteCard(Icons.water_drop_outlined, 'Wet Waste',
              'Food scraps, peels and garden waste.', const Color(0xFF2E9D55)),
          _wasteCard(Icons.inventory_2_outlined, 'Dry Waste',
              'Paper, cardboard, plastic, metal and glass.', const Color(0xFF3977B8)),
          _wasteCard(Icons.electrical_services_outlined, 'E-Waste',
              'Phones, cables, batteries and electronics.', const Color(0xFF7A55B5)),
          _wasteCard(Icons.warning_amber_outlined, 'Hazardous Waste',
              'Chemicals, sharps and damaged containers.', const Color(0xFFC46A28)),
        ],
      ),
    );
  }

  Widget _wasteCard(
      IconData icon, String title, String desc, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.25)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withOpacity(0.12),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.poppins(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                Text(desc,
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Past Reports Screen
// ─────────────────────────────────────────────────────────────────────────────

class PastReportsScreen extends StatelessWidget {
  const PastReportsScreen({super.key});

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'resolved':
        return const Color(0xFF2E7D32);
      case 'in progress':
        return const Color(0xFFF57C00);
      case 'assigned':
        return const Color(0xFF1565C0);
      default:
        return const Color(0xFF757575);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = EcoSathiFirebaseService.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(
        title: Text('My Reports',
            style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: kPrimaryDark)),
      ),
      body: userId == null
          ? Center(
              child: Text('Please sign in to view reports.',
                  style: GoogleFonts.poppins(color: Colors.black54)))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: EcoSathiFirebaseService.firestore
                  .collection('complaints')
                  .where('user_id', isEqualTo: userId)
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 40, color: Colors.red),
                          const SizedBox(height: 8),
                          Text('Unable to load reports.',
                              style: GoogleFonts.poppins(fontSize: 14)),
                        ],
                      ),
                    ),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator(color: kPrimary));
                }
                final reports = snapshot.data?.docs ?? [];
                if (reports.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inbox_outlined,
                            size: 48, color: Colors.black26),
                        const SizedBox(height: 8),
                        Text('No reports submitted yet.',
                            style: GoogleFonts.poppins(
                                fontSize: 14, color: Colors.black45)),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: reports.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final doc = reports[index];
                    final data = doc.data();
                    final status = data['status']?.toString() ?? 'Pending';
                    final imageUrl = data['image_url']?.toString() ?? '';
                    final ts = data['timestamp'] as Timestamp?;
                    final dateStr = ts != null
                        ? '${ts.toDate().day}/${ts.toDate().month}/${ts.toDate().year}'
                        : '';

                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ReportProgressScreen(
                              reportId: doc.id),
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: kCardBorder),
                          boxShadow: const [
                            BoxShadow(
                                color: Color(0x0F000000),
                                blurRadius: 4,
                                offset: Offset(0, 2)),
                          ],
                        ),
                        child: Row(
                          children: [
                            // Image thumbnail
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 52,
                                height: 52,
                                child: imageUrl.startsWith('data:image')
                                    ? Image.memory(
                                        base64Decode(imageUrl
                                            .split(',')
                                            .last),
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            Container(
                                          color: kAccentLight,
                                          child: const Icon(
                                              Icons.image_not_supported,
                                              size: 20,
                                              color: Colors.black38),
                                        ),
                                      )
                                    : Container(
                                        color: kAccentLight,
                                        child: const Icon(
                                            Icons.image_outlined,
                                            size: 20,
                                            color: Colors.black38),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    data['waste_type']?.toString() ??
                                        'Waste report',
                                    style: GoogleFonts.poppins(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    data['address']?.toString() ??
                                        'Location unavailable',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        color: Colors.black54),
                                  ),
                                  if (dateStr.isNotEmpty)
                                    Text(dateStr,
                                        style: GoogleFonts.poppins(
                                            fontSize: 10,
                                            color: Colors.black38)),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _statusColor(status).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                status,
                                style: GoogleFonts.poppins(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _statusColor(status),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Report Progress Screen – streams live data
// ─────────────────────────────────────────────────────────────────────────────

class ReportProgressScreen extends StatelessWidget {
  const ReportProgressScreen({super.key, required this.reportId});
  final String reportId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Report Progress',
            style: GoogleFonts.poppins(
                fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: EcoSathiFirebaseService.firestore
            .collection('complaints')
            .doc(reportId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: Text('Error loading report.',
                    style: GoogleFonts.poppins(color: Colors.red)));
          }
          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: kPrimary));
          }
          final data = snapshot.data!.data();
          if (data == null) {
            return Center(
                child: Text('Report not found.',
                    style: GoogleFonts.poppins(color: Colors.black54)));
          }

          final status = data['status']?.toString() ?? 'Pending';
          final stages = ['Pending', 'Assigned', 'In progress', 'Resolved'];
          final normalized = status.toLowerCase();
          var activeIdx = stages.indexWhere(
            (s) => normalized.contains(s.toLowerCase().replaceAll(' ', '')),
          );
          if (activeIdx < 0 && normalized.contains('progress')) activeIdx = 2;
          if (activeIdx < 0) activeIdx = 0;

          final imageUrl = data['image_url']?.toString() ?? '';

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Header card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFFE8FFF0), Color(0xFFF7FFFA)]),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kCardBorder),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: kPrimary,
                      child: const Icon(Icons.track_changes,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data['waste_type']?.toString() ?? 'Waste report',
                            style: GoogleFonts.poppins(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            data['address']?.toString() ??
                                'Location unavailable',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(
                                fontSize: 11, color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Image preview
              if (imageUrl.startsWith('data:image'))
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(
                    base64Decode(imageUrl.split(',').last),
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              if (imageUrl.startsWith('data:image'))
                const SizedBox(height: 14),

              // Progress tracker
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kCardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Current: $status',
                      style: GoogleFonts.poppins(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 14),
                    for (var i = 0; i < stages.length; i++)
                      _stage(
                        label: stages[i],
                        active: i <= activeIdx,
                        isLast: i == stages.length - 1,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'ID: $reportId',
                style: GoogleFonts.poppins(
                    fontSize: 10, color: Colors.black38),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _stage({
    required String label,
    required bool active,
    required bool isLast,
  }) {
    final color = active ? kPrimary : Colors.black26;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Icon(
              active ? Icons.check_circle : Icons.radio_button_unchecked,
              color: color,
              size: 22,
            ),
            if (!isLast)
              Container(
                  width: 2, height: 28, color: color.withOpacity(0.4)),
          ],
        ),
        const SizedBox(width: 10),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? kPrimaryDark : Colors.black45,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Report Complaint Screen
// ─────────────────────────────────────────────────────────────────────────────

class ReportComplaintScreen extends StatefulWidget {
  const ReportComplaintScreen({super.key});
  @override
  State<ReportComplaintScreen> createState() => _ReportComplaintScreenState();
}

class _ReportComplaintScreenState extends State<ReportComplaintScreen> {
  final ImagePicker _picker = ImagePicker();
  XFile? _imageFile;
  String? _selectedWasteType;
  final _descCtrl = TextEditingController();
  String address = 'Location pending';
  double latitude = 0;
  double longitude = 0;
  bool isSubmitting = false;
  bool isLocationLoading = true;
  bool isLocationVerified = false;
  bool showManualLocationEditor = false;
  final manualLocationCtrl = TextEditingController();

  final wasteTypes = [
    'E-Waste',
    'Wet Waste',
    'Dry Waste',
    'Plastic',
    'Construction Debris',
    'Hazardous',
    'Others',
  ];

  @override
  void initState() {
    super.initState();
    _autoDetectLocation();
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    manualLocationCtrl.dispose();
    super.dispose();
  }

  Future<void> _autoDetectLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          address = 'Location permission denied.';
          isLocationLoading = false;
          isLocationVerified = false;
        });
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final name = await reverseGeocodeWithNominatim(position);
      if (!mounted) return;
      setState(() {
        latitude = position.latitude;
        longitude = position.longitude;
        address = name;
        isLocationLoading = false;
        isLocationVerified = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        address = 'Could not detect location.';
        isLocationLoading = false;
        isLocationVerified = false;
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final image = await _picker.pickImage(
      source: source,
      imageQuality: 55,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (image != null) setState(() => _imageFile = image);
  }

  void _toggleManualEditor() {
    if (!showManualLocationEditor) {
      manualLocationCtrl.text = address;
    } else if (manualLocationCtrl.text.trim().isNotEmpty) {
      setState(() {
        address = manualLocationCtrl.text.trim();
        isLocationVerified = false;
      });
    }
    setState(() => showManualLocationEditor = !showManualLocationEditor);
  }

  Future<void> _openLocationPicker() async {
    final picked = await Navigator.of(context).push<PickedLocation>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialLocation: latitude != 0 && longitude != 0
              ? LatLng(latitude, longitude)
              : const LatLng(19.0760, 72.8777),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() {
      latitude = picked.location.latitude;
      longitude = picked.location.longitude;
      address = picked.address;
      isLocationVerified = true;
    });
  }

  bool _canSubmit() =>
      _imageFile != null && _selectedWasteType != null && !isSubmitting;

  Future<void> _submitComplaint() async {
    if (!_canSubmit()) return;
    setState(() => isSubmitting = true);
    try {
      final imageBase64 = await imageToFirestoreBase64(_imageFile!);
      await EcoSathiFirebaseService.submitComplaint(
        userId: EcoSathiFirebaseService.currentUser?.uid ?? '',
        wasteType: _selectedWasteType ?? 'Others',
        description: _descCtrl.text.trim(),
        address: address,
        latitude: latitude,
        longitude: longitude,
        imageUrl: imageBase64,
        isPriority: false,
      );
      if (!mounted) return;
      showAppNotification(context,
          title: 'Submitted!',
          message: 'Municipality can now review your complaint.');
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      showAppNotification(context,
          title: 'Submission failed',
          message: e.toString(),
          isError: true);
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back, size: 22),
        ),
        title: Text('Report Complaint',
            style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: kPrimaryDark)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Step 1: Photo
              _sectionLabel('Capture Photo'),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => _showImageSourceSheet(),
                child: Container(
                  height: 160,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEEEEE),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: _imageFile == null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.camera_alt,
                                size: 40, color: Colors.black38),
                            const SizedBox(height: 4),
                            Text('Tap to capture or select',
                                style: GoogleFonts.poppins(
                                    fontSize: 12, color: Colors.black45)),
                          ],
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.file(File(_imageFile!.path),
                              fit: BoxFit.cover),
                        ),
                ),
              ),

              const SizedBox(height: 16),
              // Waste type
              _sectionLabel('Waste Type'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: wasteTypes.map((type) {
                  final sel = _selectedWasteType == type;
                  return ChoiceChip(
                    label: Text(type,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: sel ? Colors.white : Colors.black87,
                        )),
                    selected: sel,
                    selectedColor: kPrimary,
                    backgroundColor: Colors.white,
                    side: BorderSide(
                        color: sel ? kPrimary : const Color(0xFFDDDDDD)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    onSelected: (_) =>
                        setState(() => _selectedWasteType = type),
                  );
                }).toList(),
              ),

              const SizedBox(height: 16),
              // Description
              _sectionLabel('Description (optional)'),
              const SizedBox(height: 8),
              TextField(
                controller: _descCtrl,
                maxLines: 3,
                minLines: 2,
                style: GoogleFonts.poppins(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Describe the issue...',
                  hintStyle: GoogleFonts.poppins(
                      fontSize: 13, color: Colors.black38),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                ),
              ),

              const SizedBox(height: 16),
              // Location
              _sectionLabel('Location'),
              const SizedBox(height: 8),
              _locationCard(),

              const SizedBox(height: 20),
              // Submit
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _canSubmit() ? _submitComplaint : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: kPrimaryDark,
                    disabledBackgroundColor: Colors.grey.shade300,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: isSubmitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : Text('Submit Complaint',
                          style: GoogleFonts.poppins(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showImageSourceSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt, color: kPrimary),
                title: Text('Camera',
                    style: GoogleFonts.poppins(fontSize: 14)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: kPrimary),
                title: Text('Gallery',
                    style: GoogleFonts.poppins(fontSize: 14)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.poppins(
          fontSize: 14, fontWeight: FontWeight.w600, color: kPrimaryDark),
    );
  }

  Widget _locationCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          const Color(0xFFEEF9EE).withOpacity(0.9),
          const Color(0xFFDFF5E0).withOpacity(0.8),
        ]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF90CB95)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.gps_fixed, color: kPrimary, size: 18),
              const SizedBox(width: 6),
              Text('Auto-detected location',
                  style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: kPrimaryDark)),
            ],
          ),
          const SizedBox(height: 6),
          if (isLocationLoading)
            Row(children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text('Detecting GPS...',
                  style: GoogleFonts.poppins(fontSize: 12)),
            ])
          else
            Text(
              isLocationVerified
                  ? 'Location verified ✅'
                  : 'Location needs review ⚠️',
              style: GoogleFonts.poppins(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isLocationVerified ? kPrimaryDark : Colors.deepOrange,
              ),
            ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(address,
                style: GoogleFonts.poppins(fontSize: 12, color: Colors.black87)),
          ),
          if (latitude != 0 && longitude != 0) ...[
            const SizedBox(height: 4),
            Text(
              'Lat: ${latitude.toStringAsFixed(5)}, Lng: ${longitude.toStringAsFixed(5)}',
              style: GoogleFonts.poppins(fontSize: 10, color: Colors.black45),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _toggleManualEditor,
                  icon: Icon(Icons.edit_location_alt_outlined, size: 16),
                  label: Text(
                    showManualLocationEditor ? 'Save' : 'Edit',
                    style: GoogleFonts.poppins(fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kPrimaryDark,
                    side: const BorderSide(color: Color(0xFF70B77A)),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openLocationPicker,
                  icon: const Icon(Icons.map_outlined, size: 16),
                  label: Text('Pick on map',
                      style: GoogleFonts.poppins(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kPrimaryDark,
                    side: const BorderSide(color: Color(0xFF70B77A)),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
            ],
          ),
          if (showManualLocationEditor)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: manualLocationCtrl,
                maxLines: 2,
                minLines: 1,
                style: GoogleFonts.poppins(fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Type the correct location',
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.all(10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFFB9DAB8)),
                  ),
                ),
              ),
            ),
          if (latitude != 0 && longitude != 0) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 140,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(latitude, longitude),
                    zoom: 15,
                  ),
                  markers: {
                    Marker(
                      markerId: const MarkerId('loc'),
                      position: LatLng(latitude, longitude),
                      icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueGreen),
                    ),
                  },
                  compassEnabled: false,
                  mapToolbarEnabled: false,
                  zoomControlsEnabled: false,
                  myLocationButtonEnabled: false,
                  liteModeEnabled: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Location Picker Screen
// ─────────────────────────────────────────────────────────────────────────────

class PickedLocation {
  const PickedLocation({required this.location, required this.address});
  final LatLng location;
  final String address;
}

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key, required this.initialLocation});
  final LatLng initialLocation;
  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  late LatLng _selectedLocation = widget.initialLocation;
  String _address = 'Tap on map to place pin';

  Future<void> _selectLocation(LatLng loc) async {
    setState(() => _selectedLocation = loc);
    final addr = await reverseGeocodeWithNominatim(Position(
      latitude: loc.latitude,
      longitude: loc.longitude,
      timestamp: DateTime.now(),
      accuracy: 0,
      altitude: 0,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
      altitudeAccuracy: 0,
      headingAccuracy: 0,
    ));
    if (mounted) setState(() => _address = addr);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Pin location',
            style: GoogleFonts.poppins(
                fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: widget.initialLocation,
              zoom: 16,
            ),
            markers: {
              Marker(
                markerId: const MarkerId('picked'),
                position: _selectedLocation,
                draggable: true,
                onDragEnd: _selectLocation,
              ),
            },
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            onTap: _selectLocation,
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 16,
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_address,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(fontSize: 12)),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(
                        PickedLocation(
                            location: _selectedLocation, address: _address),
                      ),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text('Use this location',
                          style: GoogleFonts.poppins(fontSize: 13)),
                      style: FilledButton.styleFrom(
                        backgroundColor: kPrimary,
                        minimumSize: const Size.fromHeight(40),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Map Screen
// ─────────────────────────────────────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _mapCtrl;
  Set<Marker> _markers = {};
  Position? _currentPos;
  String _locAddr = 'Detecting current location...';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _locAddr = 'Location permission denied.';
          _loading = false;
          _markers = {
            const Marker(
              markerId: MarkerId('demo'),
              position: LatLng(19.0760, 72.8777),
              infoWindow: InfoWindow(title: 'Default location'),
            ),
          };
        });
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      final addr = await reverseGeocodeWithNominatim(pos);

      final snap = await EcoSathiFirebaseService.firestore
          .collection('complaints')
          .get();
      final markers = <Marker>{};
      for (final doc in snap.docs) {
        final d = doc.data();
        final lat = d['latitude'];
        final lng = d['longitude'];
        if (lat is num && lng is num) {
          markers.add(Marker(
            markerId: MarkerId(doc.id),
            position: LatLng(lat.toDouble(), lng.toDouble()),
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueRed),
            infoWindow: InfoWindow(
              title: d['waste_type'] ?? 'Complaint',
              snippet: d['address'] ?? '',
            ),
          ));
        }
      }
      markers.add(Marker(
        markerId: const MarkerId('current'),
        position: LatLng(pos.latitude, pos.longitude),
        icon:
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'You are here'),
      ));

      if (!mounted) return;
      setState(() {
        _currentPos = pos;
        _locAddr = addr;
        _markers = markers;
        _loading = false;
      });
      _mapCtrl?.animateCamera(CameraUpdate.newCameraPosition(
        CameraPosition(
            target: LatLng(pos.latitude, pos.longitude), zoom: 14),
      ));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _locAddr = 'Location not available.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _currentPos != null
        ? LatLng(_currentPos!.latitude, _currentPos!.longitude)
        : const LatLng(19.0760, 72.8777);

    return Scaffold(
      appBar: AppBar(
        title: Text('Live Map',
            style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: kPrimaryDark)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => _loading = true);
              _init();
            },
            icon: const Icon(Icons.my_location, color: kPrimaryDark, size: 22),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kPrimary))
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition:
                      CameraPosition(target: target, zoom: 14),
                  markers: _markers,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  onMapCreated: (c) => _mapCtrl = c,
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            const Color(0xFFEEF9EE).withOpacity(0.8),
                            const Color(0xFFEBF4FF).withOpacity(0.6),
                          ]),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Your Location',
                                style: GoogleFonts.poppins(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: kPrimaryDark)),
                            const SizedBox(height: 4),
                            Text(_locAddr,
                                style: GoogleFonts.poppins(
                                    fontSize: 12, color: Colors.black87)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Municipality Dashboard
// ─────────────────────────────────────────────────────────────────────────────

class MunicipalityDashboard extends StatelessWidget {
  const MunicipalityDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: kAccentLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.account_balance,
                    size: 18, color: kPrimaryDark),
              ),
              const SizedBox(width: 8),
              Text('Municipality',
                  style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: kPrimaryDark)),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Logout',
              onPressed: () async {
                await EcoSathiFirebaseService.signOut();
                if (!context.mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const SplashScreen()),
                  (route) => false,
                );
              },
              icon: const Icon(Icons.logout, color: Colors.red, size: 22),
            ),
          ],
        ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: EcoSathiFirebaseService.firestore
              .collection('complaints')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 40, color: Colors.red),
                    const SizedBox(height: 8),
                    Text('Unable to load complaints.',
                        style: GoogleFonts.poppins(fontSize: 14)),
                  ],
                ),
              );
            }
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: CircularProgressIndicator(color: kPrimary));
            }
            final complaints = snapshot.data?.docs ?? [];
            if (complaints.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inbox_outlined,
                        size: 48, color: Colors.black26),
                    const SizedBox(height: 8),
                    Text('No complaints received yet.',
                        style: GoogleFonts.poppins(
                            fontSize: 14, color: Colors.black45)),
                  ],
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: complaints.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final doc = complaints[index];
                final data = doc.data();
                final status = data['status']?.toString() ?? 'Pending';
                final imageUrl = data['image_url']?.toString() ?? '';
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MunicipalityComplaintDetail(
                          complaintId: doc.id),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: kCardBorder),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x0F000000),
                            blurRadius: 4,
                            offset: Offset(0, 2)),
                      ],
                    ),
                    child: Row(
                      children: [
                        // Thumbnail
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: imageUrl.startsWith('data:image')
                                ? Image.memory(
                                    base64Decode(imageUrl.split(',').last),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      color: kAccentLight,
                                      child: const Icon(Icons.image,
                                          size: 18, color: Colors.black38),
                                    ),
                                  )
                                : Container(
                                    color: kAccentLight,
                                    child: const Icon(Icons.image_outlined,
                                        size: 18, color: Colors.black38),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                data['waste_type']?.toString() ??
                                    'Waste complaint',
                                style: GoogleFonts.poppins(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600),
                              ),
                              Text(
                                data['address']?.toString() ??
                                    'No location',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.poppins(
                                    fontSize: 11, color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _muniStatusColor(status).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            status,
                            style: GoogleFonts.poppins(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: _muniStatusColor(status),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Color _muniStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'resolved':
        return const Color(0xFF2E7D32);
      case 'in progress':
        return const Color(0xFFF57C00);
      case 'assigned':
        return const Color(0xFF1565C0);
      default:
        return const Color(0xFF757575);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Municipality Complaint Detail – view details + update status
// ─────────────────────────────────────────────────────────────────────────────

class MunicipalityComplaintDetail extends StatelessWidget {
  const MunicipalityComplaintDetail({super.key, required this.complaintId});
  final String complaintId;

  static const _statuses = ['Pending', 'Assigned', 'In progress', 'Resolved'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Complaint Detail',
            style: GoogleFonts.poppins(
                fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: EcoSathiFirebaseService.firestore
            .collection('complaints')
            .doc(complaintId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: Text('Error loading complaint.',
                    style: GoogleFonts.poppins(color: Colors.red)));
          }
          if (!snapshot.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: kPrimary));
          }
          final data = snapshot.data!.data();
          if (data == null) {
            return Center(
                child: Text('Complaint not found.',
                    style: GoogleFonts.poppins(color: Colors.black54)));
          }

          final status = data['status']?.toString() ?? 'Pending';
          final imageUrl = data['image_url']?.toString() ?? '';
          final lat = (data['latitude'] as num?)?.toDouble() ?? 0;
          final lng = (data['longitude'] as num?)?.toDouble() ?? 0;
          final desc = data['description']?.toString() ?? '';

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Image
              if (imageUrl.startsWith('data:image'))
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(
                    base64Decode(imageUrl.split(',').last),
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 100,
                      color: kAccentLight,
                      child: const Center(
                          child: Icon(Icons.broken_image, size: 30)),
                    ),
                  ),
                ),
              const SizedBox(height: 14),

              // Details card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kCardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailRow('Type', data['waste_type']?.toString() ?? '-'),
                    _detailRow('Address', data['address']?.toString() ?? '-'),
                    if (desc.isNotEmpty) _detailRow('Description', desc),
                    _detailRow('Status', status),
                    if (lat != 0)
                      _detailRow(
                          'Coordinates',
                          'Lat: ${lat.toStringAsFixed(5)}, '
                              'Lng: ${lng.toStringAsFixed(5)}'),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Map preview
              if (lat != 0 && lng != 0)
                SizedBox(
                  height: 160,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: GoogleMap(
                      initialCameraPosition:
                          CameraPosition(target: LatLng(lat, lng), zoom: 15),
                      markers: {
                        Marker(
                          markerId: const MarkerId('complaint'),
                          position: LatLng(lat, lng),
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueRed),
                        ),
                      },
                      compassEnabled: false,
                      zoomControlsEnabled: false,
                      myLocationButtonEnabled: false,
                      liteModeEnabled: true,
                    ),
                  ),
                ),
              const SizedBox(height: 18),

              // Status update
              Text('Update Status',
                  style: GoogleFonts.poppins(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: kPrimaryDark)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _statuses.map((s) {
                  final isCurrent = s.toLowerCase() == status.toLowerCase();
                  return FilledButton(
                    onPressed: isCurrent
                        ? null
                        : () => _updateStatus(context, s),
                    style: FilledButton.styleFrom(
                      backgroundColor: isCurrent ? kPrimary : Colors.grey.shade200,
                      foregroundColor:
                          isCurrent ? Colors.white : Colors.black87,
                      minimumSize: const Size(0, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(s,
                        style: GoogleFonts.poppins(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              Text('ID: $complaintId',
                  style: GoogleFonts.poppins(
                      fontSize: 10, color: Colors.black38)),
            ],
          );
        },
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.black54)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.poppins(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _updateStatus(BuildContext context, String newStatus) async {
    try {
      await EcoSathiFirebaseService.firestore
          .collection('complaints')
          .doc(complaintId)
          .update({'status': newStatus});
      if (!context.mounted) return;
      showAppNotification(context,
          title: 'Status updated',
          message: 'Complaint marked as $newStatus.');
    } catch (e) {
      if (!context.mounted) return;
      showAppNotification(context,
          title: 'Update failed',
          message: e.toString(),
          isError: true);
    }
  }
}
