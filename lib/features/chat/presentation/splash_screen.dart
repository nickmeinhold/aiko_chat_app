import 'package:flutter/material.dart';

/// Shown only while the cold-start session restore is in flight, so the user
/// never sees a login-screen flash before a valid stored session resolves.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
