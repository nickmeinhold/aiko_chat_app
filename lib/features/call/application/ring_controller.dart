/// "Is this device ringing right now" — one app-wide fact, one owner (#2808).
///
/// The ring listens to [ChatRepository.inboundMessages] (cross-channel, because
/// a call must reach you in a DM you are not looking at), funnels every message
/// through [admitRing] — the single trust decision — and holds the admitted
/// invitation for [kInAppRingDuration] or until the user answers or declines.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_providers.dart';
import '../../chat/application/mute_controller.dart';
import '../../chat/domain/channel.dart';
import '../../chat/domain/message.dart';
import '../../moderation/application/moderation_controller.dart';
import '../data/system_call_bridge.dart' show kCallSpentTtl;
import '../domain/answer_outcome.dart';
import '../domain/call_invite.dart';
import '../domain/ring_consent.dart';
import '../domain/wake_age.dart';
import 'system_call_providers.dart';
import 'ring_telemetry.dart';
import 'ring_allowlist_provider.dart';

/// The invitation currently ringing, or null.
///
/// `autoDispose` deliberately NOT used: the ring must survive the teardown of
/// whatever screen happened to be on top when the call arrived. It is torn down
/// with the repository (logout), which is the correct lifetime — a ring that
/// outlived a logout would ring for a conversation the next user cannot open.
final incomingRingProvider = NotifierProvider<RingController, CallInvite?>(
  RingController.new,
);

class RingController extends Notifier<CallInvite?> {
  /// Read per-use rather than cached in a field: `build()` runs again on every
  /// `chatRepositoryProvider` rebuild, and a field captured there would outlive
  /// the container it came from.
  RingTelemetry get _telemetry => ref.read(ringTelemetryProvider);

  StreamSubscription<Message>? _sub;
  Timer? _expiry;

  /// The live invitation, held OUTSIDE Riverpod state.
  ///
  /// `build()` runs again on every `chatRepositoryProvider` rebuild — reconnect,
  /// subscription-set change, and (worst) `seedOpenedDm` invalidation, which a
  /// FIRST-EVER DM invite triggers on the callee. Returning `null` there meant
  /// the ring was destroyed mid-ring by the very case the feature exists for
  /// (cage-match #139 — Maxwell, Carnot and Tesla independently). Keeping the
  /// invitation in a field and re-publishing it makes a rebuild transparent to
  /// the user: a repo reconnecting is not the user ignoring a call.
  CallInvite? _live;

  /// Calls whose END we have seen, keyed on the signed server id the hangup
  /// named. Value is when we saw it, so it can be forgotten on the same bound
  /// as admission.
  ///
  /// AN END CAN ARRIVE BEFORE ITS OWN INVITE, and without this it was discarded
  /// (cage-match, Tesla + Maxwell). Delivery is at-least-once and locally OUT OF
  /// ORDER, and ordering is the part that survives: the repository collapses a
  /// re-delivery of one message, but it cannot make a stop arrive after the
  /// start it refers to. An unmatched end is the ring bug inverted:
  /// a signed "this call is dead" with nowhere to live until the invitation is
  /// admitted, by which point the stop has already been thrown away and the bell
  /// rings for a corpse. Push makes it likelier rather than rarer: the island
  /// wakes a handset on the INVITE body only, so a cold start processes the
  /// invitation first by construction and the end is an ordinary afterthought.
  ///
  /// A LIST per target, not one slot. Keying `_ended[targetIslandMsgId] = end`
  /// made the newest end for a ULID evict every earlier one, and the match
  /// clauses run at LOOKUP time — so a stop this device would ultimately refuse
  /// could still displace the genuine one that arrived before it. Order: the
  /// caller's end, then anyone else's end naming the same call, then the invite
  /// — and the bell rings for a corpse. The existing third-party test only ever
  /// plays the impostor FIRST, which is the ordering that cannot fail
  /// (cage-match round 3, Tesla). Today a stranger cannot learn a DM's ULID;
  /// `isDmChannelId` was deleted precisely BECAUSE channel-wide calls will put
  /// those ids in a shared room. A single "current" slot for a contested key is
  /// the same bug this file already fixed for `_live`.
  final Map<CallRef, List<({CallEnd end, DateTime at})>> _ended = {};

