/// "Is this device ringing right now" — one app-wide fact, one owner (#2808).
///
/// The ring listens to [ChatRepository.inboundMessages] (cross-channel, because
/// a call must reach you in a DM you are not looking at), funnels every message
/// through [admitRing] — the single trust decision — and holds the admitted
/// invitation for [kCallRingDuration] or until the user answers or declines.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_providers.dart';
import '../../chat/application/mute_controller.dart';
import '../../chat/domain/channel.dart';
import '../../chat/domain/message.dart';
import '../../moderation/application/moderation_controller.dart';
import '../domain/call_invite.dart';

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

  /// Invitations already shown and finished with — answered, ignored, or
  /// expired. Keyed on the signed [CallInvite.inviteId].
  ///
  /// WHAT REACHES HERE IS NOT WHAT THE TRANSPORT SENDS, and an earlier version
  /// of this comment got that wrong: it justified this map by "live + history
  /// dual delivery, reconnect drain", which are precisely the deliveries
  /// [ChatRepository] already collapses one layer below. `_announceInbound`
  /// fires only when the cache reports `inserted` — a FIRST insert of that
  /// server ULID — so a re-delivery of one message never reaches `_consider` at
  /// all. Measured, with a positive control: a repeated emit announced once, a
  /// genuinely new one announced again.
  ///
  /// The case that DOES reach here is a caller RETRY. The same signed
  /// `clientMsgId` re-sent gets a NEW server ULID from the island, so it is a
  /// first insert, it is announced, and it carries an `inviteId` this device may
  /// already have dealt with. Suppressing only against `_live` is not enough —
  /// `stopRinging()` clears `_live`, so a retry landing after the user pressed
  /// Ignore would ring all over again. "Currently ringing" and "already dealt
  /// with" are different questions and need different memory.
  ///
  /// Pinned by `a caller RETRY of a dismissed invitation does not ring again`,
  /// which varies the two ids independently — the only shape that can fail.
  ///
  /// Bounded: an invitation is only ringable for [kCallInviteFreshness], so ids
  /// older than that can never be admitted again and are dropped. This set can
  /// therefore only hold the invitations of the last few seconds.
  final Map<String, DateTime> _settled = {};

  /// Calls whose END we have seen, keyed on the signed server id the hangup
  /// named. Value is when we saw it, for the same bounded forgetting as
  /// [_settled].
  ///
  /// AN END CAN ARRIVE BEFORE ITS OWN INVITE, and without this it was discarded
  /// (cage-match, Tesla + Maxwell). Delivery here is at-least-once and locally
  /// out of order — this file already says so, and `_settled` exists because
  /// `_live` was not memory enough. An unmatched end is that same bug inverted:
  /// a signed "this call is dead" with nowhere to live until the invitation is
  /// admitted, by which point the stop has already been thrown away and the bell
  /// rings for a corpse. Push makes it likelier rather than rarer: the island
  /// wakes a handset on the INVITE body only, so a cold start processes the
  /// invitation first by construction and the end is an ordinary afterthought.
  ///
  /// A LIST per target, not one slot. Keying `_ended[targetServerMsgId] = end`
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
  final Map<String, List<({CallEnd end, DateTime at})>> _ended = {};

  /// The user this ring state belongs to; see the identity guard in [build].
  String? _identity;

  /// Channel ids the island reported as DMs (`GET /v1/dm`). Refreshed on every
  /// build from the watched provider — see [build].
  Set<String> _dmIds = const {};

  void _forget(DateTime now) {
    _settled.removeWhere(
      (_, at) => now.difference(at) > kCallInviteFreshness * 2,
    );
    // An end is only useful while its invitation could still be ADMITTED, and
    // admission is capped by freshness. Same bound, same reason: this can only
    // ever hold the last few seconds of calls.
    for (final ends in _ended.values) {
      ends.removeWhere((e) => now.difference(e.at) > kCallInviteFreshness * 2);
    }
    _ended.removeWhere((_, ends) => ends.isEmpty);
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
        kCallRingDuration - DateTime.now().toUtc().difference(live.startedAt);
    if (left <= Duration.zero) {
      _settle(live);
      return null;
    }
    _expiry ??= Timer(left, stopRinging);
    return live;
  }

  /// Record an invitation as dealt with. See [_settled].
  void _settle(CallInvite invite) {
    _settled[invite.inviteId] = DateTime.now().toUtc();
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
      _settled.clear();
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
    final end = admitCallEnd(m, meUserId: me);
    if (end != null) {
      (_ended[end.targetServerMsgId] ??= []).add((end: end, at: now));
      final live = _live;
      if (live != null && endsInvite(end, live)) stopRinging();
      return;
    }
    final invite = admitRing(
      m,
      meUserId: me,
      blockedUserIds: ref.read(blockedUserIdsProvider),
      conversationMuted: _isMuted(m),
      isDm: _isDm(m),
      now: now,
    );
    if (invite == null) return;
    // Already dead on arrival: its hangup got here first. Settle rather than
    // ring, so an at-least-once replay cannot ring either. Matched through the
    // SAME predicate the live path uses, so a remembered end can never suppress
    // a ring that an in-order end would not have.
    final owed = _ended[invite.serverMsgId];
    if (owed != null && owed.any((e) => endsInvite(e.end, invite))) {
      _settle(invite);
      return;
    }
    // At-least-once delivery means the SAME invitation can arrive again (live +
    // history dual delivery, reconnect replay). Two distinct failures if this is
    // not suppressed: re-arming the timer would extend the ring from the LAST
    // echo rather than the first (Tesla), and a replay after the user pressed
    // Ignore would ring again (Carnot). Both are answered by remembering the
    // signed invite id, not by comparing against whatever is ringing now.
    if (_settled.containsKey(invite.inviteId)) return;
    // The SAME invitation, already ringing. Nothing to do — and notably nothing
    // to UPGRADE: an earlier round grew a branch here that re-published `_live`
    // when a replay carried a server id the first sighting lacked. That state is
    // now unrepresentable ([CallInvite.serverMsgId] is non-nullable and
    // `admitRing` refuses a message without one), so the branch defended nothing
    // and cost a HIGH review finding for a bug it made look possible.
    if (invite == _live) return;
    // A DIFFERENT invite while already ringing REPLACES the first (last-wins) —
    // the most recent caller is the live one, and stacking rings has no sane UI.
    // The DISPLACED invitation is settled on the way out: replacement is a third
    // state, neither "ringing" nor "dealt with", and leaving it unrecorded let
    // A's at-least-once replay steal the banner back from B seconds later — so
    // Answer would have joined A's room while the user was looking at B
    // (cage-match #139 R4, Tesla).
    final displaced = _live;
    if (displaced != null) _settle(displaced);
    _expiry?.cancel();
    _expiry = null;
    _live = invite;
    // ONE equation of motion. Arming an absolute `kCallRingDuration` here while
    // `_republish` derived the remaining time from `startedAt` meant a ring's
    // length depended on whether a rebuild happened to occur: an invite signed
    // 9s ago rang 30s without a rebuild, ~21s with one (cage-match #139 R5,
    // Carnot). Both paths now go through `_republish`, so the deadline is a
    // function of the signed start time and nothing else.
    state = _republish();
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
  void stopRinging() {
    _expiry?.cancel();
    _expiry = null;
    final done = _live;
    // RECORDED as settled before clearing — otherwise the replay that arrives a
    // second after Ignore finds no `_live` to match and rings again.
    if (done != null) _settle(done);
    _live = null; // cleared too, or the next rebuild would re-publish it.
    state = null;
  }
}
