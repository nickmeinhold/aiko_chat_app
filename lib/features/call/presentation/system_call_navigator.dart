import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../application/ring_controller.dart';
import '../application/system_call_providers.dart';
import '../data/system_call_bridge.dart';
import '../domain/call_invite.dart';
import '../domain/system_call_action.dart';
import '../application/ring_telemetry.dart';
import '../domain/answer_outcome.dart';
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

  /// Read per use rather than cached: this widget outlives provider rebuilds,
  /// and a captured logger would keep writing to a torn-down sink.
  RingTelemetry get _telemetry => ref.read(ringTelemetryProvider);

  /// The channel of an answered call we have not joined yet. See the class doc.
  String? _answered;

  /// Channels whose invitation [admitRing] ADMITTED, and when.
  ///
  /// **A MEMORY OF ADMISSION, NOT A READING OF THE LIVE RING** — and the
  /// difference is a call the user answered and got hung up on (Tesla, round 2,
  /// and it is the sharpest finding of the panel).
  ///
  /// `incomingRingProvider` is a DESTINATION: the one invitation ringing right
  /// now. Its null means two opposite things — *not yet* (cold start, the
  /// websocket is still in flight) and *already gone* (the in-app banner's
  /// window elapsed). The gate cannot tell those apart, and the second one is
  /// not hypothetical: **the in-app ring window and the CallKit ring are two
  /// different clocks, deliberately.** `RingOverlay` documents that an in-app
  /// expiry is not a decision about the system call, because CallKit answers to
  /// the island's ceiling. So the handset can still be ringing at T+40s with the
  /// banner long dead — and reading the live slot there would hold the answer,
  /// arm a second full window, and then END a call the user had answered.
  ///
  /// Latching the admission fixes that at the root: the proof is kept, not
  /// rented from a banner timer this code already says is the wrong clock.
  /// **The entry IS the admission, and its timer IS the lifetime** — there is
  /// no timestamp to compare against a clock. That is not only tidier: a
  /// wall-clock comparison is unreachable by `tester.pump`, so the expiry it
  /// claimed could not be tested at all, and an expiry no test can reach is an
  /// expiry nobody should believe in.
  final Map<String, Timer> _admitted = {};

  /// How long the held answer may wait for its invitation to be admitted.
  ///
  /// Always belongs to [_answered] when non-null, because both are written only
  /// by [_hold], [_consume] and [_release]. An earlier version carried a
  /// separate `_deadlineFor` key naming the channel the timer was for, and that
  /// key promptly drifted out of step with the timer it described — it was
  /// never cleared on a hangup (Kelvin, round 3). A field that must be kept in
  /// step with another field IS the coupling; deleting it is the fix.
  Timer? _joinDeadline;

  @override
  void initState() {
    super.initState();
    // Subscribed in `initState`, not in `build`: subscribing is what drains the
    // native side's held actions, and a subscription created in build would be
    // re-created on every rebuild — re-listening to a broadcast stream that has
    // already been drained.
    final bridge = ref.read(systemCallBridgeProvider);
    _sub = bridge?.actions.listen(_onAction);
    // SEED THE LATCH, because `ref.listen` fires on CHANGES only. An invitation
    // already ringing when this mounts — a hot restart, or a rebuild landing
    // mid-ring — would otherwise never be recorded, and the very next answer
    // would find no proof of an admission that had plainly happened. Caught by
    // the existing tests the moment the latch replaced the live read.
    _recordAdmission(ref.read(incomingRingProvider));
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final timer in _admitted.values) {
      timer.cancel();
    }
    _joinDeadline?.cancel();
    super.dispose();
  }

  void _onAction(SystemCallAction action) {
    // EVERY action, unconditionally, BEFORE the switch — and the "unconditional"
    // is the whole point. The `ended` arm below records itself only when it
    // ends an answer WE were holding, so a call the system ended before anyone
    // answered it (which is every failing run so far: 2026-09-20, the handset
    // rang, the call died ~5s later, and Dart's record of who killed it was
    // empty) passed through here in silence. The native side is the only party
    // that sees that end, and this stream is the only place it becomes
    // evidence.
    //
    // Cheap by construction: a handset receives a handful of these per call,
    // not per frame, so this cannot crowd the ring buffer it shares with the
    // events it exists to explain.
    _telemetry.systemCallAction(
      action.channelId,
      action.kind.name,
      origin: action.origin,
    );
    switch (action.kind) {
      case SystemCallActionKind.answered:
        _hold(action.channelId);
      case SystemCallActionKind.ended:
        // The native side has ALREADY ended this call, so the hold is dropped
        // without ending it again: the user answered and then hung up before
        // the session was ready, and joining now would open a call they have
        // already left.
        if (_answered == action.channelId) {
          _telemetry.answerResolved(
            action.channelId,
            AnswerOutcome.endedInSystemUi,
          );
          _consume();
        }
        _leaveIfOpen(action.channelId);
    }
  }

  // ---- ONE HOLD, AND EXACTLY TWO WAYS OUT OF IT ----
  //
  // **THIS SHAPE ANSWERS A REPEATED FINDING CLASS, not a bug.** Three
  // consecutive cage-match rounds each found a different instance of one
  // defect: SIX sites wrote `_answered`, and every one decided for itself
  // whether the system call it was dropping should be ended. Three got it
  // wrong, in three different ways — a displaced answer leaked its call
  // (Carnot), a session stuck in `AsyncLoading` held with no deadline at all
  // (Kelvin), and the deadline's ownership key drifted out of step with the
  // deadline (Kelvin). Patching the third would have been the fourth patch on
  // one invariant nobody had written down.
  //
  // So it is written down and made structural: **this navigator holds at most
  // one answered call, that hold always carries a deadline, and it ends in
  // exactly one of two ways.**
  //
  //   [_consume] — the answer BECAME a call. Drop it and end nothing: the
  //                system call IS the live call now.
  //   [_release] — we will not be joining. End the system call, so the OS is
  //                never left showing a connection that will not arrive.
  //
  // Every exit routes through one of those two. That is what makes a missing
  // disposal show up as a missing call rather than as nothing at all.

  /// Take an answer, releasing whatever it displaces.
  ///
  /// The deadline is armed HERE, at the moment of holding — not at the moment a
  /// join attempt fails. That placement fixes two findings at once: a session
  /// stuck in `AsyncLoading` never reached the old arming site and so held
  /// forever, and arming per-attempt made the clock resettable by unrelated
  /// provider traffic. Held once, clocked once.
  void _hold(String channelId) {
    _telemetry.answerHeld(channelId);
    final displaced = _answered;
    // CONSERVATION OF OWNERSHIP: a second answer does not silently forget the
    // first one's system call. Nothing this class stops holding is ever simply
    // dropped.
    if (displaced != null && displaced != channelId) {
      _telemetry.answerResolved(displaced, AnswerOutcome.displaced);
      _release(displaced);
    }
    _answered = channelId;
    _joinDeadline?.cancel();
    _joinDeadline = Timer(kInAppRingDuration, () {
      // No admitted invitation inside the window the invitation itself would
      // have been ringing for. Nothing was sent, or `admitRing` refused it, or
      // the websocket never came back — all three are "there is no call to
      // join", and the honest render is the system call ending rather than a
      // connected call that never connects.
      if (_answered == channelId) {
        _telemetry.answerResolved(channelId, AnswerOutcome.neverAdmitted);
        _release(channelId);
      }
    });
    _tryJoin();
  }

  /// Remember that [admitRing] admitted an invitation for this channel.
  void _recordAdmission(CallInvite? invite) {
    if (invite != null) {
      _admitted[invite.channelId]?.cancel();
      _admitted[invite.channelId] = Timer(
        kSystemCallRingTrust,
        () => _admitted.remove(invite.channelId),
      );
    }
    _tryJoin();
  }

  /// Was an invitation for this channel admitted recently enough to still name
  /// a call the handset could be ringing for?
  ///
  /// The bound is [kSystemCallRingTrust] — the SAME window the native side
  /// applies to an unanswered ring, pinned to it by
  /// `system_call_channel_contract_test.dart` rather than by a comment. Past it
  /// the native map has stopped believing in the ring too, so there is nothing
  /// left for an admission to be proof of.
  bool _wasAdmitted(String channelId) => _admitted.containsKey(channelId);

  /// The held answer became a call. Drop the hold; end nothing.
  void _consume() {
    _answered = null;
    _joinDeadline?.cancel();
    _joinDeadline = null;
  }

  /// We will not be joining [channelId]. End its system call.
  ///
  /// Safe for a channel that is not currently held — that is the displacement
  /// case — and a structural no-op at the native layer when no system call
  /// exists for it.
  void _release(String channelId) {
    if (_answered == channelId) _consume();
    unawaited(
      ref.read(systemCallBridgeProvider)?.end(channelId) ?? Future.value(),
    );
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
    // BOTH halves: the route, and the id. `pathParameters['channelId']` is set
    // on ANY route carrying that parameter, so on its own this is "pop whatever
    // is on top if it happens to name this channel". `/call/` is a literal
    // prefix that percent-encoding never touches, so adding it costs nothing
    // and restores the route identity the old string compare had by accident
    // (Tesla, round 2: right about encoding, wrong about which route).
    final state = router.state;
    if (!state.uri.path.startsWith('/call/')) return;
    if (state.pathParameters['channelId'] != channelId) return;
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
      // No bridge means no system call to end and no route to join into.
      _telemetry.answerResolved(channelId, AnswerOutcome.noBridge);
      _consume();
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
      if (session is AsyncData<AppUser?>) {
        _telemetry.answerResolved(channelId, AnswerOutcome.signedOut);
        _release(channelId);
      }
      // Loading or error: the question is still open. `AsyncError` is
      // deliberately on this side — a failed round trip is "unknown", not
      // "nobody", and hanging up on it would refuse a call the user can take
      // the moment the network comes back.
      return;
    }
    // THE VERIFIED INVITATION, or nothing. Only `admitRing` puts anything in
    // `_admitted`, so this REUSES the nine start-gate refusals rather than
    // re-deciding them — `unverifiedOrigin`, the signature check, at the head.
    if (!_wasAdmitted(channelId)) {
      // Not yet, or never. Hold, and let the deadline decide which — the
      // invitation is a websocket message and this is routinely a cold start.
      // The deadline is already running — it was armed when the answer was
      // held — so this is a plain "not yet", with nothing to arm or re-arm.
      return;
    }
    _consume();

    if (isInLiveCall) {
      _telemetry.answerResolved(channelId, AnswerOutcome.alreadyInLiveCall);
      // Two calls at once is a state neither CallKit (`maximumCallsPerCallGroup
      // = 1`) nor this app models. The in-app banner refuses the same way and
      // tells the user; here there is nobody to tell — the answer came from the
      // lock screen — so the honest render is the system call ending rather
      // than a connected call that silently goes nowhere.
      _release(channelId);
      return;
    }
    // The same invitation is very likely ALSO ringing in-app: the island wakes
    // the handset and the websocket delivers the invite, so a foregrounded app
    // gets both. Answering one must silence the other, or the banner paints over
    // the call it just opened for the rest of the ring window.
    ref
        .read(incomingRingProvider.notifier)
        .stopRinging(RingStopCause.answeredInSystemUi);
    // `inviteId` is deliberately not passed: it names an invitation OF OURS to
    // announce the end of, and this is the callee's side. `CallScreen` documents
    // null as the correct value for every way in but the caller's.
    _telemetry.answerResolved(channelId, AnswerOutcome.joined);
    unawaited(pushCallOn(ref.read(routerProvider), channelId));
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
    ref.listen<CallInvite?>(
      incomingRingProvider,
      (_, next) => _recordAdmission(next),
    );
    return widget.child;
  }
}