  /// Calls the SYSTEM call UI has already ended on this device, and when: the
  /// Dart half of the native spent records (design 22 v4.2): such a call
  /// cannot ring again here, which says nothing about whether it is live.
  ///
  /// A lock-screen decline can happen before Flutter exists. The invitation
  /// then arrives over the websocket a few seconds later, still inside
  /// [kCallInviteFreshness], and without this it rang as a banner for a call
  /// the user had already declined (Tesla, design 22 temper round 3). Fed by
  /// the navigator from every native `ended`, including the ones replayed on
  /// listen. Lives [kCallSpentTtl], the native record's own lifetime.
  final Map<CallRef, DateTime> _spent = {};

  /// The user this ring state belongs to; see the identity guard in [build].
  String? _identity;

  /// Every admitted invitation, as it is admitted — whether or not it rings.
  ///
  /// The ring STATE cannot carry this. It is the banner, and the banner's
  /// window runs from the signed start, so an invitation admitted late by its
  /// wake age (design 23: a locked answer, then Face ID) can be admitted after
  /// that window is spent. Published only as state, that admission was `null`
  /// and the answer it exists for never joined. Synchronous, so a listener
  /// sees an admission at the same moment it would have seen the state.
  Stream<CallInvite> get admissions => _admissions.stream;
  final _admissions = StreamController<CallInvite>.broadcast(sync: true);

  /// Admissions waiting on the native wake age, by call (design 23).
  ///
  /// The navigator's join deadline asks this before it releases an answer: an
  /// admission already in flight completes first (v3.1, requirement 3).
  Future<void>? wakeAdmissionFor(CallRef call) => _awaitingWake[call];
  final Map<CallRef, Future<void>> _awaitingWake = {};

  /// Arrival order of invitations, so last-wins follows ARRIVAL. An admission
  /// that waited on native can finish after a newer one that did not.
  int _arrivals = 0;
  int _liveArrival = 0;

  /// Channel ids the island reported as DMs (`GET /v1/dm`). Refreshed on every
  /// build from the watched provider — see [build].
  Set<String> _dmIds = const {};

  void _forget(DateTime now) {
    // An end is only useful while its invitation could still be ADMITTED, and
    // admission is capped by freshness. Same bound, same reason: this can only
    // ever hold the last few seconds of calls.
    for (final ends in _ended.values) {
      ends.removeWhere((e) => now.difference(e.at) > kCallInviteFreshness * 2);
    }
    _ended.removeWhere((_, ends) => ends.isEmpty);
    _spent.removeWhere((_, at) => now.difference(at) > kCallSpentTtl);
  }

  /// Re-publish the live invitation after a rebuild, re-arming its expiry with
  /// the time it has LEFT.
  ///
  /// The deadline is DERIVED from the signed [CallInvite.startedAt], never
  /// restarted — so any number of rebuilds inside one ring cannot extend it, and
  /// the timer that `onDispose` just cancelled is restored without resetting.
  /// A ring whose window already elapsed during the rebuild gap settles rather
  /// than returning from the dead.
  CallInvite? _republish() {
    final live = _live;
    if (live == null) return null;
    final left =
        kInAppRingDuration - DateTime.now().toUtc().difference(live.startedAt);
    if (left <= Duration.zero) {
      _settle(live);
      return null;
    }
    _expiry ??= Timer(left, () => stopRinging(RingStopCause.windowElapsed));
    return live;
  }

  /// This invitation is no longer the live one — answered, ignored, expired, or
  /// displaced by a newer caller.
  ///
  /// It used to ALSO record the id in a `_settled` set, so a later delivery of
  /// the same invitation could be suppressed. That set is gone. Reaching it
  /// required one signed `clientMsgId` to exist under two server ULIDs, and the
  /// island refuses that at the database: `UNIQUE(channel_id, client_msg_id)`,
  /// with a create path that returns the EXISTING row on a resend. Nothing else
  /// can deliver one invitation to `_consider` twice — `ChatRepository`
  /// announces only on a first insert of a server ULID (measured, with a
  /// positive control).
  ///
  /// It was kept for one round as cross-repo defence in depth, and that reading
  /// does not survive contact: the thing it defended against is not a peer
  /// changing its mind, it is a peer's UNIQUE constraint failing. Defending
  /// against that admits no limit — every foreign key and every documented
  /// contract would earn a client-side shadow. What the set did buy was three
  /// tests that could only be written by constructing a delivery the island
  /// cannot emit, and a false review finding, which is the going rate for
  /// machinery guarding a state nobody can produce.
  void _settle(CallInvite invite) {
    if (_live == invite) _live = null;
  }

