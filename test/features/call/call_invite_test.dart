import 'dart:typed_data';

import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ring's admission door (#2808). A ring is the highest-privilege message in
/// the app — it lights up a device and offers to turn on the camera — so every
/// refusal it makes gets its own test, and the sentinel that will live in
/// permanent signed history gets a golden.
void main() {
  const me = 'me-key-opaque';
  const robin = 'robin-key-opaque';
  final now = DateTime.utc(2026, 8, 15, 13, 30);

  // TWO DISTINCT KEYS, because the allowlist tests below are about telling one
  // signer from another. A fixture where every message carries the same key
  // cannot distinguish "the allowlist matched THIS key" from "the allowlist
  // matched ANY key" — the exact shape that made the drain-ordering test void
  // (two token strings that could not collide).
  final residentKey = Uint8List(32)..[0] = 7;
  final strangerKey = Uint8List(32)..[0] = 9;

  OriginEnvelope signedAt(DateTime t, {Uint8List? key}) => OriginEnvelope(
    keyVersion: 1,
    rawPublicKey: key ?? Uint8List(32),
    clientMsgId: 'm1',
    signedAtMs: t.millisecondsSinceEpoch,
    sig: Uint8List(64),
  );

  Message invite({
    String from = robin,
    String channelId = 'dm:aaa:bbb',
    String body = kCallInviteBody,
    Duration age = const Duration(seconds: 1),
    bool? cryptoValid = true,
    bool withOrigin = true,
    SenderKind kind = SenderKind.human,
    Uint8List? key,
    bool hasAccount = true,
  }) => Message(
    clientTempId: 'm1',
    // DELIBERATELY DIFFERENT from clientTempId, and a REAL canonical ULID. The
    // gateway's reply_to is an FK onto messages.id, so the end must name this
    // one — and a fixture using the same string for both could not tell a
    // correct binding from the wire bug. `SRV-m1` did force them apart but is a
    // value no island could mint, so it proved the binding while exercising an
    // impossible id (this repo asserts canonical ULID case elsewhere).
    id: '01M0GS7FDWBVQ31950B1PTV2DW',
    channelId: channelId,
    sender: MessageSender(
      userId: hasAccount ? from : null,
      kind: kind,
      label: 'Robin',
    ),
    body: body,
    // Deliberately SKEWED away from the signed time: every freshness
    // assertion below must be reading `origin.signedAtMs`, not this. If a
    // regression re-keys freshness to `createdAt`, these tests fail.
    createdAt: now.subtract(const Duration(days: 7)),
    origin: withOrigin ? signedAt(now.subtract(age), key: key) : null,
    originCryptoValid: cryptoValid,
    deliveryState: DeliveryState.sent,
  );

  /// A hangup naming [target], parameterised the same way [invite] is so the
  /// symmetry tests can vary sender kind and signing key.
  Message callEnd({
    String from = robin,
    SenderKind kind = SenderKind.human,
    Uint8List? key,
    String target = '01M0GS7FDWBVQ31950B1PTV2DW',
  }) => Message(
    clientTempId: 'end1',
    id: '01M0GS7FDWBVQ31950B1PTV2DX',
    channelId: 'dm:aaa:bbb',
    sender: MessageSender(userId: from, kind: kind, label: 'Robin'),
    body: kCallEndBody,
    replyToId: target,
    createdAt: now,
    origin: signedAt(now, key: key),
    originCryptoValid: true,
    deliveryState: DeliveryState.sent,
  );

  CallInvite? admit(
    Message m, {
    Set<String> blocked = const {},
    Set<String> allowedKeys = const {},
    bool muted = false,
    bool isDm = true,
  }) => admitRing(
    m,
    meUserId: me,
    blockedUserIds: blocked,
    ringAllowedKeys: allowedKeys,
    conversationMuted: muted,
    isDm: isDm,
    now: now,
  );

  group('the pinned sentinel', () {
    // GOLDEN. This string is signed and written to permanent island history, so
    // it is a ONE-WAY DOOR: a change is a v2 with a compatibility branch, never
    // an edit. If this test fails, you are about to fork the wire — stop.
    test('is byte-for-byte what a peer will verify forever', () {
      expect(kCallInviteBody, 'aiko:call/1 · 📞 started a call');
    });

    test(
      'matches exactly — a sentinel with anything appended is NOT an invite',
      () {
        // A startsWith/contains test would let anyone ring you by typing the
        // sentinel with a word after it, and would make every quotation ring.
        expect(isCallInviteBody(kCallInviteBody), isTrue);
        expect(isCallInviteBody('$kCallInviteBody and now you ring'), isFalse);
        expect(
          isCallInviteBody('look: aiko:call/1 · 📞 started a call'),
          isFalse,
        );
        expect(isCallInviteBody(''), isFalse);
      },
    );
  });

  group('admits', () {
    test(
      'a fresh invite from a peer in an unmuted, unblocked conversation',
      () {
        final got = admit(invite());
        expect(got, isNotNull);
        expect(got!.channelId, 'dm:aaa:bbb');
        expect(got.from.userId, robin);
        expect(got.startedAt, now.subtract(const Duration(seconds: 1)));
      },
    );

    test('an invite exactly AT the freshness boundary', () {
      expect(admit(invite(age: kCallInviteFreshness)), isNotNull);
    });
  });

  group('refuses', () {
    test('an ordinary message', () {
      expect(admit(invite(body: 'hey, call me?')), isNull);
    });

    test('my own invite echoing back through the inbound path', () {
      // The caller's own send returns down the same stream. Ringing yourself is
      // the degenerate FIRST case, not an edge case.
      expect(admit(invite(from: me)), isNull);
    });

    test('an UNSIGNED message — the refusal the whole design rests on', () {
      // Cage-match #139 (Carnot + Tesla, independently): the original admitRing
      // read body/sender/time and never looked at `origin` at all, so the entire
      // "the signature covers the body, therefore unforgeable" argument was
      // unenforced. An island — or anything that can write a member-visible body
      // — could forge the highest-privilege act in the app.
      expect(admit(invite(withOrigin: false, cryptoValid: null)), isNull);
    });

    test('a message whose signature FAILED verification', () {
      expect(admit(invite(cryptoValid: false)), isNull);
    });

    test('a message not yet verified (null verdict) — fail CLOSED', () {
      // A missed ring is recoverable; a forged one impersonates a person to get
      // you into a room. `true` is the only admitting value.
      expect(admit(invite(cryptoValid: null)), isNull);
    });

    test('a NON-DM channel — one human must not ring a whole community', () {
      // The sentinel is deliberately human-readable so old clients degrade
      // gracefully — which means any human can TYPE it. Refusing bots unplugged
      // only one horn of that megaphone (cage-match #139, Tesla).
      expect(admit(invite(), isDm: false), isNull);
      expect(admit(invite(), isDm: true), isNotNull);
    });

    test('DM-ness is NOT re-derived from the channel id', () {
      // LIVE-VERIFIED against the real island: `POST /v1/dm` returns
      // channel_id `01M02Y4QS94QRRQ3658BZAB0PG` — a bare ULID. The `dm:` prefix
      // lives on `channels.aiko_channel`, a column the app never receives. An
      // earlier gate tested `channelId.startsWith('dm:')` and would therefore
      // have refused EVERY real DM. A realistic ULID channel id must admit.
      expect(
        admit(invite(channelId: '01M02Y4QS94QRRQ3658BZAB0PG')),
        isNotNull,
        reason: 'a real DM channel id is a ULID, not a dm:-prefixed string',
      );
    });

    test('a stale SIGNED time, even with a fresh server timestamp', () {
      // The island writes createdAt, so keying freshness to it would let the
      // island resurrect a genuine week-old invitation by re-stamping it
      // (cage-match #139, Tesla). signedAtMs is inside the signature.
      final resurrected = Message(
        clientTempId: 'm1',
        id: 'm1',
        channelId: 'dm:aaa:bbb',
        sender: const MessageSender(
          userId: robin,
          kind: SenderKind.human,
          label: 'Robin',
        ),
        body: kCallInviteBody,
        createdAt: now, // island says "just now"
        origin: signedAt(now.subtract(const Duration(days: 7))), // truth
        originCryptoValid: true,
        deliveryState: DeliveryState.sent,
      );
      expect(admit(resurrected), isNull);
    });

    test(
      'every NON-HUMAN sender — the refusal a user could not make themselves',
      () {
        // Bus actors are unblockable by island design (NULL sender_user_id is
        // always visible; claude-tasks#27). Without this, @@armbot posting the
        // sentinel in #general rings every member and no block or mute stops it.
        // Enumerated rather than spot-checked: `!= human` must hold for the WHOLE
        // non-human set, and a new SenderKind added later inherits the refusal.
        //
        // WHAT THIS DOES NOT CURRENTLY STOP, measured on the live island
        // 2026-08-26 — and the reason this test is a TRIPWIRE, not just a guard.
        // The deployed gateway does not report a sender's real kind. It reports
        // `"human"` for ANY sender holding an account, unconditionally:
        //
        //     if sender_user is not None: return "human"
        //     if channel.kind in ("llm","robot"): return channel.kind
        //     return "actor"
        //
        // So `kind` answers "did the sender have an account?", never "is the
        // sender a person" — and the clause above fires only on the `actor` arm,
        // which is exactly the bus-actor case named above. An agent that simply
        // HOLDS an account is admitted, and one did: `Dreamfinder`, its own
        // account and Ed25519 key, rang a real handset through this path.
        //
        // The gateway's unreleased source replaces that hardcode with the
        // account's true kind ("never a hardcoded 'human'", island #3096). On the
        // day it deploys, this test stops describing a bus actor and starts
        // refusing a resident Nick asked to be called by — a working capability
        // regressing, in a repo that did not change. If this test is what broke,
        // read claude-tasks#3448 BEFORE weakening it: the `actor` refusal must
        // survive; only the account-holding case is in question.
        for (final kind in SenderKind.values.where(
          (k) => k != SenderKind.human,
        )) {
          expect(
            admit(invite(kind: kind)),
            isNull,
            reason: 'a $kind must not ring',
          );
        }
      },
    );

    test('a blocked sender', () {
      expect(admit(invite(), blocked: {robin}), isNull);
    });

    test('a muted conversation', () {
      // Mute is attention-scoped and a ring is the loudest attention there is.
      expect(admit(invite(), muted: true), isNull);
    });

    test('a stale invite — history replay must not ring the backlog', () {
      expect(
        admit(invite(age: kCallInviteFreshness + const Duration(seconds: 1))),
        isNull,
      );
      expect(admit(invite(age: const Duration(hours: 3))), isNull);
    });

    test('an invite stamped in the FUTURE by a skewed clock', () {
      // Negative age is not "very fresh" — it is unreadable, and admitting it
      // would let a bad clock ring forever. `age > freshness` alone admits this.
      expect(admit(invite(age: const Duration(seconds: -60))), isNull);
    });
  });

  group('consented ringers — the allowlist widening (claude-tasks#3448)', () {
    // The gate this widens does not mean what its name says on the live island:
    // the gateway reports "human" for ANY account-holding sender, so `kind` only
    // ever refuses `actor`, the accountless bus participant. When the gateway
    // starts reporting true kinds (island #3096) a resident agent Nick asked to
    // be called by would be refused. These tests pin the widening that has to
    // land first, and — more importantly — pin what it must NOT loosen.
    String mk(Uint8List k) => encodeMultikey(k);

    test('an allowlisted key rings even though the island says it is not a person', () {
      final admitted = admit(
        invite(kind: SenderKind.llm, key: residentKey),
        allowedKeys: {mk(residentKey)},
      );
      expect(admitted, isNotNull);
    });

    test('a DIFFERENT key does not ride in on someone else\'s consent', () {
      // The allowlist is NON-EMPTY and holds the resident's key; the caller
      // signs with the stranger's. A test with an empty allowlist here would
      // pass for the wrong reason — it would only prove "empty refuses".
      expect(
        admit(
          invite(kind: SenderKind.llm, key: strangerKey),
          allowedKeys: {mk(residentKey)},
        ),
        isNull,
      );
    });

    test('consent is keyed on the KEY, not the account — a relabelled sender gains nothing', () {
      // `sender.userId`/`label` are server-supplied and OUTSIDE signingBytes, so
      // an island can rewrite them. Same allowlisted USER, stranger's key.
      expect(
        admit(
          invite(from: robin, kind: SenderKind.robot, key: strangerKey),
          allowedKeys: {mk(residentKey), robin},
        ),
        isNull,
        reason: 'putting a user id in the allowlist must never admit anyone',
      );
    });

    test('an allowlisted key with NO account is still refused — consent must stay withdrawable', () {
      // An accountless ringer cannot be blocked or muted, so allowlisting one
      // would mint exactly the unblockable ringer the `actor` refusal exists to
      // prevent. Consent you cannot withdraw is not consent.
      expect(
        admit(
          invite(kind: SenderKind.actor, key: residentKey, hasAccount: false),
          allowedKeys: {mk(residentKey)},
        ),
        isNull,
      );
    });

    test('the allowlist widens ONE gate — it is not a bypass', () {
      final allowed = {mk(residentKey)};
      Message resident() => invite(kind: SenderKind.llm, key: residentKey);
      // Each of these would admit if the allowlist short-circuited the rest.
      expect(admit(resident(), allowedKeys: allowed, blocked: {robin}), isNull,
          reason: 'blocked');
      expect(admit(resident(), allowedKeys: allowed, muted: true), isNull,
          reason: 'muted');
      expect(admit(resident(), allowedKeys: allowed, isDm: false), isNull,
          reason: 'not a DM');
      expect(
        admit(
          invite(kind: SenderKind.llm, key: residentKey, age: const Duration(minutes: 5)),
          allowedKeys: allowed,
        ),
        isNull,
        reason: 'stale',
      );
    });

    test('an UNVERIFIED signature never rings, consent or not', () {
      // The whole allowlist rests on the key being authentic: without this,
      // anyone could paste a resident's PUBLIC key — which is public — and ring.
      //
      // Scoped honestly. An earlier version of this test claimed to pin the
      // ORDER of the crypto check against the kind gate, and was VOID: both
      // orders return null, just at different lines, so `isNull` cannot tell
      // them apart. Reversing them was tried and every test still passed. What
      // is real, and RED-proven by deleting the crypto check entirely, is that
      // an unverified envelope never produces a ring no matter what consent
      // says. The ordering in `admitRing` is defence for a future refactor, not
      // a property this test establishes.
      for (final valid in [null, false]) {
        expect(
          admit(
            invite(kind: SenderKind.llm, key: residentKey, cryptoValid: valid),
            allowedKeys: {mk(residentKey)},
          ),
          isNull,
          reason: 'originCryptoValid=$valid must never reach the allowlist',
        );
      }
    });

    test('an EMPTY allowlist preserves the old behaviour for every non-human kind', () {
      for (final kind in SenderKind.values.where((k) => k != SenderKind.human)) {
        expect(admit(invite(kind: kind, key: residentKey)), isNull,
            reason: 'a $kind must not ring with no consent recorded');
      }
    });

    test('a consented ringer can also HANG UP — start and stop share one gate', () {
      // Carnot (HIGH) and Tesla found this independently: the kind clause lived
      // in `_isCallEndShape`, so widening `admitRing` alone made the STOP gate
      // colder than the START gate. An allowlisted resident could wake the
      // handset and then not silence it — the ring ran its full 30 seconds after
      // the caller had already hung up. A protocol whose start and stop have
      // different admission rules is not a protocol, it is two.
      final allowed = {mk(residentKey)};
      final ended = admitCallEnd(
        callEnd(kind: SenderKind.llm, key: residentKey),
        meUserId: me,
        ringAllowedKeys: allowed,
      );
      expect(ended, isNotNull, reason: 'the consented caller must be able to stop its own ring');
    });

    test('an UNCONSENTED non-human still cannot hang up', () {
      // The widening is symmetric, not a hole: without consent the stop gate
      // refuses exactly as the start gate does.
      expect(
        admitCallEnd(
          callEnd(kind: SenderKind.llm, key: strangerKey),
          meUserId: me,
          ringAllowedKeys: {mk(residentKey)},
        ),
        isNull,
      );
    });

    test('a human still rings without appearing on any allowlist', () {
      expect(admit(invite(key: strangerKey)), isNotNull);
    });
  });

  group('the two clocks are different numbers', () {
    // Conflating the staleness gate with the ring duration is how you ring for a
    // call that already ended (Nick, 2026-08-15). Pin that they are distinct.
    test('staleness gate is 10s; ring duration is longer', () {
      expect(kCallInviteFreshness, const Duration(seconds: 10));
      expect(kCallRingDuration, greaterThan(kCallInviteFreshness));
    });
  });

  group('the hangup — admitCallEnd', () {
    /// The invitation currently ringing, as `admitRing` would have produced it.
    final live = admit(invite())!;

    Message end({
      String from = robin,
      String? replyTo = '01M0GS7FDWBVQ31950B1PTV2DW',
      String channelId = 'dm:aaa:bbb',
      String body = kCallEndBody,
      bool? cryptoValid = true,
      bool withOrigin = true,
    }) => Message(
      clientTempId: 'e1',
      id: 'e1',
      channelId: channelId,
      sender: MessageSender(
        userId: from,
        kind: SenderKind.human,
        label: 'Robin',
      ),
      body: body,
      replyToId: replyTo,
      createdAt: now,
      origin: withOrigin ? signedAt(now) : null,
      originCryptoValid: cryptoValid,
      deliveryState: DeliveryState.sent,
    );

    /// The two doors together, which is how production uses them: judge the
    /// message, then match it to a ring. A test that only exercised one would
    /// miss the class the round-2 finding lived in — a memory whose key was
    /// weaker than the live path's.
    bool stops(Message m, {CallInvite? ringing}) {
      final end = admitCallEnd(m, meUserId: me, ringAllowedKeys: const {});
      return end != null && endsInvite(end, ringing ?? live);
    }

    test('the END sentinel is pinned — it is signed, permanent history', () {
      // A golden, for the same reason the invite has one: this string is inside
      // signatures the moment it is first sent, so changing it is a v2 with a
      // compatibility branch, never an edit.
      expect(kCallEndBody, 'aiko:call/1 · 📞 ended the call');
    });

    test('the caller hanging up stops the ring', () {
      expect(stops(end()), isTrue);
    });

    test('an ordinary message does not stop a ring', () {
      expect(stops(end(body: 'ok bye')), isFalse);
    });

    test(
      'an exact match only — a sentinel with a word after it is a remark',
      () {
        expect(stops(end(body: '$kCallEndBody now')), isFalse);
      },
    );

    test(
      'an end is judged WITHOUT reference to what is ringing — so one that '
      'overtakes its invitation can be remembered under the same clauses',
      () {
        // The round-2 shape: the gate used to take `live` and answer a single
        // fused question, so the out-of-order memory had to invent its own,
        // weaker, key. Split, both consumers run identical clauses.
        final judged = admitCallEnd(end(), meUserId: me, ringAllowedKeys: const {});
        expect(judged, isNotNull);
        expect(judged!.targetServerMsgId, '01M0GS7FDWBVQ31950B1PTV2DW');
        expect(judged.fromUserId, robin);
        expect(judged.channelId, 'dm:aaa:bbb');
      },
    );

    test('an end with NO AUTHOR is refused — "only the caller may end it" is '
        'unanswerable without one', () {
      final anon = Message(
        clientTempId: 'e1',
        id: 'e1',
        channelId: 'dm:aaa:bbb',
        sender: const MessageSender(kind: SenderKind.human, label: 'ghost'),
        body: kCallEndBody,
        replyToId: '01M0GS7FDWBVQ31950B1PTV2DW',
        createdAt: now,
        origin: signedAt(now),
        originCryptoValid: true,
        deliveryState: DeliveryState.sent,
      );
      expect(admitCallEnd(anon, meUserId: me, ringAllowedKeys: const {}), isNull);
    });

    test('a NON-HUMAN end is refused, mirroring admitRing', () {
      final robot = Message(
        clientTempId: 'e1',
        id: 'e1',
        channelId: 'dm:aaa:bbb',
        sender: const MessageSender(userId: robin, kind: SenderKind.robot),
        body: kCallEndBody,
        replyToId: '01M0GS7FDWBVQ31950B1PTV2DW',
        createdAt: now,
        origin: signedAt(now),
        originCryptoValid: true,
        deliveryState: DeliveryState.sent,
      );
      expect(admitCallEnd(robot, meUserId: me, ringAllowedKeys: const {}), isNull);
    });

    test(
      'an UNVERIFIED end keeps ringing — fail closed means KEEP RINGING',
      () {
        // The asymmetry with admitRing, stated as a test: an unverified START
        // must not light a camera, and an unverified STOP must not silence a
        // genuine call. Both refusals preserve the ring.
        expect(stops(end(cryptoValid: null)), isFalse);
        expect(stops(end(cryptoValid: false)), isFalse);
        expect(stops(end(withOrigin: false, cryptoValid: true)), isFalse);
      },
    );

    test('a THIRD PARTY cannot silence your ring', () {
      expect(stops(end(from: 'someone-else')), isFalse);
    });

    test('my own end does not stop my own ring', () {
      expect(stops(end(from: me)), isFalse);
    });

    test('the end must name the SERVER id — a client_msg_id is a frame the '
        'gateway REFUSES outright', () {
      // Found live, not by review: `reply_to` is an FK onto `messages.id`, so a
      // frame carrying a client_msg_id there comes back `no_reply_target` and
      // the hangup never leaves the device — silently, because announcing it is
      // best-effort. Both ids are opaque 26-char strings, so nothing but the
      // real island could tell them apart.
      expect(stops(end(replyTo: 'm1')), isFalse);
      expect(stops(end(replyTo: '01M0GS7FDWBVQ31950B1PTV2DW')), isTrue);
    });

    test('an end for a DIFFERENT call does not stop this one', () {
      // The double-call race: hang up, ring again immediately, and the first
      // end must not reach through and kill the second ring. The signed replyTo
      // is what makes the end about ONE call.
      expect(stops(end(replyTo: 'some-other-invite')), isFalse);
      expect(stops(end(replyTo: null)), isFalse);
    });

    test('an end in a different channel does not stop this ring', () {
      expect(stops(end(channelId: 'dm:ccc:ddd')), isFalse);
    });
  });
}
