import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../application/ring_controller.dart';
import '../application/system_call_providers.dart';
import '../domain/system_call_action.dart';
import 'call_screen.dart' show isInLiveCall, pushCallOn;

/// Turns an answered system call into a joined room (claude-tasks#4420).
///
/// **This is the half of the ring that makes it a call.** Until it existed the
/// handset rang full-screen from a dead process, the user swiped, and
/// `CXAnswerCallAction` fulfilled into nothing.
///
/// Mounted in `MaterialApp.router`'s `builder` beside [RingOverlay] and
/// [NotificationTapNavigator], and for the same reason all three are: the app
/// resumes on whatever route it was last on, and an answer has to be honoured
/// from any of them. It also has to be honoured from NO route — a VoIP push
/// relaunches a terminated app, so the mount point must be alive before the
/// first real screen is.
///
/// ## Why the answer is HELD rather than acted on
///
/// The gap this spans is not the router's, it is the SESSION's. Answering a
/// locked handset launches the app from dead: the engine boots, `main()` runs,
/// the session restore is a round trip, and only then is there a credential the
/// island will mint a room token against. The answer reliably arrives first. So
/// it waits here and is re-attempted on the sign-in edge.
///
/// **A held answer has no deadline, and that is a named compromise rather than
/// an oversight** (claude-tasks#4428). If the session never restores — expired
/// credentials, a user who signed out on another device — the OS keeps showing
/// a connected call that this app will never join. It is recoverable: the system
/// call UI's red button reaches [SystemCallActionKind.ended] and clears it. A
/// deadline would self-heal it, and a deadline is a constant this increment has
/// not earned a value for (the same honesty design 16 v2 applies to
/// `kPushDeliverySlack`).
class SystemCallNavigator extends ConsumerStatefulWidget {
  const SystemCallNavigator({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SystemCallNavigator> createState() =>
      _SystemCallNavigatorState();
}

class _SystemCallNavigatorState extends ConsumerState<SystemCallNavigator> {
  StreamSubscription<SystemCallAction>? _sub;

  /// The channel of an answered call we have not joined yet. See the class doc.
  String? _answered;

  @override
  void initState() {
    super.initState();
    // Subscribed in `initState`, not in `build`: subscribing is what drains the
    // native side's held actions, and a subscription created in build would be
    // re-created on every rebuild — re-listening to a broadcast stream that has
    // already been drained.
    final bridge = ref.read(systemCallBridgeProvider);
    _sub = bridge?.actions.listen(_onAction);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onAction(SystemCallAction action) {
    switch (action.kind) {
      case SystemCallActionKind.answered:
        _answered = action.channelId;
        _tryJoin();
      case SystemCallActionKind.ended:
        // Drop a held answer for the same call: the user answered and then hung
        // up before the session was ready, and joining now would open a call
        // they have already left.
        if (_answered == action.channelId) _answered = null;
        _leaveIfOpen(action.channelId);
    }
  }

  /// The user ended the call in the SYSTEM UI. On a locked handset that is the
  /// only control they have, so this is the only way out of a call answered
  /// there — without it the room stays joined after the red button.
  ///
  /// Popping the route is the whole teardown: `CallScreen.dispose` leaves the
  /// room, announces the end if we were the caller, and tells the native side
  /// the system call is over (a no-op here, since the native side is where this
  /// came from).
  void _leaveIfOpen(String channelId) {
    final router = ref.read(routerProvider);
    if (router.state.uri.path != '/call/$channelId') return;
    if (router.canPop()) router.pop();
  }

  /// Join, if everything a join needs is present. Called on the answer and again
  /// on every auth transition, because the two race on a cold start.
  void _tryJoin() {
    final channelId = _answered;
    if (channelId == null) return;
    final bridge = ref.read(systemCallBridgeProvider);
    // No bridge means calling is gated off in this build, in which case there is
    // no `/call/:id` route to push and no honest way to answer. Unreachable
    // today — the same gate stops the VoIP token being registered at all, so
    // nothing can ring — and belt-and-braces on purpose: the two gates protect
    // against different orders of a future edit.
    if (bridge == null) {
      _answered = null;
      return;
    }
    // Not signed in YET is the normal cold-start state, not a refusal: hold.
    if (ref.read(authControllerProvider).value == null) return;
    _answered = null;

    if (isInLiveCall) {
      // Two calls at once is a state neither CallKit (`maximumCallsPerCallGroup
      // = 1`) nor this app models. The in-app banner refuses the same way and
      // tells the user; here there is nobody to tell — the answer came from the
      // lock screen — so the honest render is the system call ending rather
      // than a connected call that silently goes nowhere.
      unawaited(bridge.end(channelId));
      return;
    }
    // The same invitation is very likely ALSO ringing in-app: the island wakes
    // the handset and the websocket delivers the invite, so a foregrounded app
    // gets both. Answering one must silence the other, or the banner paints over
    // the call it just opened for the rest of the ring window.
    ref.read(incomingRingProvider.notifier).stopRinging();
    // `inviteId` is deliberately not passed: it names an invitation OF OURS to
    // announce the end of, and this is the callee's side. `CallScreen` documents
    // null as the correct value for every way in but the caller's.
    unawaited(pushCallOn(ref.read(routerProvider), channelId));
  }

  @override
  Widget build(BuildContext context) {
    // The sign-in edge is what releases a held answer. Listened rather than
    // watched: this widget wraps the whole app and must not rebuild the router's
    // output on every auth republish.
    ref.listen<AsyncValue<AppUser?>>(authControllerProvider, (_, next) {
      if (next.value != null) _tryJoin();
    });
    return widget.child;
  }
}
