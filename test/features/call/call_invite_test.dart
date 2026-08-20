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

  OriginEnvelope signedAt(DateTime t) => OriginEnvelope(
    keyVersion: 1,
    rawPublicKey: Uint8List(32),
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
  }) => Message(
    clientTempId: 'm1',
    id: 'm1',
    channelId: channelId,
    sender: MessageSender(userId: from, kind: kind, label: 'Robin'),
    body: body,
    // Deliberately SKEWED away from the signed time: every freshness
    // assertion below must be reading `origin.signedAtMs`, not this. If a
    // regression re-keys freshness to `createdAt`, these tests fail.
    createdAt: now.subtract(const Duration(days: 7)),
    origin: withOrigin ? signedAt(now.subtract(age)) : null,
    originCryptoValid: cryptoValid,
    deliveryState: DeliveryState.sent,
  );

  CallInvite? admit(
    Message m, {
    Set<String> blocked = const {},
    bool muted = false,
    bool isDm = true,
  }) => admitRing(
    m,
    meUserId: me,
    blockedUserIds: blocked,
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
      String? replyTo = 'm1',
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

    bool stops(Message m, {CallInvite? ringing}) =>
        admitCallEnd(m, live: ringing ?? live, meUserId: me);

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

    test('nothing ringing, nothing to stop', () {
      expect(admitCallEnd(end(), live: null, meUserId: me), isFalse);
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
