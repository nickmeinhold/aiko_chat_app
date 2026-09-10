import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../application/notification_tap_providers.dart';

/// Sends the app to the conversation list when a call notification is tapped
/// (claude-tasks#3588).
///
/// Mounted in `MaterialApp.router`'s `builder` beside [RingOverlay], and for the
/// same reason: a tap must be honoured wherever the app happens to be. The app
/// resumes on whatever route it was last on, so a user reading Settings when the
/// call arrived would otherwise tap "Incoming call" and be left in Settings —
/// the buffer holding a tap that nothing on screen can consume.
///
/// **This widget NAVIGATES; it does not SELECT.** The pick belongs to
/// `ChatScreen`, which owns the readiness gate — a conversation cannot be
/// selected until both channels and DMs have settled, and on a cold start caused
/// by the tap they have not. Splitting it this way means neither half has to
/// know the other's timing: this one guarantees the screen exists, that one
/// guarantees the pick lands when it can stick. The tap stays in
/// [pendingCallTapProvider] across the gap.
class NotificationTapNavigator extends ConsumerWidget {
  const NotificationTapNavigator({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<String?>(pendingCallTapProvider, (_, next) {
      if (next == null) return;
      // Do NOT take() here — taking is the consumer's job, and taking without
      // selecting would drop the tap on the floor if the screen is not ready.
      final router = ref.read(routerProvider);
      if (router.state.uri.path != '/') router.go('/');
    });
    return child;
  }
}