  @override
  CallInvite? build() {
    // Cancel BEFORE branching on the new async value, not inside `whenData`: a
    // transition through loading/error would otherwise leave the OLD repo's
    // subscription attached while this provider rebuilt — and on LOGOUT that
    // stale stream feeds `_consider`, which reads the NEW `currentUserProvider`,
    // so the next user could be rung for the previous session's call
    // (cage-match #139, Carnot + Tesla — identity as a mutable key).
    _sub?.cancel();
    _sub = null;
    // Identity guard (cage-match #139 R2, Carnot): a logout that swaps the repo
    // WITHOUT disposing the ProviderScope would otherwise let `_live` be
    // re-published to the next identity. Identity is not a reversible state
    // variable — when it changes, everything the previous session was ringing
    // about is void.
    final me = ref.watch(currentUserProvider)?.userId;
    if (me != _identity) {
      _identity = me;
      _live = null;
      _ended.clear();
      _expiry?.cancel();
      _expiry = null;
    }
    // WATCHED, not read-on-demand. `dmsProvider` is autoDispose and `ref.read`
    // creates no dependency, so the ring was silently relying on some other
    // widget to keep it alive; if nothing did, it disposed, read back as
    // loading, and every DM invitation failed closed with no signal. Watching it
    // here both keeps it alive for this provider's lifetime and gives
    // `_consider` a resolved list to read synchronously.
    _dmIds = {
      for (final c in ref.watch(dmsProvider).value ?? const <Channel>[]) c.id,
    };
    final repoAsync = ref.watch(chatRepositoryProvider);
    repoAsync.whenData((repo) {
      _sub = repo.inboundMessages.listen(_consider);
    });
    // `onDispose` fires on every REBUILD, not only on teardown — so clearing
    // `_live` here killed the ring on exactly the rebuild this design exists to
    // survive, and the round-1 commit that claimed otherwise was wrong
    // (cage-match #139 R4, Tesla; pinned by `a live ring SURVIVES a repository
    // rebuild`). Only the subscription and the timer are dropped here; both are
    // re-created below, and the invitation itself outlives the rebuild.
    ref.onDispose(() {
      _sub?.cancel();
      _expiry?.cancel();
      _expiry = null;
    });
    return _republish();
  }

  void _consider(Message m) {
    // Read, not watch: this runs in a stream callback, not a build. Each is read
    // at the moment the invite lands, which is the moment the decision is made —
    // a block or mute applied one second before the call must be honoured.
    final me = ref.read(currentUserProvider)?.userId;
    if (me == null) return; // logged out mid-flight — nobody to ring.
    // THE STOP IS CONSIDERED FIRST, and on the same stream as the start, because
    // both are ordinary signed messages arriving through one door. Placing it
    // ahead of `admitRing` costs nothing (the two sentinels are disjoint) and
    // keeps the ordering obvious: an end can only ever be about a call that is
    // already ringing.
    final now = DateTime.now().toUtc();
    // PRUNE ON EVERY MESSAGE, not only after an invitation is admitted. Ends
    // never prune it otherwise, so a flood of signed stops with unique targets
    // would grow forever waiting for some future ring to remember to forget
    // (cage-match round 2, Tesla).
    _forget(now);
    // ONE DOOR. `admitCallEnd` judges the message; `endsInvite` matches it to a
    // ring. Both consumers below run the SAME clauses — the first version gave
    // the memory a weaker key than the live path, so a third party or another
    // channel could pre-poison a ring the live path would have refused.
    // SLICED ONCE, from the message's own channel, and handed to BOTH gates.
    // Two independent narrowings would be two chances to name a different room
    // — and the start/stop pair having different admission rules is the exact
    // defect rounds 6-7 found (an allowlisted caller that could wake the handset
    // and then not silence it). One slice, one scope, both doors.
    final consent = ref
        .read(ringConsentByChannelProvider.notifier)
        .consentIn(m.channelId);
    switch (admitCallEnd(m, meUserId: me, consent: consent)) {
      case CallEndAdmitted(:final end):
        (_ended[end.call] ??= []).add((end: end, at: now));
        final live = _live;
        if (live != null && endsInvite(end, live)) {
          stopRinging(RingStopCause.callerHungUp);
        }
        return;
      case CallEndRefused(:final reason):
        // A refused END falls THROUGH to the ring gate — it is not a rejection
        // of the message, only of one reading of it. `notAnEnd` is the ordinary
        // case for every invite that arrives. Only a refusal that actually
        // refused an attempt is worth a record, or the buffer fills with the
        // shape of every message that is not a hangup.
        if (reason.refusedAnAttempt) {
          _telemetry.endRefused(m.channelId, reason);
        }
    }
    _admit(m, me: me, consent: consent, now: now, arrival: ++_arrivals);
  }

