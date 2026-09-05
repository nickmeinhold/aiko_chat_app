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
    final islandHost = islandHostLabel(ref.watch(configProvider).httpBaseUrl);
    // Synchronous read off already-loaded prefs — an async one would render the
    // wrong emphasis for a frame and then swap under the user's thumb.
    // Keyed on the BASE URL, not the display label: the label is for humans and
    // could collapse two distinct islands onto one string, which would leak one
    // island's hint onto another.
    // Same fail-open rule as the write side: a missing prefs binding must never
    // brick the login WALL — that would make a cosmetic hint able to lock a user
    // out of the app entirely. No evidence reads as "fresh device", which is the
    // safe emphasis (Create primary, sign-in still reachable).
    bool passkeySeenHere;
    try {
      passkeySeenHere = ref
          .watch(passkeyHintStoreProvider)
          .seenFor(ref.watch(configProvider).httpBaseUrl);
    } catch (_) {
      passkeySeenHere = false;
    }

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
      // A STABLE handle for "we are at the login wall", so tests assert the
      // DESTINATION rather than a button's wording. Several logout / account-
      // deletion tests asserted `widgetWithText(FilledButton, 'Create a passkey')`
      // to mean "back at login" — which silently became false when the primary
      // ingress started swapping with the passkey hint (the hint survives logout
      // by design, because the passkey does).
      key: const Key('login-screen'),
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
                        // EMPHASIS FOLLOWS THE DEVICE, and the order is the
                        // whole point. An Apple reviewer with a fresh install
                        // tapped "Already have a passkey? Sign in" — which on a
                        // device with no passkey can only fail — and 0.0.4 was
                        // REJECTED on what they saw next. Our own review notes
                        // said to tap Create; the screen gave both options equal
                        // standing and let them pick the one that cannot work.
                        //
                        // So the likely-correct ingress is the FilledButton and
                        // the other is a TextButton, swapped on the hint.
                        //
                        // The sign-in affordance is NEVER removed, only demoted.
                        // A passkey outlives the app: reinstall, or restore a new
                        // device from iCloud Keychain / Google Password Manager,
                        // and a REAL credential exists with no local hint. Hiding
                        // sign-in there would strand a returning user holding a
                        // valid passkey — trading this rejection for a worse bug.
                        // `seen == false` means "no evidence", never "no passkey".
                        if (!kIsWeb) ...[
                          if (passkeySeenHere) ...[
                            FilledButton.icon(
                              onPressed: busy ? null : passkeySignIn,
                              icon: const Icon(Icons.fingerprint),
                              label: const Text('Sign in with your passkey'),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: busy ? null : passkeyRegister,
                              child: const Text('Create a new passkey'),
                            ),
                          ] else ...[
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
                              host: islandHost,
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
                          'Island: $islandHost',
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
                              : () => context.push('/settings/island'),
                          child: const Text('Change island'),
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
