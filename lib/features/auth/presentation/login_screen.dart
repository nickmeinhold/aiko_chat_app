import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/diagnostics/report_problem_button.dart';
import '../../../core/network/network_status_banner.dart';
import '../application/auth_controller.dart';
import 'auth_error_text.dart';

/// The login ingress the user last invoked (create vs sign in). Held in a
/// PROVIDER, not widget State, so it survives a [LoginScreen] remount while an
/// auth error persists: the error lives in [authControllerProvider] (which
/// outlives the widget), so a State field would reset to `signIn` on remount and
/// mislabel a create-account failure as "reconnect to sign in" (cage-match #74,
/// Carnot + Tesla). The provider co-lives with the controller's container, so
/// action and error move and reset together.
class LoginActionController extends Notifier<AuthAction> {
  @override
  AuthAction build() => AuthAction.signIn;
  void set(AuthAction action) => state = action;
}

final loginActionProvider = NotifierProvider<LoginActionController, AuthAction>(
  LoginActionController.new,
);

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
    final gatewayHost = gatewayHostLabel(ref.watch(configProvider).httpBaseUrl);

    void passkeySignIn() {
      ref.read(loginActionProvider.notifier).set(AuthAction.signIn);
      ref.read(authControllerProvider.notifier).signInWithPasskey();
    }

    void passkeyRegister() {
      ref.read(loginActionProvider.notifier).set(AuthAction.createAccount);
      ref.read(authControllerProvider.notifier).registerWithPasskey();
    }

    return Scaffold(
      // No AppBar — a passkey-first ingress doesn't need a Material title bar;
      // the content stands on its own. SafeArea keeps it clear of the status bar
      // now that nothing sits above it.
      body: SafeArea(
        child: Column(
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
                        // Passkeys need a platform authenticator (iOS
                        // Authentication Services / Android Credential Manager) —
                        // no web target ships, so nothing renders on web.
                        if (!kIsWeb) ...[
                          FilledButton.icon(
                            onPressed: busy ? null : passkeyRegister,
                            icon: const Icon(Icons.fingerprint),
                            label: const Text('Create a passkey'),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: busy ? null : passkeySignIn,
                            child: const Text(
                              'Already have a passkey? Sign in',
                            ),
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
                              action: ref.watch(loginActionProvider),
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          // One-tap path for the genuinely-stuck: bundle device
                          // specs + network state + a SAFE error label into the
                          // share sheet (PR3).
                          ReportProblemButton(error: auth.error),
                        ],
                        const SizedBox(height: 28),
                        Text(
                          'Server: $gatewayHost',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
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
      ),
    );
  }
}