  /// The ring gate, then everything that follows an admission.
  ///
  /// [receivedAt] is null on the first pass: freshness judged at [now], exactly
  /// as before design 23. Only an invitation refused `stale` asks the native
  /// side when it was woken, and that is not an optimisation of the rule but
  /// the rule itself: `receivedAt ≤ now`, so a wake can only ever rescue an
  /// invitation that `now` refuses. Everything else stays synchronous.
  void _admit(
    Message m, {
    required String me,
    required RingConsent consent,
    required DateTime now,
    required int arrival,
    DateTime? receivedAt,
    WakeAge? wake,
  }) {
    final decision = admitRing(
      m,
      meUserId: me,
      blockedUserIds: ref.read(blockedUserIdsProvider),
      consent: consent,
      conversationMuted: _isMuted(m),
      isDm: _isDm(m),
      now: now,
      receivedAt: receivedAt,
    );
    final CallInvite invite;
    switch (decision) {
      case RingRefused(reason: RingRefusal.stale)
          when wake == null && _askWake(m, me: me, arrival: arrival):
        // Every clause ahead of age has passed, signature first — so the call
        // the native side is asked about is the SIGNED body's. Not refused
        // yet: the answer decides.
        return;
      case RingRefused(:final reason, :final age):
        // THE LINE THAT DID NOT EXIST. Ten distinct refusals used to leave here
        // as one indistinguishable `null`, which is why learning that a real
        // push-woken ring had been refused for staleness took four hours and a
        // throwaway instrumentation branch (claude-tasks#3588, #3591).
        if (reason.refusedAnAttempt) {
          _telemetry.ringRefused(m.channelId, reason, age: age);
        }
        return;
      case RingAdmitted(invite: final admitted):
        invite = admitted;
    }
    // Already dead on arrival: its hangup got here first. Settle rather than
    // ring, so an at-least-once replay cannot ring either. Matched through the
    // SAME predicate the live path uses, so a remembered end can never suppress
    // a ring that an in-order end would not have.
    final owed = _ended[invite.call];
    if (owed != null && owed.any((e) => endsInvite(e.end, invite))) {
      // Dead on arrival: its hangup got here first, so it never rings. `_live`
      // cannot be this invitation — it is only being admitted now, so the end
      // that is already remembered arrived when something else (or nothing) was
      // live, and the live arm above handles that case. The comment here used to
      // argue exactly that while the code still called `_settle(invite)`, whose
      // only remaining act is `if (_live == invite)` — a check for the state the
      // comment denies (round 8, Tesla).
      //
      // ANNOUNCED rather than silent: the gate said YES and the handset stays
      // quiet, which is the one shape this whole change exists to make
      // impossible to mistake for "nobody called" (Tesla, #3591 cage-match).
      _telemetry.ringDeadOnArrival(invite.channelId);
      return;
    }
    // Already ended in the system call UI on this device — declined on the
    // lock screen before this invitation reached Dart. Same treatment as an
    // owed hangup: it never rings.
    if (_spent.containsKey(invite.call)) {
      _telemetry.ringDeadOnArrival(invite.channelId);
      return;
    }
    // The SAME invitation, already ringing. Nothing to do — and notably nothing
    // to UPGRADE: an earlier round grew a branch here that re-published `_live`
    // when a replay carried a server id the first sighting lacked. That state is
    // now unrepresentable ([CallInvite.islandMsgId] is non-nullable and
    // `admitRing` refuses a message without one), so the branch defended nothing
    // and cost a HIGH review finding for a bug it made look possible.
    if (invite == _live) {
      // At-least-once delivery re-delivering a live ring. Expected, so DEBUG —
      // but recorded, so a report can show the duplicate rate rather than
      // leaving a reader to infer it from a gap.
      _telemetry.ringDuplicate(invite.channelId);
      return;
    }
    // A DIFFERENT invite while already ringing REPLACES the first (last-wins) —
    // the most recent caller is the live one, and stacking rings has no sane UI.
    // The DISPLACED invitation is settled on the way out: replacement is a third
    // state, neither "ringing" nor "dealt with", and leaving it unrecorded let
    // A's at-least-once replay steal the banner back from B seconds later — so
    // Answer would have joined A's room while the user was looking at B
    // (cage-match #139 R4, Tesla).
    final displaced = _live;
    if (displaced != null && _liveArrival > arrival) {
      // A NEWER invitation is already live: this one waited on its wake age
      // and finished second. Arrival decides, so it does not take the banner —
      // but it was admitted, and an answer for it may be waiting.
      _telemetry.ringStarted(invite.channelId, now.difference(invite.startedAt));
      _admissions.add(invite);
      return;
    }
    if (displaced != null) _settle(displaced);
    _expiry?.cancel();
    _expiry = null;
    _live = invite;
    _liveArrival = arrival;
    // The POSITIVE CONTROL for the refusal lines above. Without an admitted
    // record, an empty report cannot distinguish "no call arrived" from
    // "logging is broken" — and an instrument that reads the same either way is
    // not an instrument.
    _telemetry.ringStarted(invite.channelId, now.difference(invite.startedAt));
    _admissions.add(invite);
    // ONE equation of motion. Arming an absolute `kInAppRingDuration` here while
    // `_republish` derived the remaining time from `startedAt` meant a ring's
    // length depended on whether a rebuild happened to occur: an invite signed
    // 9s ago rang 30s without a rebuild, ~21s with one (cage-match #139 R5,
    // Carnot). Both paths now go through `_republish`, so the deadline is a
    // function of the signed start time and nothing else.
    state = _republish();
  }

