/// The incoming-call ring (#2808) — an app-wide banner above every route.
///
/// Mounted in `MaterialApp.router`'s `builder`, ABOVE the Navigator, because a
/// call must reach you wherever you are: reading another conversation, in
/// Settings, anywhere. A ring rendered inside a route would only ring on that
/// route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/feature_flags.dart' show callingEnabledProvider;
import '../../../app/router.dart';
import '../application/ring_controller.dart';
import '../domain/call_invite.dart';
import 'media_confidentiality_chip.dart';
import 'call_screen.dart' show isCallRouteOpen, isInLiveCall, pushCallOn;

/// Wraps [child] with the ring banner. A no-op (zero layout cost, no overlay)
/// whenever nothing is ringing.
class RingOverlay extends ConsumerWidget {
  const RingOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The gate lives HERE, not at the mount site in `main.dart`, because this
    // widget is the only thing that answers a ring: a banner whose Accept
    // pushes `/call/...` while that route is unregistered would offer a button
    // that goes nowhere, which is worse than not ringing. One door, one
    // decision (see `app/feature_flags.dart`).
    if (!ref.watch(callingEnabledProvider)) return child;
    final invite = ref.watch(incomingRingProvider);
    return Stack(
      children: [
        child,
        if (invite != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _RingBanner(invite: invite),
          ),
      ],
    );
  }
}

class _RingBanner extends ConsumerWidget {
  const _RingBanner({required this.invite});

  final CallInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Label is nullable AND can be empty; both mean "we don't have a name for
    // this key yet" and both must render as a person, never as a blank row.
    final label = invite.from.label;
    final caller = (label == null || label.isEmpty) ? 'Someone' : label;
    return SafeArea(
      // Material, not a bare Container: this sits above the Navigator, so it has
      // no ancestor Material to draw ink, text baselines or elevation against.
      child: Material(
        elevation: 8,
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.videocam, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          caller,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Incoming call',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  // "Ignore", NOT "Decline". The caller is never told — there is no
                  // signal back to them until the island's occupancy endpoint lands
                  // (claude-tasks#3159). "Decline" implies they hear about it; the
                  // word would be the lie, so the honest word does the work instead
                  // of a disclaimer.
                  TextButton(
                    onPressed: () =>
                        ref.read(incomingRingProvider.notifier).stopRinging(),
                    child: const Text('Ignore'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _answer(context, ref),
                    icon: const Icon(Icons.call),
                    label: const Text('Answer'),
                  ),
                ],
              ),
              // The disclosure gets its OWN full-width line rather than a slot
              // inside the caller's column, and this is a render-driven fix,
              // not a taste one. Squeezed beside the name and two buttons, the
              // corrected label ("Not end-to-end encrypted") ELLIPSIZED to
              // "Not end-to-end …" — the one word carrying the meaning was the
              // word that got cut. Every test still passed: `find.text` matches
              // the Text's `data` and the geometry assertion measures the box,
              // while ellipsis happens at paint. Only looking at the pixels
              // caught it.
              //
              // Full width also buys back the island's name, so the `compact`
              // variant that existed to drop it has no caller left.
              const SizedBox(height: 8),
              const MediaConfidentialityChip(),
            ],
          ),
        ),
      ),
    );
  }

  void _answer(BuildContext context, WidgetRef ref) {
    // A call is already open. `pushCallOn` would return silently (its latch is
    // held for the whole duration of the live call, since `router.push`
    // resolves only on pop), so stopping the ring first would make the banner
    // vanish with no call and no message — the user presses the primary button
    // and the call disappears. Reachable, not theoretical: this banner is
    // mounted above the Navigator and draws over the live call screen.
    //
    // The ring is deliberately LEFT RINGING. Answering is refused, not the
    // invitation — the user can still Ignore it, or end the current call and
    // answer within the remaining ring window.
    if (isInLiveCall) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("You're already in a call")));
      return;
    }
    // A call route is open but the call is OVER — the user is sitting on "Call
    // ended" and has not pressed Close. Refusing here would be the same dead
    // button, for a call that no longer exists. Pop the spent screen and let
    // the answer through: `pushCallOn`'s latch is released BY that pop (its
    // `router.push` future resolves there), so the push has to wait a turn.
    if (isCallRouteOpen) {
      final router = ref.read(routerProvider);
      if (router.canPop()) router.pop();
      Future<void>.delayed(Duration.zero, () {
        ref.read(incomingRingProvider.notifier).stopRinging();
        pushCallOn(router, invite.channelId);
      });
      return;
    }
    // Ring stopped FIRST, synchronously, before navigating: pushCall awaits
    // until the call route pops, so clearing afterwards would leave the banner
    // painted over the live call for its whole duration.
    ref.read(incomingRingProvider.notifier).stopRinging();
    // Router from the PROVIDER, not from context: this widget lives above the
    // Router in `MaterialApp.router`'s builder, so `context.push` would throw
    // `No GoRouter found in context` (cage-match #139 — the feature's primary
    // button was dead until `ring_overlay_test.dart` pressed it).
    pushCallOn(ref.read(routerProvider), invite.channelId);
  }
}
