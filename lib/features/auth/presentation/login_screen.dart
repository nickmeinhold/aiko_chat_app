import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/network/network_status_banner.dart';
import '../application/auth_controller.dart';
import '../data/auth_exceptions.dart';

/// The passkey sign-in screen — the app's sole ingress after social sign-in was
/// removed. First-passkey-creates-account: ONE prominent "Create a passkey"
/// (register a new passkey + account) plus a secondary "Already have a passkey?"
/// (assert an existing/discoverable credential).
///
/// Watches [authControllerProvider] for the in-flight spinner / error. On
/// success the controller publishes the user and the router redirects to chat —
/// this screen does no navigation itself.
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final busy = auth.isLoading;
    // Choosing a server is a PRE-LOGIN act (#35): surface the active gateway and
    // a way to change it, so a user stranded on an unreachable server can switch
    // away without reinstalling. The route is logged-out-reachable (see router).
    final gatewayHost = _hostOf(ref.watch(configProvider).httpBaseUrl);

    void passkeySignIn() =>
        ref.read(authControllerProvider.notifier).signInWithPasskey();
    void passkeyRegister() =>
        ref.read(authControllerProvider.notifier).registerWithPasskey();

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Column(
        children: [
          // Full-width network banner — the login screen is exactly where the
          // DNS failure surfaced (PR #71), and pre-auth there is no socket, so
          // this is the user's only connectivity signal here.
          const NetworkStatusBanner(),
          Expanded(
            child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Passkeys need a platform authenticator (iOS Authentication
                // Services / Android Credential Manager) — no web target ships,
                // so there is nothing to render on web.
                if (!kIsWeb) ...[
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
                if (busy) ...[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
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
          ),
        ],
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

  /// Human-readable, actionable text for an auth failure. The controller records
  /// the thrown exception verbatim (`AsyncValue.guard`), so the specific reason
  /// is available here — surface it instead of a blanket "something went wrong".
  ///
  /// Passkey failures arrive as `AuthCeremonyFailed('Passkey: <code>')` (see
  /// [PlatformPasskeyAuthClient]); the documented codes get tailored guidance.
  /// Anything unmapped falls through to its RAW text so a new failure mode is
  /// never invisible — the generic message is only the last resort for an empty
  /// error, which is what made this screen blind in the first place.
  static String _authErrorText(Object? error, String host) {
    final raw =
        error is AuthCeremonyFailed ? error.message : (error?.toString() ?? '');
    final lower = raw.toLowerCase();
    if (raw.contains('no-credentials-available')) {
      return 'No passkey found on this device. '
          'Tap "Create a passkey" above to make one.';
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