  /// Ask the native side when it was woken for this invitation's call, then
  /// judge again from that instant. Returns false when there is nothing to ask
  /// (no bridge, a v1 body), so the `stale` stands.
  ///
  /// ONE QUESTION PER CALL: a duplicate delivery while the first is waiting
  /// joins it rather than asking twice.
  bool _askWake(Message m, {required String me, required int arrival}) {
    final call = parseCallBody(m.body)?.call;
    final bridge = ref.read(systemCallBridgeProvider);
    if (call == null || bridge == null) return false;
    if (_awaitingWake.containsKey(call)) return true;
    late final Future<void> asking;
    asking = _wakeThenAdmit(m, call, me: me, arrival: arrival).whenComplete(() {
      if (identical(_awaitingWake[call], asking)) _awaitingWake.remove(call);
    });
    _awaitingWake[call] = asking;
    return true;
  }

  Future<void> _wakeThenAdmit(
    Message m,
    CallRef call, {
    required String me,
    required int arrival,
  }) async {
    // `unknown` is asked again, never judged at `now` (v3.1, requirement 1):
    // the oracle that has not synced is not the oracle saying no. Bounded by
    // the ring window from ARRIVAL: past it there is no answer left for this
    // admission to serve, since the join deadline is that long from an answer
    // that cannot precede the wake.
    final giveUp = DateTime.now().add(kInAppRingDuration);
    var attempts = 0;
    WakeAge wake;
    while (true) {
      attempts++;
      final bridge = ref.read(systemCallBridgeProvider);
      wake = bridge == null
          ? const WakeNotActionable()
          : await bridge.wakeAge(m.channelId, call);
      if (!ref.mounted) return;
      if (wake is! WakeUnknown || !DateTime.now().isBefore(giveUp)) break;
      await Future<void>.delayed(kWakeAgeRetry);
      if (!ref.mounted) return;
    }
    _telemetry.ringWakeAge(m.channelId, wake, attempts: attempts);
    // Identity is not a reversible state variable (see [build]): a logout
    // while native was answering voids the question.
    if (ref.read(currentUserProvider)?.userId != me) return;
    // `now` SAMPLED AT THE ANSWER, after the await, so the age native measured
    // and the instant it is subtracted from are one moment.
    final now = DateTime.now().toUtc();
    _forget(now);
    _admit(
      m,
      me: me,
      // SLICED AGAIN, on purpose: this is a new decision at a later moment, and
      // a block, mute or consent change made while the user reached for Face
      // ID must be honoured, as every clause here is re-read.
      consent: ref
          .read(ringConsentByChannelProvider.notifier)
          .consentIn(m.channelId),
      now: now,
      arrival: arrival,
      receivedAt: switch (wake) {
        Woke(:final age) => now.subtract(age),
        _ => null,
      },
      wake: wake,
    );
  }

