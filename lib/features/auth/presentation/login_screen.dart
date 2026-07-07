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
          // primary "create" (register a new passkey + account) and a secondary
          // "sign in" (for an existing/discoverable credential). The "create"
          // is prominent to guide new users, as "sign in" will fail for them.
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : passkeyRegister,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Create a passkey'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: busy ? null : passkeySignIn,
                child: const Text('Already have a passkey? Sign in'),
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
                    _authErrorText(auth.error, gatewayHost),
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

  /// The host (with port, when present) of the active gateway for the login
  /// footer — falls back to the full URL if it doesn't parse to a host. The port
  /// is load-bearing: two gateways on the same host differing only by port (e.g.
  /// Local `:8095` vs an emulator host) would otherwise be indistinguishable
  /// here (Carnot, cage-match #53).
  static String _hostOf(String httpBaseUrl) {
    final uri = Uri.tryParse(httpBaseUrl);
    final host = uri?.host;
    if (host == null || host.isEmpty) return httpBaseUrl;
    return uri!.hasPort ? '$host:${uri.port}' : host;
  }

  /// A best-effort glyph per broker provider; generic fallback otherwise.
  static IconData _brokerIcon(String slug) => switch (slug) {
        'github' => Icons.code,
        'discord' => Icons.forum_outlined,
        _ => Icons.login,
      };

  /// Human-readable, actionable text for an auth failure. The controller records
  /// the thrown exception verbatim (`AsyncValue.guard`), so the specific reason
  /// is available here — surface it instead of a blanket "something went wrong".
  ///
  /// Passkey failures arrive as `SocialSignInFailed('Passkey: <code>')` (see
  /// [PlatformPasskeyAuthClient]); the documented codes get tailored guidance.
  /// Anything unmapped falls through to its RAW text so a new failure mode is
  /// never invisible — the generic message is only the last resort for an empty
  /// error, which is what made this screen blind in the first place.
  static String _authErrorText(Object? error, String host) {
    final raw =
        error is SocialSignInFailed ? error.message : (error?.toString() ?? '');
    final lower = raw.toLowerCase();
    if (raw.contains('no-credentials-available')) {
      return 'No passkey found on this device. '
          'Tap "New here? Create a passkey" below to make one.';
    }
    if (raw.contains('domain-not-associated')) {
      return "Passkeys aren't linked to $host yet, so sign-in can't complete. "
          "(The server's domain association is still pending.)";
    }
    if (raw.contains('deviceNotSupported') || lower.contains('not supported')) {
      return "This device doesn't support passkeys.";
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'The request timed out. Please try again.';
    }
    return raw.isEmpty
        ? 'Something went wrong. Please try again.'
        : 'Sign-in failed: $raw';
  }
}
