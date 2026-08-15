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

  @override
  CallInvite? build() {
    // The repo is async and rebuilds (reconnect, subscription-set change). Each
    // rebuild re-subscribes; the previous subscription is cancelled first so a
    // rebuilt repo cannot leave two listeners racing to ring for one invite.
    final repoAsync = ref.watch(chatRepositoryProvider);
    repoAsync.whenData((repo) {
      _sub?.cancel();
      _sub = repo.inboundMessages.listen(_consider);
    });
    ref.onDispose(() {
      _sub?.cancel();
      _expiry?.cancel();
    });
    return null;
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
    // A second invite while already ringing REPLACES the first (last-wins) — the
    // most recent caller is the live one, and stacking rings has no sane UI.
    _expiry?.cancel();
    _expiry = Timer(kCallRingDuration, stopRinging);
    state = invite;
  }

  /// A DM is silenced by EITHER cause — the conversation muted, or the person
  /// muted — mirroring `channelUnreadCountProvider`'s two mute targets. Both are
  /// checked here rather than folded into one, because muting a person and
  /// muting a room are different intentions that happen to share an outcome.
  bool _isMuted(Message m) =>
      ref.read(mutedChannelIdsProvider).contains(m.channelId) ||
      ref.read(mutedUserIdsProvider).contains(m.sender.userId);

  /// Stop ringing — answered, declined, or expired. Idempotent.
  void stopRinging() {
    _expiry?.cancel();
    _expiry = null;
    state = null;
  }
}
