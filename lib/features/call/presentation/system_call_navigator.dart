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
/// **The hold ends on a CONDITION, not a clock** (claude-tasks#4440). A restore
/// that RESOLVES with no user — expired credentials, a session signed out on
/// another device — is a definite answer that this call can never be joined, and
/// the system call is ended there. That is the real event; a timeout would be a
/// constant standing in for it, and an unearned one (the same honesty design 16
/// v2 applies to `kPushDeliverySlack`).
///
/// What that leaves unbounded is narrower and named: a restore that never
/// resolves AT ALL — an island that is down, a request that hangs — holds the
/// answer, and the OS keeps showing a connected call until the user presses the
/// red button, which reaches [SystemCallActionKind.ended] and clears it.
/// An `AsyncError` restore is deliberately on the holding side of that line: a
/// failed round trip is "unknown", not "nobody is signed in".
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
    // THE THREE ANSWERS THE SESSION CAN GIVE, and they are three, not two. A
    // test that only flipped signed-out → signed-in found this: with the state
    // ALREADY resolved-empty when the answer lands (a stale push to a signed-out
    // app), no transition ever fires, so a decision made only in the auth
    // listener would hold that answer forever.
    final session = ref.read(authControllerProvider);
    if (session.value == null) {
      // Resolved, and nobody is signed in: `build()` awaits the restore, so
      // `AsyncData(null)` is a definite answer. This call can never be joined.
      if (session is AsyncData<AppUser?>) _abandonHeldAnswer();
      // Loading or error: the question is still open. `AsyncError` is
      // deliberately on this side — a failed round trip is "unknown", not
      // "nobody", and hanging up on it would refuse a call the user can take
      // the moment the network comes back.
      return;
    }
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

  /// There will never be a session to join this call with. End the system call
  /// rather than leave the OS showing a connected call with nothing behind it.
  void _abandonHeldAnswer() {
    final channelId = _answered;
    if (channelId == null) return;
    _answered = null;
    unawaited(
      ref.read(systemCallBridgeProvider)?.end(channelId) ?? Future.value(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The sign-in edge is what releases a held answer. Listened rather than
    // watched: this widget wraps the whole app and must not rebuild the router's
    // output on every auth republish.
    // Every auth transition re-asks the question; `_tryJoin` owns the answer, so
    // the same decision is reached whether the session resolved before the
    // answer arrived or after it.
    ref.listen<AsyncValue<AppUser?>>(
      authControllerProvider,
      (_, _) => _tryJoin(),
    );
    return widget.child;
  }
}
