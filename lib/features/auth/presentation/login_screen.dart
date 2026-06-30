import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../app/providers.dart';
import '../application/auth_controller.dart';
import '../data/social_auth_client.dart';
import '../domain/auth_provider.dart';

/// Social sign-in screen. The button list is driven by the gateway's
/// `GET /v1/auth/providers` ([authProvidersProvider]): native providers
/// (Apple/Google) render their platform-specific button (and only on supported
/// platforms), while every `broker` provider (GitHub, …) renders a generic
/// "Continue with X" that runs the web-auth broker flow by slug — so adding a
/// broker provider is a gateway-only change, no app release.
///
/// Watches [authControllerProvider] for the in-flight spinner / error. On
/// success the controller publishes the user and the router redirects to chat —
/// this screen does no navigation itself.
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
    final providers = ref.watch(authProvidersProvider);
    // Choosing a server is a PRE-LOGIN act (#35): surface the active gateway and
    // a way to change it, so a user stranded on an unreachable server can switch
    // away without reinstalling. The route is logged-out-reachable (see router).
    final gatewayHost = _hostOf(ref.watch(configProvider).httpBaseUrl);

    void social(SocialProvider provider) =>
        ref.read(authControllerProvider.notifier).signInWith(provider);
    void broker(String slug) =>
        ref.read(authControllerProvider.notifier).signInWithBroker(slug);
    void passkeySignIn() =>
        ref.read(authControllerProvider.notifier).signInWithPasskey();
    void passkeyRegister() =>
        ref.read(authControllerProvider.notifier).registerWithPasskey();

    // Build the button for one advertised provider, or null if it can't render
    // on this platform (e.g. an Apple native button on Android).
    Widget? buttonFor(AuthProviderInfo p) {
      switch (p.kind) {
        case AuthProviderKind.native:
          switch (p.slug) {
            case 'apple':
              if (!_appleAvailable) return null;
              return SignInWithAppleButton(
                onPressed: busy ? () {} : () => social(SocialProvider.apple),
              );
            case 'google':
              if (!_googleAvailable) return null;
              return OutlinedButton.icon(
                onPressed: busy ? null : () => social(SocialProvider.google),
                icon: const Icon(Icons.account_circle_outlined),
                label: const Text('Continue with Google'),
              );
            default:
              return null; // an unknown native provider has no compiled SDK
          }
        case AuthProviderKind.broker:
          return OutlinedButton.icon(
            onPressed: busy ? null : () => broker(p.slug),
            icon: Icon(_brokerIcon(p.slug)),
            label: Text('Continue with ${p.displayName}'),
          );
        case AuthProviderKind.passkey:
          // Passkeys need a platform authenticator (iOS AuthenticationServices /
          // Android Credential Manager) — no web target ships, so hide there.
          if (kIsWeb) return null;
          // First-passkey-creates-account: ONE advertised entry drives BOTH a
          // primary "sign in" (assert an existing/discoverable credential) and a
          // secondary "create" (register a new passkey + account).
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : passkeySignIn,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Sign in with a passkey'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: busy ? null : passkeyRegister,
                child: const Text('New here? Create a passkey'),
              ),
            ],
          );
      }
    }

    // If the providers fetch fails, fall back to the statically-known native
    // buttons so sign-in still works (the fetch is best-effort chrome, not a
    // hard dependency for Apple/Google).
    List<Widget> nativeFallback() => [
          if (_appleAvailable) ...[
            SignInWithAppleButton(
              onPressed: busy ? () {} : () => social(SocialProvider.apple),
            ),
            const SizedBox(height: 12),
          ],
          if (_googleAvailable)
            OutlinedButton.icon(
              onPressed: busy ? null : () => social(SocialProvider.google),
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('Continue with Google'),
            ),
        ];

    final buttons = providers.when(
      data: (list) {
        final widgets = <Widget>[];
        for (final p in list) {
          final b = buttonFor(p);
          if (b == null) continue;
          if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 12));
          widgets.add(b);
        }
        // Defensive: if the gateway advertised nothing renderable, fall back.
        return widgets.isEmpty ? nativeFallback() : widgets;
      },
      loading: () => const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (_, _) => nativeFallback(),
    );

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
                ...buttons,
                if (auth.hasError) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Something went wrong. Please try again.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 28),
                Text(
                  'Server: $gatewayHost',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                TextButton(
                  onPressed:
                      busy ? null : () => context.push('/settings/gateway'),
                  child: const Text('Change server'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The host of the active gateway for the login footer — falls back to the
  /// full URL if it doesn't parse to a host.
  static String _hostOf(String httpBaseUrl) {
    final host = Uri.tryParse(httpBaseUrl)?.host;
    return (host == null || host.isEmpty) ? httpBaseUrl : host;
  }

  /// A best-effort glyph per broker provider; generic fallback otherwise.
  static IconData _brokerIcon(String slug) => switch (slug) {
        'github' => Icons.code,
        'discord' => Icons.forum_outlined,
        _ => Icons.login,
      };
}
