import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../chat/application/chat_providers.dart';
import '../../chat/data/chat_repository.dart' show ChatRepository;
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

  /// Invitations whose hangup has already been claimed by someone.
  ///
  /// ONE CALL, ONE END — and the reason is the same one that made `startCall`
  /// single-flight: `kCallEndBody` is a signed row in permanent history, so a
  /// second announcement is not a harmless retry, it is a duplicate fact.
  /// Idempotence here is what lets MORE THAN ONE owner be responsible for the
  /// hangup without coordinating: the call screen's teardown and the call's mint
  /// site can both demand it, and whichever runs first is the one that speaks.
  /// That is deliberately the opposite of a fence — the failure this replaced
  /// was an obligation with exactly one owner who was not always born.
  ///
  /// THE SECOND OWNER STARTS THE OBLIGATION; IT DOES NOT RETRY IT. Both owners
  /// fire in the same pop, so by the time the first has reached an `await` the
  /// second has already run and no-oped — a second striker that arrives before
  /// the first has struck is not a fallback (cage-match round 5, Tesla). The
  /// only thing the second owner is FOR is the case where the first was never
  /// born at all, which is exactly the bug it was added for. Retrying a failed
  /// attempt is the loop's job, in [_announce], where it can actually happen.
  ///
  /// Grows by one short string per call PLACED on this device, in a session.
  /// Named rather than bounded: unlike [settling], an entry retains no closure
  /// graph, and a device that placed enough calls to notice has other problems.
  ///
  /// A CLAIM IS RELEASED WHEN THE ATTEMPT ABANDONS, and that is what keeps the
  /// dual ownership honest. Claiming permanently on ENTRY would mean the first
  /// owner to speak also gets to fail silently on everyone's behalf: the screen's
  /// teardown claims, the announcement gives up (identity changed, never acked),
  /// and the mint site's `finally` — the whole point of which is to be a second
  /// owner — is turned into a no-op by the corpse of the first attempt
  /// (cage-match round 4, Tesla). So the set means "an announcement is in flight
  /// or has SUCCEEDED", never "someone once intended to".
  final Set<String> _claimed = {};

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
    if (!_claimed.add(inviteId)) return;
    // NOTHING BELOW MAY THROW, because the caller is `CallScreen.dispose` and a
    // throw there skips `super.dispose()` — a broken widget teardown, from the
    // one path that exists to make teardown safe. `_identity()` reads two
    // providers off a long-lived `Ref`, and a disposed `Ref` throws (the
    // fragility already tracked as #3349), so it sits inside the guard rather
    // than in front of it. The claim is released on that path too: a claim means
    // "in flight or succeeded", and an announcement that never started is
    // neither (cage-match round 6, Tesla).
    final (String?, String) identity;
    try {
      identity = _identity();
    } catch (e) {
      debugPrint('CallEndAnnouncer: could not read identity for $inviteId: $e');
      _claimed.remove(inviteId);
      return;
    }
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

  /// ONE OBLIGATION, RETRIED UNTIL THE RING WINDOW CLOSES.
  ///
  /// Three review rounds each added a guard here and each guard grew the next
  /// round's defect: dual owners, then idempotence, then unclaim-on-abandon.
  /// The contract was never actually written down, so it kept being approximated
  /// — *a hangup is announced exactly once, and an attempt that fails is tried
  /// again until there is nothing left to stop*. Retry belongs INSIDE the single
  /// obligation. Spreading it across two owners could never work: the mint site's
  /// `finally` and `CallScreen.dispose` fire in the same pop, so the "second
  /// striker" had already returned before the first reached its first `await`
  /// (cage-match round 5, Tesla).
  ///
  /// [_ackWait] bounds the WHOLE loop, not just the wait for an id — after it,
  /// the peer's ring has expired on its own and there is nothing left to still.
  Future<void> _announce(
    String channelId,
    String inviteId,
    (String?, String) identity,
  ) async {
    final deadline = DateTime.now().add(_ackWait);
    try {
      while (DateTime.now().isBefore(deadline)) {
        // Re-checked EVERY pass, not once at the top. The loop spans awaits, and
        // a liveness test does not survive an await — signing a hangup as
        // whoever is current would be worse than not sending one.
        if (_identity() != identity) {
          debugPrint(
            'CallEndAnnouncer: identity changed — abandoning the hangup for '
            '$inviteId.',
          );
          _claimed.remove(inviteId);
          return;
        }
        if (!DateTime.now().isBefore(deadline)) break;
        // ONE TRY AROUND THE WHOLE PASS, and the shape is the point. Three
        // rounds enumerated these exits in a COMMENT and then left one await
        // outside the guard each time: round 5 found a null send treated as
        // spoken, round 6 found a repository error fatal where a null retried,
        // round 7 found `sendMessage` itself outside the catch — so a live send
        // that THREW was a funeral while the same failure as a null was a
        // shrug. Prose enumerating exits does not enumerate exits. Every await
        // in the pass is inside this block, so the fatal paths are the ones
        // written below and there is nowhere else to fall out.
        //
        // EXITS, and there are exactly three:
        //   1. the send returns an id   -> spoken, done
        //   2. identity changed         -> abandon; it is not ours to say
        //   3. the deadline passed      -> abandon; the peer's ring expired
        try {
          // A SLICE, not the whole budget (cage-match round 7, Tesla). Bounding
          // the read by all remaining time meant one hung
          // `chatRepositoryProvider.future` consumed the entire obligation:
          // `timeout` does not cancel the original, so we stopped waiting on a
          // corpse and then left the graveyard instead of re-reading the
          // CURRENT provider a moment later. Reconnect, `seedOpenedDm` and a
          // subscription rebuild — the three deaths this object exists to
          // outlive — are exactly the cases that resolve on the next read.
          final left = deadline.difference(DateTime.now());
          final slice = left < _attemptSlice ? left : _attemptSlice;
          final repo = await _repositoryWithin(slice);
          if (repo != null) {
            final serverId = await repo.serverIdFor(inviteId);
            if (serverId != null) {
              // RE-CHECKED WITH THE REPOSITORY IN HAND. The pass began with an
              // identity check and then awaited twice; a liveness test does not
              // survive an await. Round 3 added exactly this guard and the
              // round-5 rewrite dropped it, unnoticed, because it had no test.
              // Snapshot A, obtain repository B, and the hangup is signed by
              // whoever is current: the callee will not stop (the caller no
              // longer matches) and permanent signed history grows a row from a
              // person who never placed the call.
              if (_identity() != identity) {
                debugPrint(
                  'CallEndAnnouncer: identity changed before signing — '
                  'abandoning the hangup for $inviteId.',
                );
                _claimed.remove(inviteId);
                return;
              }
              final sentId = await repo.sendMessage(
                channelId,
                kCallEndBody,
                replyToId: serverId,
              );
              if (sentId != null) return; // spoken; the claim stands.
              // NAMED COMPROMISE, found by a fix-interaction pass rather than a
              // reviewer: `sendMessage` fires the transport BEFORE it returns,
              // and its catch returns null. So a throw in that window yields
              // null with the frame ALREADY on the wire, and this retry sends a
              // second END — two signed rows for one hangup, in permanent
              // history. Kept deliberately, because the failures are not
              // symmetric: a duplicate end is inert at the receiver (`_ended`
              // holds a list, `stopRinging` is idempotent) while a MISSING end
              // rings a handset for thirty seconds at a room nobody is coming
              // to. Removing it properly needs a write-ahead attempt record,
              // not another guard here.
            }
          }
        } catch (e) {
          // "Not this millisecond", never "not this universe".
          debugPrint('CallEndAnnouncer: transient failure for $inviteId: $e');
        }
        await Future<void>.delayed(_retryCadence);
      }
      debugPrint(
        'CallEndAnnouncer: gave up on $inviteId after $_ackWait — the peer ring '
        'has expired on its own, so there is nothing left to stop.',
      );
      _claimed.remove(inviteId);
    } catch (e) {
      // Only an identity read can reach here now; everything inside the pass is
      // caught above.
      debugPrint('CallEndAnnouncer: could not announce the hangup: $e');
      _claimed.remove(inviteId);
    }
  }

  /// How long ONE attempt may wait for the repository before trying again.
  ///
  /// Short on purpose: the point is to come back and read the CURRENT provider,
  /// not to keep holding a future that may never complete.
  static const Duration _attemptSlice = Duration(seconds: 2);

  /// The gap between attempts. Slow enough not to spin, far shorter than any
  /// ring window.
  static const Duration _retryCadence = Duration(milliseconds: 250);

  /// The CURRENT repository, or null if it does not arrive within [left].
  ///
  /// Read fresh on every attempt rather than captured: capturing one at hangup
  /// time is the mortal-instance bug this object exists to fix.
  Future<ChatRepository?> _repositoryWithin(Duration left) async {
    try {
      return await _ref.read(chatRepositoryProvider.future).timeout(left);
    } on TimeoutException {
      return null;
    }
  }
}

/// Watched in `main()` so this object's lifetime is intentional, not incidental.
///
/// CORRECTING TWO FABRICATIONS that stood here through eight review rounds and
/// four model families (round 8, Tesla). This comment claimed providers
/// "auto-dispose by default in Riverpod 3" — they do not; every builder in
/// riverpod 3.3.2 declares `bool isAutoDispose = false`, so a plain `Provider`
/// lives as long as its container and the announcer was never mortal. And it
/// cited `pushPairingProvider` as the precedent for pinning: no such provider
/// exists anywhere in this repo. Both were invented to justify a decision that
/// is fine on its own terms, and neither had a reader-side falsifier — which is
/// exactly why nobody checked.
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
