import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../application/ring_controller.dart';
import '../application/system_call_providers.dart';
import '../domain/call_invite.dart';
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
/// ## THE JOIN IS GATED ON A VERIFIED INVITATION (Nick, 2026-09-15)
///
/// **The ring fires before proof; the MEDIA never does.** Three reviewer
/// families independently blocked PR #201 on the same property, and Tesla put
/// the decisive argument in one line: this tree already refuses to connect for
/// no mapping, a resolved-empty session and a live call, so *"refusing would
/// un-answer a ring we already committed to"* is a frame, not a constraint.
///
/// The VoIP payload is `{"c","k"}` and carries no signature, so a wake can be
/// fabricated by anyone able to send one — which is the island, and only the
/// island. Before the answer joined a room, that bought an unwanted ring. With
/// a join wired to it, it buys a CAMERA IN A ROOM: the island gains the power
/// to *initiate* a capture, where before it could only observe calls the user
/// chose to have. That escalation is what this gate removes.
///
/// So an answer joins only once [admitRing] has ADMITTED an invitation for the
/// same channel — the app's single trust decision, whose head refusal is
/// `unverifiedOrigin`, the signature check. No second gate is built here; this
/// waits for the existing one. The invitation arrives over the websocket, so on
/// a cold start it lands after the session does, and both waits are one wait.
///
/// **The deadline is DERIVED, not invented:** an answer is joinable for as long
/// as the invitation would still be ringing ([kInAppRingDuration]). Past that
/// there is no call left to join, and the system call is ended rather than left
/// showing a connection that will never arrive.
///
/// **The cost is real and was accepted rather than hidden:** answering can now
/// FAIL — a websocket that does not connect in time, or an invitation
/// `admitRing` refuses (muted, blocked, consent withheld), ends the call
/// instead of joining it. A refusal is the gate working. A slow network is the
/// price, and it is the price of the ring not being proof.
///
/// ## It is still a second admission PATH — what it is no longer is UNGATED
///
/// `NotificationTapChannel` argues, in writing, that a tapped call notification
/// must open the CONVERSATION and never navigate straight into a call — because
/// `admitRing` carries nine start-gate refusals (signature verification at the
/// head of them) and a handler that jumped into the room would be a second
/// admission path honouring none of them. **This class does exactly what that
/// comment forbids**, and the reason it is not the same decision is design 16
/// v2 §4:
///
/// > all nine refusals become post-hoc [under CallKit]... an invite with a
/// > forged or absent signature rings the handset — full-screen, through silent
/// > mode and DND — before anything verifies it.
///
/// A tap is a navigation choice made about a notification that already sat
/// there quietly. **An answer is a choice the user made about a full-screen ring
/// that has ALREADY fired**, un-gated, because iOS requires the report before
/// the delivery handler returns. Refusing to connect at this point does not
/// un-ring the phone; it renders as a call that cannot be answered, which is
/// the failure mode the ring increment deliberately avoided.
///
/// So the honest statement is not "this path is gated". It is: **the gate that
/// matters moved, and has not been built.** The recorded decision (2026-09-01,
/// design 16 v2's open questions) is that Swift verifies Ed25519 against the
/// device-local consented key set BEFORE reporting to CallKit — proof moving to
/// the layer that is awake, rather than later or to the island. The payload is
/// `{"c", "k"}` today and carries no signature, so that verification has
/// nothing to check yet, and every VoIP ring on this build is unverified at the
/// moment it fires. That is a property of the RING, not of this class, and it
/// is the thing to fix rather than a reason to make the answer refuse.
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

  /// How long a held answer may wait for its invitation to be admitted.
  Timer? _joinDeadline;

  /// The channel [_joinDeadline] belongs to.
  ///
  /// The timer alone is not enough, and the two-transition path that proves it
  /// is Carnot's (cage-match PR #201 round 2): with a bare `??=`, answer A arms
  /// the timer, answer B replaces `_answered` and is refused a timer because one
  /// already exists, then A's timer fires, sees the held channel is no longer
  /// A, returns — and leaves B held forever with no deadline at all. The
  /// unbounded hold this exists to bound, restored through the back door by the
  /// very guard that was added to bound it.
  String? _deadlineFor;

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
    _joinDeadline?.cancel();
    super.dispose();
  }

  /// Start the clock on a held answer — once PER CHANNEL.
  ///
  /// Two failure modes sit on either side of this and both are real:
  ///
  ///  * Re-arm on every call and the deadline never fires. `_tryJoin` is
  ///    re-entered on every auth AND ring transition, so unrelated traffic
  ///    pushes it out forever — an unbounded hold wearing a timer's coat.
  ///  * Arm only when no timer exists (a bare `??=`) and a SECOND answer
  ///    inherits the first one's timer, which then fires against a channel it
  ///    no longer matches and clears itself, leaving the second answer held
  ///    with no deadline at all.
  ///
  /// So the timer is keyed to the channel it belongs to: same channel, leave it
  /// running; different channel, the old one is void and this one starts now.
  void _armJoinDeadline(String channelId) {
    if (_deadlineFor == channelId && _joinDeadline != null) return;
    _joinDeadline?.cancel();
    _deadlineFor = channelId;
    _joinDeadline = Timer(kInAppRingDuration, () {
      _joinDeadline = null;
      _deadlineFor = null;
      if (_answered != channelId) return;
      // No admitted invitation inside the window the invitation itself would
      // have been ringing for. Nothing was sent, or `admitRing` refused it, or
      // the websocket never came back — all three are "there is no call to
      // join", and the honest render is the system call ending rather than a
      // connected call that never connects.
      _abandonHeldAnswer();
    });
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
        if (_answered == action.channelId) {
          _answered = null;
          _joinDeadline?.cancel();
          _joinDeadline = null;
        }
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
    // THE PARSED PARAMETER, NEVER A RECONSTRUCTED PATH STRING. `state.uri.path`
    // is percent-ENCODED and the id is not, so `'/call/$channelId'` compares two
    // different encodings and silently fails to match. Measured across five ids:
    // `dm:aaa:bbb` matches, `a b` renders `/call/a%20b` and does NOT, `é` renders
    // `/call/%C3%A9` and does not — while `pathParameters['channelId']` returns
    // the decoded id and matches in every case. Today's island ids are
    // `dm:<id>:<id>` so nothing is live; the miss is what matters, because it is
    // the system-UI hangup failing to leave the room with the camera still on,
    // reported by nothing.
    if (router.state.pathParameters['channelId'] != channelId) return;
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
    // THE VERIFIED INVITATION, or nothing. `incomingRingProvider` publishes only
    // what `admitRing` admitted, so reading it here REUSES the nine start-gate
    // refusals rather than re-deciding them — `unverifiedOrigin`, the signature
    // check, at the head of them.
    final admitted = ref.read(incomingRingProvider);
    if (admitted?.channelId != channelId) {
      // Not yet, or never. Hold, and let the deadline decide which — the
      // invitation is a websocket message and this is routinely a cold start.
      _armJoinDeadline(channelId);
      return;
    }
    _answered = null;
    _joinDeadline?.cancel();
    _joinDeadline = null;
    _deadlineFor = null;

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
    _joinDeadline?.cancel();
    _joinDeadline = null;
    _deadlineFor = null;
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
    // The ADMITTED invitation is the other release condition, and on a cold
    // start it is the later of the two: the session restores, the websocket
    // connects, the invitation arrives, `admitRing` runs, and only then is
    // there anything to join.
    ref.listen<CallInvite?>(incomingRingProvider, (_, _) => _tryJoin());
    return widget.child;
  }
}
