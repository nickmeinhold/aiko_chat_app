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
import '../../chat/domain/message.dart';
import '../../moderation/application/moderation_controller.dart';
import '../domain/call_invite.dart';

/// The invitation currently ringing, or null.
///
/// `autoDispose` deliberately NOT used: the ring must survive the teardown of
/// whatever screen happened to be on top when the call arrived. It is torn down
/// with the repository (logout), which is the correct lifetime — a ring that
/// outlived a logout would ring for a conversation the next user cannot open.
final incomingRingProvider =
    NotifierProvider<RingController, CallInvite?>(RingController.new);

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
  /// Delivery is at-least-once (live + history dual delivery, reconnect drain),
  /// so the SAME invitation can arrive again inside its 10s freshness window.
  /// Suppressing only against `_live` was not enough: `stopRinging()` clears
  /// `_live`, so a replay landing seconds after the user pressed Ignore rang all
  /// over again (cage-match #139 R2, Carnot). "Currently ringing" and "already
  /// dealt with" are different questions and need different memory.
  ///
  /// Bounded: an invitation is only ringable for [kCallInviteFreshness], so ids
  /// older than that can never be admitted again and are dropped. This set can
  /// therefore only hold the invitations of the last few seconds.
  final Map<String, DateTime> _settled = {};

  /// The user this ring state belongs to; see the identity guard in [build].
  String? _identity;

  void _forget(DateTime now) => _settled.removeWhere(
      (_, at) => now.difference(at) > kCallInviteFreshness * 2);

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
      _expiry?.cancel();
      _expiry = null;
    }
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
    final now = DateTime.now().toUtc();
    final invite = admitRing(
      m,
      meUserId: me,
      blockedUserIds: ref.read(blockedUserIdsProvider),
      conversationMuted: _isMuted(m),
      now: now,
    );
    if (invite == null) return;
    // At-least-once delivery means the SAME invitation can arrive again (live +
    // history dual delivery, reconnect replay). Two distinct failures if this is
    // not suppressed: re-arming the timer would extend the ring from the LAST
    // echo rather than the first (Tesla), and a replay after the user pressed
    // Ignore would ring again (Carnot). Both are answered by remembering the
    // signed invite id, not by comparing against whatever is ringing now.
    if (invite == _live) return;
    _forget(now);
    if (_settled.containsKey(invite.inviteId)) return;
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
