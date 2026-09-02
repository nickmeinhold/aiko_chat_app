import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../application/auth_controller.dart';
import 'auth_error_text.dart';

/// Shown when THIS island has suspended (banned) the current account — driven by
/// [suspendedProvider] (set when a `403 {"detail":"account suspended"}` surfaces
/// as [AccountSuspended]). A ban is terminal-for-this-island and reversible, NOT
/// "logged out, sign in again" — so this replaces the login screen's inline
/// "sign in again" copy (which loops: a re-auth 403s again) with an honest
/// dedicated surface and the two real ways out:
///   - "Try signing in again" — clears the soft gate → /login. If the ban lifted
///     the user signs back in; if not, the attempt re-flags and returns here.
///   - "Use a different island" — the gateway picker; switchGateway clears the
///     flag, so a different (non-banning) island lands cleanly on its /login.
///
/// The host is read from [configProvider] (single owner for the active gateway),
/// so [suspendedProvider] stays a bare flag.
class SuspendedScreen extends ConsumerWidget {
  const SuspendedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = gatewayHostLabel(ref.watch(configProvider).httpBaseUrl);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.block, size: 56, color: theme.colorScheme.error),
                  const SizedBox(height: 20),
                  Text(
                    'Account suspended',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This account is suspended on $host. If you think this is a '
                    'mistake, contact the people who run this island.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    // Dismiss the soft gate and return to /login. A re-auth
                    // against a still-banned account re-flags and comes back
                    // here; a lifted ban signs the user in.
                    onPressed: () =>
                        ref.read(suspendedProvider.notifier).clear(),
                    child: const Text('Try signing in again'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => context.go('/settings/island'),
                    child: const Text('Use a different island'),
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
