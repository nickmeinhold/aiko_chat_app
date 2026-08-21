import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../chat/application/chat_providers.dart';
import '../domain/call_invite.dart';

/// Announces that a call ended — as an OBLIGATION, not an instant.
///
/// Three cage-match findings collapsed into this one object, because they were
/// one bug wearing three coats: the hangup was only expressible in the single
/// moment `CallScreen.dispose()` ran, and if the world was not ready in that
/// moment the intent was discarded with a debugPrint.
///
///   - **The ack had not arrived** (Carnot + Tesla, independently). `sendMessage`
///     returns as soon as the optimistic row is committed, deliberately, so the
///     ring never gates navigation. So the invitation has no server ULID yet —
///     and `reply_to` needs one. The path that broke is the *fastest and most
///     human*: place the call, realise it is a misdial, back out immediately.
///     Exactly the case where you most want the peer's phone to stop.
///   - **The captured repository had died.** The screen did
///     `ref.read(chatRepositoryProvider.future)` in `initState` and spoke only to
///     that instance in `dispose`. It is `autoDispose` and rebuilds on reconnect,
///     subscription-set change and `seedOpenedDm` — the same read-not-watch trap
///     #139 spent rounds on. A long unanswered ring is precisely when a mobile
///     socket is most likely to have swapped it underneath.
///   - **A hangup racing its own invite.** Handled on the receiving side by
///     [RingController]'s `_ended` memory; this is its sending-side twin.
///
/// So the screen no longer performs the announcement. It hands over an
/// obligation and unmounts; this object — app-scoped, outliving any screen and
/// any repository instance — discharges it, reading the CURRENT repository at
/// the moment it sends. Same shape as the device-unregister debt in the push
/// pairing, and for the same reason: an intent that only exists during one
/// instant is an intent you will lose.
class CallEndAnnouncer {
  CallEndAnnouncer(this._ref, {Duration? ackWait})
    : _ackWait = ackWait ?? kCallRingDuration;

  final Ref _ref;

  /// How long to wait for the invitation's ack before giving up.
  ///
  /// NOT A TUNED NUMBER: it is [kCallRingDuration], because after that the
  /// peer's ring has expired on its own and there is nothing left to stop. A
  /// bound derived from the thing it is bounding, rather than picked.
  final Duration _ackWait;

  /// The announcements still in flight — awaited by tests, never by production.
  /// A caller that awaited this would put a network round trip back inside a
  /// widget teardown, which is what this object exists to remove.
  @visibleForTesting
  final List<Future<void>> settling = [];

  /// Say that the call opened by [inviteId] in [channelId] has ended.
  ///
  /// Returns immediately. Safe to call from `dispose()` — it captures nothing
  /// that is being torn down.
  void announce({required String channelId, required String inviteId}) {
    // SNAPSHOT WHO WE ARE, not just what we are ending (cage-match round 2,
    // Tesla). This object was built to outlive the screen and therefore outlives
    // the USER: /call/:channelId is not a logged-out zone, so when the session
    // ends the router ejects the route, dispose hands over the obligation, and
    // the pinned announcer would discharge it under whoever is next. The human
    // path is not exotic — misdial, hang up, switch island because the call felt
    // wrong — and that is well inside a 30s ack wait. RingController already
    // treats identity as a non-reversible key and clears on swap; this is its
    // sending-side twin and needs the same rule.
    final identity = _identity();
    late final Future<void> f;
    f = _announce(channelId, inviteId, identity).whenComplete(() {
      // Completed obligations must not accumulate: this object is pinned for the
      // app's lifetime, so an ever-growing list would retain every hangup's
      // closure graph forever (cage-match round 2, Carnot).
      settling.remove(f);
    });
    settling.add(f);
  }

  /// Who this device is, right now, as far as an announcement is concerned: the
  /// signed-in account AND the island it is signed in to. Either changing makes
  /// a pending hangup somebody else's business.
  (String?, String) _identity() => (
    _ref.read(currentUserProvider)?.userId,
    _ref.read(configProvider).httpBaseUrl,
  );

  Future<void> _announce(
    String channelId,
    String inviteId,
    (String?, String) identity,
  ) async {
    try {
      final serverId = await _awaitServerId(inviteId);
      if (_identity() != identity) {
        // The session or the island changed while we waited. The invitation
        // belonged to a user we are no longer, on a gateway we may no longer be
        // talking to — announcing now would sign a hangup as somebody else.
        debugPrint(
          'CallEndAnnouncer: identity changed while waiting for the ack — '
          'abandoning the hangup for $inviteId.',
        );
        return;
      }
      if (serverId == null) {
        // The invitation was never acked within the whole ring window, so it
        // almost certainly never reached the peer either — there is no ring to
        // stop, and a `reply_to` the island cannot resolve would sink the entire
        // message (`no_reply_target`, verified live).
        debugPrint(
          'CallEndAnnouncer: $inviteId was never acked within $_ackWait — no '
          'hangup announced; nothing should be ringing.',
        );
        return;
      }
      // Read the repository FRESH, at send time. Capturing one at hangup time
      // would reintroduce the mortal-instance bug this object exists to fix.
      final repo = await _ref.read(chatRepositoryProvider.future);
      await repo.sendMessage(channelId, kCallEndBody, replyToId: serverId);
    } catch (e) {
      debugPrint('CallEndAnnouncer: could not announce the hangup: $e');
    }
  }

  /// Poll for the island's ULID for [inviteId] until it lands or [_ackWait]
  /// elapses.
  ///
  /// Polling rather than watching, deliberately: the alternative is a stream
  /// subscription that must be cancelled by something, and "something that must
  /// remember to clean up" is what the screen already failed to be. A loop that
  /// ends by itself has no teardown to get wrong.
  Future<String?> _awaitServerId(String inviteId) async {
    final deadline = DateTime.now().add(_ackWait);
    while (DateTime.now().isBefore(deadline)) {
      final repo = await _ref.read(chatRepositoryProvider.future);
      final id = await repo.serverIdFor(inviteId);
      if (id != null) return id;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final repo = await _ref.read(chatRepositoryProvider.future);
    return repo.serverIdFor(inviteId);
  }
}

/// PINNED IN `main()`, and that is not decoration. Providers auto-dispose by
/// default in Riverpod 3, so an announcer read only by `CallScreen` would be
/// created by that screen and disposed WITH it — killing the in-flight
/// announcement along with the widget that handed it over, which is precisely
/// the bug this class exists to fix. A fix for a mortal capture that is itself
/// mortal is not a fix. `main()` watches it for the app's lifetime, the same way
/// it pins `pushPairingProvider`.
final callEndAnnouncerProvider = Provider<CallEndAnnouncer>(
  (ref) => CallEndAnnouncer(ref, ackWait: ref.read(callEndAckWaitProvider)),
);

/// How long an announcement waits for the invitation's ack.
///
/// A provider ONLY so tests can shorten it and still build the announcer through
/// its real wiring. Standing up a hand-made `Ref` instead was worse than
/// inconvenient: it was a shim that got disposed by an ordinary invalidate, so
/// the announcement failed through the class's own swallow and the test passed
/// for the wrong reason (cage-match round 2 — twice, in fact).
final callEndAckWaitProvider = Provider<Duration>((_) => kCallRingDuration);
