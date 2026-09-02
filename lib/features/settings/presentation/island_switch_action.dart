/// The shared "switch island (and re-login)" flow.
///
/// Switching island is a hard logout by design: [AuthController.switchIsland]
/// clears tokens + cached user, disconnects, and bounces to the new island's
/// `/login` (JWTs are island-specific). Two surfaces trigger it — the full
/// island picker ([IslandPickerScreen]) and the wide-layout sidebar island
/// switcher ([ChatSidebar]) — so the no-op guard, the confirm dialog, the
/// [IslandSwitchFailed] error copy, and the post-switch `/login` landing all
/// live HERE, once, so the two entry points can never drift.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/config.dart';
import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';

/// Guard → confirm → switch → land on `/login`.
///
/// - No-op guard: selecting the ALREADY-active island shows a snackbar and
///   returns without a dialog (a switch to the current island would needlessly
///   destroy a live session — normalized compare so a trailing slash can't hide
///   the match).
/// - Confirm: a single shared dialog naming [label]; Cancel returns silently.
/// - Switch: [AuthController.switchIsland]. A persistence failure throws BEFORE
///   any teardown (session intact) — surfaced inline, stay put.
/// - Land: `GoRouter.go('/login')` (we're logged out now, so `/login` is always
///   correct — see the picker's rationale; `maybeOf` keeps a bare-widget test a
///   safe no-op).
///
/// [onSwitching] lets a caller drive a local busy indicator (the picker's
/// AbsorbPointer spinner) around the awaited switch; it is optional so the
/// sidebar can call this with no local state.
Future<void> confirmAndSwitchIsland(
  BuildContext context,
  WidgetRef ref, {
  required String url,
  required String label,
  void Function(bool switching)? onSwitching,
}) async {
  final current = ref.read(configProvider).httpBaseUrl;
  if (IslandConfig.normalized(url).httpBaseUrl == current) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Already connected to this island.')),
    );
    return;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Switch island?'),
      content: Text(
        'You\'ll be signed out and need to sign in again on $label. '
        'Your account on the current island is not affected.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Switch'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  onSwitching?.call(true);
  // switchIsland publishes `loading` (router → /splash) then logs the user out
  // on the new island. A persistence failure throws BEFORE any teardown
  // (session intact) — surface it and stay put.
  try {
    await ref.read(authControllerProvider.notifier).switchIsland(url);
  } catch (e) {
    if (!context.mounted) return;
    onSwitching?.call(false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_switchError(e))));
    return;
  }
  // Land deterministically on the new island's /login. Since #35 made
  // /settings/island reachable while logged out, the redirect treats it as a
  // valid logged-out resting state — so without an explicit nav the picker stays
  // on screen after the switch. maybeOf keeps a bare-widget unit test (no
  // GoRouter ancestor) a safe no-op.
  if (context.mounted) GoRouter.maybeOf(context)?.go('/login');
  if (context.mounted) onSwitching?.call(false);
}

String _switchError(Object e) {
  if (e is IslandSwitchFailed) return e.message;
  return 'Could not switch islands. Please try again.';
}