  /// Is this message's channel a DM, per the app's OWN channel model?
  ///
  /// `dmsProvider` is the list the island returned from `GET /v1/dm`, so
  /// membership in it means `channels.kind == 'dm'` server-side. Deliberately
  /// NOT re-derived from the channel id — see the note on [admitRing]'s `isDm`
  /// refusal; the id is a bare ULID and the `dm:` prefix lives on a column the
  /// app never receives.
  ///
  /// Absent list → false (fail CLOSED for a ring). A message can only reach this
  /// client if its channel is in the repository's subscription set, which is
  /// built from these same lists, so an arriving message whose channel is
  /// unknown here is a genuinely anomalous state, not the ordinary first-contact
  /// case.
  bool _isDm(Message m) => _dmIds.contains(m.channelId);

  /// A DM is silenced by EITHER cause — the conversation muted, or the person
  /// muted — mirroring `channelUnreadCountProvider`'s two mute targets. Both are
  /// checked here rather than folded into one, because muting a person and
  /// muting a room are different intentions that happen to share an outcome.
  bool _isMuted(Message m) =>
      ref.read(mutedChannelIdsProvider).contains(m.channelId) ||
      ref.read(mutedUserIdsProvider).contains(m.sender.userId);

  /// Stop ringing — answered, ignored, or expired. Idempotent.
  ///
  /// [cause] is REQUIRED, and that is the point. This method had five callers
  /// and wrote nothing, so an admitted hangup silencing the ring and a ring
  /// that simply vanished produced identical evidence — which is how a call
  /// that rang, was admitted, and died 1.4 seconds later left exactly one log
  /// line behind it (2026-09-20). A default value would let the next caller
  /// re-create that silence by omission.
  /// Stop ringing [call], and only [call]. A no-op when a different call (or
  /// none) is ringing.
  ///
  /// The navigator joins a call it admitted by identity, so its stop has to
  /// name one too. Unkeyed, joining call A silenced call B whenever B had
  /// become the live banner in between (Tesla + Carnot, PR #210 v2 round 3).
  void stopRingingFor(CallRef call, RingStopCause cause) {
    if (_live?.call == call) stopRinging(cause);
  }

  /// The system call UI ended [call] on this device. Remember it so its
  /// invitation never rings late, and stop its banner if it is ringing now.
  void markSpent(CallRef call) {
    final now = DateTime.now().toUtc();
    _forget(now);
    _spent[call] = now;
    stopRingingFor(call, RingStopCause.endedInSystemUi);
  }

  void stopRinging(RingStopCause cause) {
    // Logged BEFORE the state is torn down, so the channel is still nameable.
    // A stop with nothing live is a real and ordinary case (idempotent), and
    // the null channel says exactly that rather than inventing an id.
    _telemetry.ringStopped(_live?.channelId, cause);
    _expiry?.cancel();
    _expiry = null;
    final done = _live;
    // A PRAYER OVER AN EMPTY ALTAR until round 7 (Tesla): this said the id was
    // "RECORDED as settled before clearing", which stopped being true when the
    // `_settled` set was deleted. `_settle` now only drops `_live`, and the
    // invariant it used to defend — a re-delivered invitation does not ring
    // again after Ignore — is enforced one layer below, where the repository
    // announces only on a first insert of a server ULID. Pinned by
    // `a re-delivered invitation does not ring again after Ignore`, which
    // asserts the INVARIANT against the real repository rather than this
    // mechanism, so the day that layer changes the test fails here.
    if (done != null) _settle(done);
    _live = null; // cleared too, or the next rebuild would re-publish it.
    state = null;
  }
}
