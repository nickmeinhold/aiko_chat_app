import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/report_problem_button.dart';
import '../../../core/network/network_status_banner.dart';
import '../application/auth_controller.dart';
import 'auth_error_text.dart';

/// The passkey sign-in screen — the app's sole ingress after social sign-in was
/// removed. First-passkey-creates-account: ONE prominent "Create a passkey"
/// (register a new passkey + account) plus a secondary "Already have a passkey?"
/// (assert an existing/discoverable credential).
///
/// Watches [authControllerProvider] for the in-flight spinner / error. On
/// success the controller publishes the user and the router redirects to chat —
/// this screen does no navigation itself.
///
/// Stateful only to remember WHICH action the user last invoked (create vs sign
/// in), so an offline failure — the same [NetworkUnavailable] for both — is
/// phrased honestly: "creating your account needs internet just this once" vs
/// "reconnect to sign in".
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  // The last ingress the user tapped. Drives error phrasing only; it doesn't
  // need setState (the auth state change already rebuilds, and this is always
  // set before the resulting failure renders). Defaults to signIn.
  AuthAction _lastAction = AuthAction.signIn;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final busy = auth.isLoading;
    // Choosing a server is a PRE-LOGIN act (#35): surface the active gateway and
    // a way to change it, so a user stranded on an unreachable server can switch
    // away without reinstalling. The route is logged-out-reachable (see router).
    final gatewayHost = _hostOf(ref.watch(configProvider).httpBaseUrl);

    void passkeySignIn() {
      _lastAction = AuthAction.signIn;
      ref.read(authControllerProvider.notifier).signInWithPasskey();
    }

    void passkeyRegister() {
      _lastAction = AuthAction.createAccount;
      ref.read(authControllerProvider.notifier).registerWithPasskey();
    }

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
                          authErrorText(
                            auth.error,
                            host: gatewayHost,
                            action: _lastAction,
                          ),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        // One-tap path for the genuinely-stuck: bundle device specs +
                        // network state + the raw error into the share sheet (PR3).
                        ReportProblemButton(error: auth.error),
                      ],
                      const SizedBox(height: 28),
                      Text(
                        'Server: $gatewayHost',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => context.push('/settings/gateway'),
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
}
