import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../application/auth_controller.dart';
import '../data/social_auth_client.dart';

/// Social sign-in screen (Apple + Google). Watches [authControllerProvider]:
/// a spinner while the call is in flight, an inline error if it failed. On
/// success the controller publishes the user and the router redirects to chat
/// — this screen does no navigation itself.
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  /// Apple requires Sign in with Apple be *offered* whenever other social
  /// logins are, but only its own platforms get the native sheet (Android would
  /// need the web flow — deferred).
  static bool get _appleAvailable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Native Google sign-in (`authenticate()`) is unsupported on web — the web
  /// SDK requires its own rendered-button flow, which this app (no web target)
  /// doesn't ship. Hide the button there rather than show one that can't
  /// complete (Carnot).
  static bool get _googleAvailable => !kIsWeb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final busy = auth.isLoading;

    void social(SocialProvider provider) {
      ref.read(authControllerProvider.notifier).signInWith(provider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_appleAvailable) ...[
                  SignInWithAppleButton(
                    onPressed: busy ? () {} : () => social(SocialProvider.apple),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_googleAvailable) ...[
                  OutlinedButton.icon(
                    onPressed:
                        busy ? null : () => social(SocialProvider.google),
                    icon: const Icon(Icons.account_circle_outlined),
                    label: const Text('Continue with Google'),
                  ),
                ],
                if (auth.hasError) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Something went wrong. Please try again.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
