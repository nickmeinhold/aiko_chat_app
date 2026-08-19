/// The incoming-call ring (#2808) — an app-wide banner above every route.
///
/// Mounted in `MaterialApp.router`'s `builder`, ABOVE the Navigator, because a
/// call must reach you wherever you are: reading another conversation, in
/// Settings, anywhere. A ring rendered inside a route would only ring on that
/// route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../application/ring_controller.dart';
import '../domain/call_invite.dart';
import 'call_screen.dart' show pushCallOn;

/// Wraps [child] with the ring banner. A no-op (zero layout cost, no overlay)
/// whenever nothing is ringing.
class RingOverlay extends ConsumerWidget {
  const RingOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          child: Row(
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
        ),
      ),
    );
  }

  void _answer(BuildContext context, WidgetRef ref) {
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
