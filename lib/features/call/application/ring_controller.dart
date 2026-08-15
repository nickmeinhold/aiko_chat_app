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
    final repoAsync = ref.watch(chatRepositoryProvider);
    repoAsync.whenData((repo) {
      _sub = repo.inboundMessages.listen(_consider);
    });
    ref.onDispose(() {
      _sub?.cancel();
      _expiry?.cancel();
      _expiry = null;
      _live = null; // logout must not leave a ring armed for the next user.
    });
    // Re-publish the live invitation across the rebuild, but only while it is
    // still within its ring window — an expiry timer that fired during the
    // rebuild gap must not be resurrected.
    return _live;
  }

  void _consider(Message m) {
    // Read, not watch: this runs in a stream callback, not a build. Each is read
    // at the moment the invite lands, which is the moment the decision is made —
    // a block or mute applied one second before the call must be honoured.
    final me = ref.read(currentUserProvider)?.userId;
    if (me == null) return; // logged out mid-flight — nobody to ring.
    final invite = admitRing(
      m,
      meUserId: me,
      blockedUserIds: ref.read(blockedUserIdsProvider),
      conversationMuted: _isMuted(m),
      now: DateTime.now().toUtc(),
    );
    if (invite == null) return;
    // At-least-once delivery means the SAME invitation can arrive twice (live +
    // history dual-delivery, reconnect replay). Re-arming the timer on a
    // re-delivery would silently extend the ring past `kCallRingDuration` from
    // the last echo rather than the first (cage-match #139, Tesla). An identical
    // invitation is therefore a no-op, not a refresh.
    if (invite == _live) return;
    // A DIFFERENT invite while already ringing REPLACES the first (last-wins) —
    // the most recent caller is the live one, and stacking rings has no sane UI.
    _expiry?.cancel();
    _expiry = Timer(kCallRingDuration, stopRinging);
    _live = invite;
    state = invite;
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
    _live = null; // cleared too, or the next rebuild would re-publish it.
    state = null;
  }
}
