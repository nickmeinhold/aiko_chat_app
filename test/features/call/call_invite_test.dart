import 'dart:typed_data';

import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/call/domain/ring_consent.dart';
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

  /// Unwraps to the pre-#3591 shape ON PURPOSE. Every assertion below was
  /// written against `CallInvite?` and most were won in a cage-match; rewriting
  /// 30 of them to pattern-match would be churn at a trust boundary for no gain.
  /// The reasons get their own dedicated group instead — see
  /// "every refusal names itself".
  CallInvite? admit(
    Message m, {
    Set<String> blocked = const {},
    Set<String> allowedKeys = const {},
    bool muted = false,
    bool isDm = true,
  }) => switch (admitRing(
    m,
    meUserId: me,
    blockedUserIds: blocked,
    // Scoped to the message's OWN channel, so these cases keep testing what
    // they were written to test. The scoping property itself is exercised
    // separately, below.
    consent: RingConsent.inChannel(channelId: m.channelId, keys: allowedKeys),
    conversationMuted: muted,
    isDm: isDm,
    now: now,
  )) {
    RingAdmitted(:final invite) => invite,
    RingRefused() => null,
  };

  /// The refusal REASON for the same call — the thing that did not exist before.
  RingRefusal? refusal(
    Message m, {
    Set<String> blocked = const {},
    Set<String> allowedKeys = const {},
    bool muted = false,
    bool isDm = true,
  }) => switch (admitRing(
    m,
    meUserId: me,
    blockedUserIds: blocked,
    consent: RingConsent.inChannel(channelId: m.channelId, keys: allowedKeys),
    conversationMuted: muted,
    isDm: isDm,
    now: now,
  )) {
    RingAdmitted() => null,
    RingRefused(:final reason) => reason,
  };

  group('every refusal names itself (claude-tasks#3591)', () {
    // The gate answered "no" eleven ways with one indistinguishable `null`.
    // Learning WHICH way took four hours and a throwaway instrumentation
    // branch. One case per reason, so the vocabulary cannot rot silently.

    test('an ordinary message — the hot path', () {
      expect(refusal(invite(body: 'hello')), RingRefusal.notAnInvite);
    });

    test('my own invite, echoed back', () {
      expect(refusal(invite(from: me)), RingRefusal.ownInvite);
    });

    test('an unsigned invite', () {
      expect(refusal(invite(cryptoValid: null)), RingRefusal.unverifiedOrigin);
    });

    test('a carried-but-INVALID signature', () {
      expect(refusal(invite(cryptoValid: false)), RingRefusal.unverifiedOrigin);
    });

    test('a sender with no account', () {
      expect(refusal(invite(hasAccount: false)), RingRefusal.anonymousSender);
    });

    test('a non-human without this conversation\'s consent', () {
      expect(
        refusal(invite(kind: SenderKind.llm)),
        RingRefusal.consentWithheld,
      );
    });

    test('not a DM', () {
      expect(refusal(invite(), isDm: false), RingRefusal.notDirectMessage);
    });

    test('a blocked sender', () {
      expect(refusal(invite(), blocked: {robin}), RingRefusal.senderBlocked);
    });

    test('a muted conversation', () {
      expect(refusal(invite(), muted: true), RingRefusal.conversationMuted);
    });

    test('signed in the FUTURE by a skewed clock', () {
      expect(
        refusal(invite(age: const Duration(seconds: -5))),
        RingRefusal.clockSkew,
      );
    });

    test('older than the freshness window — THE ONE #3588 is waiting for', () {
      // A push-woken invite necessarily carries APNs delivery, a human
      // noticing, a cold start and a handshake inside its measured age. If this
      // reason appears in a report from a real suspended-phone wake, the
      // freshness gate is what refused the ring — the observation four hours of
      // instrumentation could not produce, because it was one `null` among ten.
      expect(
        refusal(invite(age: kCallInviteFreshness + const Duration(seconds: 1))),
        RingRefusal.stale,
      );
    });

    test('an UNSIGNED invite wearing MY OWN id names the SIGNATURE, not the '
        'echo — the forger does not get to pick the quieter reason', () {
      // Tesla, #3591 cage-match. `sender.userId` is server-supplied and outside
      // the signature, so an island can staple the recipient's own id onto an
      // unsigned invite. With the own-echo clause running first, that refused as
      // `ownInvite` — refusedAnAttempt:false, recorded nowhere — instead of
      // `unverifiedOrigin`. Both refuse, so admission never differed; what
      // differed is that the attacker chose which field to forge and thereby
      // chose the quieter diagnostic. This case did not exist in the first
      // census, which is how it got past it.
      expect(
        refusal(invite(from: me, cryptoValid: null)),
        RingRefusal.unverifiedOrigin,
      );
      expect(
        refusal(invite(from: me, cryptoValid: false)),
        RingRefusal.unverifiedOrigin,
      );
      // A genuine, properly signed self-echo still reads as one.
      expect(refusal(invite(from: me)), RingRefusal.ownInvite);
    });

    test('a fresh, signed, permitted invite is ADMITTED', () {
      // The positive control. Without it every test above would still pass if
      // `admitRing` refused unconditionally.
      expect(refusal(invite()), isNull);
      expect(admit(invite()), isNotNull);
    });

    test('a hangup with NO AUTHOR is a malformed STOP, not ordinary chatter', () {
      // Maxwell + Carnot + Tesla, independently, #3591 cage-match. The first
      // draft folded this into `notAnEnd(refusedAnAttempt: false)` alongside
      // every "hello" anyone types — so a malformed or hostile stop aimed at the
      // ring subsystem was STRUCTURALLY unloggable. That is this PR's own defect
      // reproduced one level down, and the first draft's test celebrated it as a
      // discovery instead of reading it as a conflation.
      final anon = Message(
        clientTempId: 'e1',
        id: '01M0GS7FDWBVQ31950B1PTV2DX',
        channelId: 'dm:aaa:bbb',
        sender: const MessageSender(userId: null, kind: SenderKind.human),
        body: kCallEndBody,
        replyToId: '01M0GS7FDWBVQ31950B1PTV2DW',
        createdAt: now,
        origin: signedAt(now),
        originCryptoValid: true,
        deliveryState: DeliveryState.sent,
      );
      expect(
        admitCallEnd(anon, meUserId: me, consent: RingConsent.none),
        isA<CallEndRefused>().having(
          (r) => r.reason,
          'reason',
          RingRefusal.endMissingAuthor,
        ),
      );
      expect(RingRefusal.endMissingAuthor.refusedAnAttempt, isTrue);
    });

    test(
      'a hangup NAMING NO CALL is observable — a bell may still be ringing',
      () {
        // The nastier of the two: it could never stop any ring, so the caller
        // believes the call is over while the callee's handset is still going.
        final noTarget = Message(
          clientTempId: 'e1',
          id: '01M0GS7FDWBVQ31950B1PTV2DX',
          channelId: 'dm:aaa:bbb',
          sender: const MessageSender(userId: robin, kind: SenderKind.human),
          body: kCallEndBody,
          createdAt: now,
          origin: signedAt(now),
          originCryptoValid: true,
          deliveryState: DeliveryState.sent,
        );
        expect(
          admitCallEnd(noTarget, meUserId: me, consent: RingConsent.none),
          isA<CallEndRefused>().having(
            (r) => r.reason,
            'reason',
            RingRefusal.endMissingTarget,
          ),
        );
        expect(RingRefusal.endMissingTarget.refusedAnAttempt, isTrue);
      },
    );

    test('each gate produces EXACTLY its own reasons — driven, not counted', () {
      // REPLACES a roster with a graph (Tesla, round 2, #3591). The first version
      // unioned three hand-maintained sets and asked whether every enum NAME
      // appeared somewhere. That check's outcome was independent of what the
      // gates do: a refactor retargeting a hangup at the wrong reason stayed
      // green, `originMissing` was filed "deliberately unreachable" while
      // `admitRing` could produce it from a fixture already in this file, and
      // nothing ever asked `admitCallEnd` a question at all. A test that cannot
      // go red for the failure it names is not a test.
      //
      // So: DRIVE both gates across a matrix of fixtures, collect what each one
      // actually emits, and compare against the `startGate`/`stopGate` flags the
      // enum declares. Now a reason that no gate produces, a reason produced by
      // the WRONG gate, and a flag that disagrees with reality all fail.
      final producedByStart = <RingRefusal>{};
      for (final m in [
        invite(body: 'hello'),
        invite(from: me),
        invite(cryptoValid: null),
        invite(cryptoValid: false),
        invite(withOrigin: false), // cryptoValid true, origin absent
        invite(hasAccount: false),
        invite(kind: SenderKind.llm),
        invite(),
      ]) {
        for (final blocked in [
          <String>{},
          {robin},
        ]) {
          for (final muted in [false, true]) {
            for (final isDm in [true, false]) {
              final r = refusal(m, blocked: blocked, muted: muted, isDm: isDm);
              if (r != null) producedByStart.add(r);
            }
          }
        }
      }
      producedByStart.add(refusal(invite(age: const Duration(seconds: -5)))!);
      // A signed, permitted invite carrying NO SERVER ID. Built by hand because
      // the `invite` fixture always mints one — which is precisely why the first
      // roster version could file `noServerId` as "deliberately unreachable" and
      // never be contradicted. Driving the gate forces the question.
      producedByStart.add(switch (admitRing(
        Message(
          clientTempId: 'm1',
          channelId: 'dm:aaa:bbb',
          sender: const MessageSender(userId: robin, kind: SenderKind.human),
          body: kCallInviteBody,
          createdAt: now,
          origin: signedAt(now),
          originCryptoValid: true,
          deliveryState: DeliveryState.sent,
        ),
        meUserId: me,
        blockedUserIds: const {},
        consent: RingConsent.none,
        conversationMuted: false,
        isDm: true,
        now: now,
      )) {
        RingRefused(:final reason) => reason,
        RingAdmitted() => throw StateError('expected a refusal'),
      });
      producedByStart.add(
        refusal(
          invite(age: kCallInviteFreshness + const Duration(seconds: 1)),
        )!,
      );

      final producedByStop = <RingRefusal>{};
      Message end({
        String body = kCallEndBody,
        String? from = robin,
        String? target = '01M0GS7FDWBVQ31950B1PTV2DW',
        bool? cryptoValid = true,
        bool withOrigin = true,
        SenderKind kind = SenderKind.human,
      }) => Message(
        clientTempId: 'e1',
        id: '01M0GS7FDWBVQ31950B1PTV2DX',
        channelId: 'dm:aaa:bbb',
        sender: MessageSender(userId: from, kind: kind),
        body: body,
        replyToId: target,
        createdAt: now,
        origin: withOrigin ? signedAt(now) : null,
        originCryptoValid: cryptoValid,
        deliveryState: DeliveryState.sent,
      );
      for (final m in [
        end(body: 'hello'),
        end(from: null),
        end(target: null),
        end(cryptoValid: null),
        end(withOrigin: false), // cryptoValid true, origin absent
        end(kind: SenderKind.llm),
        end(from: me),
        end(),
      ]) {
        switch (admitCallEnd(m, meUserId: me, consent: RingConsent.none)) {
          case CallEndRefused(:final reason):
            producedByStop.add(reason);
          case CallEndAdmitted():
            break;
        }
      }

      final declaredStart = RingRefusal.values
          .where((r) => r.startGate)
          .toSet();
      final declaredStop = RingRefusal.values.where((r) => r.stopGate).toSet();

      // NO EXCEPTIONS. An earlier version subtracted `anonymousSender` here,
      // because the flag said both gates and only the start gate produces it —
      // i.e. it encoded the contradiction rather than removing it, which is the
      // exact lie the comment above condemns. The flag is now correct, so the
      // comparison is plain equality. Carnot + Tesla, independently, round 3.
      expect(
        producedByStop,
        equals(declaredStop),
        reason: 'the STOP gate emits exactly the reasons it declares',
      );
      expect(
        producedByStart,
        equals(declaredStart),
        reason: 'the START gate emits exactly the reasons it declares',
      );
      // And no reason is claimed by neither gate.
      for (final r in RingRefusal.values) {
        expect(
          r.startGate || r.stopGate,
          isTrue,
          reason: '$r is claimed by no gate — a dead value',
        );
      }
    });

    test('the hot path is NOT refusedAnAttempt — this protects the ring buffer', () {
      // `admitRing` sees EVERY inbound message, so `notAnInvite` fires for every
      // ordinary chat message. Flipping it to refusedAnAttempt would fill a 500-record
      // buffer with it in seconds and evict the events worth keeping — the
      // diagnostic tool destroying its own value. Not a verbosity preference.
      expect(RingRefusal.notAnInvite.refusedAnAttempt, isFalse);
      expect(RingRefusal.ownInvite.refusedAnAttempt, isFalse);
      expect(RingRefusal.notAnEnd.refusedAnAttempt, isFalse);
      expect(RingRefusal.ownEnd.refusedAnAttempt, isFalse);
      // Everything else means somebody tried to ring you and the gate said no.
      for (final r in RingRefusal.values) {
        if (r
            case RingRefusal.notAnInvite ||
                RingRefusal.ownInvite ||
                RingRefusal.notAnEnd ||
                RingRefusal.ownEnd) {
          continue;
        }
        expect(
          r.refusedAnAttempt,
          isTrue,
          reason: '$r is a refused ring attempt and must be observable',
        );
      }
    });
  });

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

    test('every NON-HUMAN sender — the refusal a user could not make themselves', () {
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
    });

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

    test(
      'an allowlisted key rings even though the island says it is not a person',
      () {
        final admitted = admit(
          invite(kind: SenderKind.llm, key: residentKey),
          allowedKeys: {mk(residentKey)},
        );
        expect(admitted, isNotNull);
      },
    );

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

    test(
      'consent is keyed on the KEY, not the account — a relabelled sender gains nothing',
      () {
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
      },
    );

    test(
      'an allowlisted key with NO account is still refused — consent must stay withdrawable',
      () {
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
      },
    );

    test('the allowlist widens ONE gate — it is not a bypass', () {
      final allowed = {mk(residentKey)};
      Message resident() => invite(kind: SenderKind.llm, key: residentKey);
      // Each of these would admit if the allowlist short-circuited the rest.
      expect(
        admit(resident(), allowedKeys: allowed, blocked: {robin}),
        isNull,
        reason: 'blocked',
      );
      expect(
        admit(resident(), allowedKeys: allowed, muted: true),
        isNull,
        reason: 'muted',
      );
      expect(
        admit(resident(), allowedKeys: allowed, isDm: false),
        isNull,
        reason: 'not a DM',
      );
      expect(
        admit(
          invite(
            kind: SenderKind.llm,
            key: residentKey,
            age: const Duration(minutes: 5),
          ),
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

    test(
      'an EMPTY allowlist preserves the old behaviour for every non-human kind',
      () {
        for (final kind in SenderKind.values.where(
          (k) => k != SenderKind.human,
        )) {
          expect(
            admit(invite(kind: kind, key: residentKey)),
            isNull,
            reason: 'a $kind must not ring with no consent recorded',
          );
        }
      },
    );

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
        consent: RingConsent.inChannel(channelId: 'dm:aaa:bbb', keys: allowed),
      );
      expect(
        ended,
        isA<CallEndAdmitted>(),
        reason: 'the consented caller must be able to stop its own ring',
      );
    });

    test('an UNCONSENTED non-human still cannot hang up', () {
      // The widening is symmetric, not a hole: without consent the stop gate
      // refuses exactly as the start gate does.
      expect(
        admitCallEnd(
          callEnd(kind: SenderKind.llm, key: strangerKey),
          meUserId: me,
          consent: RingConsent.inChannel(
            channelId: 'dm:aaa:bbb',
            keys: {mk(residentKey)},
          ),
        ),
        isA<CallEndRefused>().having(
          (r) => r.reason,
          'reason',
          RingRefusal.consentWithheld,
        ),
      );
    });

    test('a human still rings without appearing on any allowlist', () {
      expect(admit(invite(key: strangerKey)), isNotNull);
    });

    group('consent is PER CONVERSATION (Nick, 2026-08-26)', () {
      const here = 'dm:aaa:bbb';
      const elsewhere = 'dm:aaa:ccc';

      test('a key consented HERE rings here', () {
        expect(
          admitRing(
            invite(kind: SenderKind.llm, key: residentKey, channelId: here),
            meUserId: me,
            blockedUserIds: const {},
            consent: RingConsent.inChannel(
              channelId: here,
              keys: {mk(residentKey)},
            ),
            conversationMuted: false,
            isDm: true,
            now: now,
          ),
          isA<RingAdmitted>(),
        );
      });

      test(
        'the SAME key does NOT ring in another conversation — the whole ruling',
        () {
          // The global version admitted this. A resident agent may hold membership
          // in many channels, so "blessed in one room" leaking into every room it
          // can reach is not a corner case, it is the ordinary shape of the thing.
          expect(
            admitRing(
              invite(
                kind: SenderKind.llm,
                key: residentKey,
                channelId: elsewhere,
              ),
              meUserId: me,
              blockedUserIds: const {},
              consent: RingConsent.inChannel(
                channelId: elsewhere,
                keys: {mk(residentKey)},
              ),
              conversationMuted: false,
              isDm: true,
              now: now,
            ),
            isA<RingAdmitted>(),
            reason: 'precondition: consent granted THERE does admit there',
          );
          expect(
            admitRing(
              invite(
                kind: SenderKind.llm,
                key: residentKey,
                channelId: elsewhere,
              ),
              meUserId: me,
              blockedUserIds: const {},
              consent: RingConsent.inChannel(
                channelId: here,
                keys: {mk(residentKey)},
              ),
              conversationMuted: false,
              isDm: true,
              now: now,
            ),
            // Named, so a future refactor that starts refusing this for the
            // WRONG reason (say, by tripping the freshness clause) cannot pass
            // by still being a refusal. That substitution was invisible while
            // every refusal was the same `null`.
            isA<RingRefused>().having(
              (r) => r.reason,
              'reason',
              RingRefusal.consentWithheld,
            ),
          );
        },
      );

      test('a MIS-SCOPED consent is refused, not silently trusted — the gate '
          're-checks the slice rather than believing the caller', () {
        // The defence against the defect this feature has already produced
        // twice: a caller that pairs one room's keys with another room's id.
        // The keys match, the sender is consented, and it still must not ring.
        final consent = RingConsent.inChannel(
          channelId: elsewhere,
          keys: {mk(residentKey)},
        );
        expect(consent.permits(here, decodeMultikey(mk(residentKey))), isFalse);
        expect(
          admitRing(
            invite(kind: SenderKind.llm, key: residentKey, channelId: here),
            meUserId: me,
            blockedUserIds: const {},
            consent: consent,
            conversationMuted: false,
            isDm: true,
            now: now,
          ),
          isA<RingRefused>().having(
            (r) => r.reason,
            'reason',
            RingRefusal.consentWithheld,
          ),
        );
      });

      test('the stop gate is scoped identically to the start gate', () {
        // Rounds 6-7 found the start and stop gates diverging once before. A
        // per-conversation start with a global stop would be the same defect
        // wearing the new scope.
        expect(
          admitCallEnd(
            callEnd(kind: SenderKind.llm, key: residentKey),
            meUserId: me,
            consent: RingConsent.inChannel(
              channelId: elsewhere,
              keys: {mk(residentKey)},
            ),
          ),
          isA<CallEndRefused>().having(
            (r) => r.reason,
            'reason',
            RingRefusal.consentWithheld,
          ),
          reason:
              'the end arrives in dm:aaa:bbb; consent for another room must not '
              'admit it, or a caller could be consented to stop rings it was '
              'never allowed to start',
        );
      });

      test('a hangup admitted in room B cannot end room A\'s ring — the stop '
          'CORRELATION is scoped, not just the stop ADMISSION', () {
        // Tesla asked for this at the confirming round, and was right to: the
        // per-conversation change scoped what `admitCallEnd` ADMITS, while the
        // `_ended` ledger is keyed on `targetIslandMsgId` alone. If correlation
        // were unscoped, an agent consented only in room B could pass the stop
        // gate there and silence — or pre-poison — a ring living in room A.
        //
        // It cannot, and the reason is `endsInvite` comparing all three fields
        // rather than the id alone (call_invite.dart). Both the live path and
        // the memory path run it, so this pins the property both share.
        final ringInA = CallInvite(
          inviteId: 'c-1',
          islandMsgId: '01M0GS7FDWBVQ31950B1PTV2D0',
          channelId: here,
          from: const MessageSender(userId: 'agent', kind: SenderKind.llm),
          startedAt: now,
        );
        const endFromB = CallEnd(
          targetIslandMsgId: '01M0GS7FDWBVQ31950B1PTV2D0',
          fromUserId: 'agent',
          channelId: elsewhere,
        );

        expect(
          endsInvite(endFromB, ringInA),
          isFalse,
          reason:
              'same target id, same caller, DIFFERENT room — the covenant lives '
              'in B and the ring lives in A',
        );
        expect(
          endsInvite(
            const CallEnd(
              targetIslandMsgId: '01M0GS7FDWBVQ31950B1PTV2D0',
              fromUserId: 'agent',
              channelId: here,
            ),
            ringInA,
          ),
          isTrue,
          reason: 'positive control — the same end IN room A does correlate',
        );
      });

      test('RingConsent.none admits nobody anywhere', () {
        expect(
          RingConsent.none.permits(here, decodeMultikey(mk(residentKey))),
          isFalse,
        );
        expect(RingConsent.none.channelId, isNull);
      });
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
      final end = switch (admitCallEnd(
        m,
        meUserId: me,
        consent: RingConsent.none,
      )) {
        CallEndAdmitted(:final end) => end,
        CallEndRefused() => null,
      };
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
        final decision = admitCallEnd(
          end(),
          meUserId: me,
          consent: RingConsent.none,
        );
        expect(decision, isA<CallEndAdmitted>());
        final judged = (decision as CallEndAdmitted).end;
        expect(judged.targetIslandMsgId, '01M0GS7FDWBVQ31950B1PTV2DW');
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
      expect(
        admitCallEnd(anon, meUserId: me, consent: RingConsent.none),
        // `endMissingAuthor` — and the history of this one assertion is the
        // whole argument for the change. It began as a guess (`anonymousSender`),
        // and the type refuted it: the compound `_isCallEndShape` gate fired
        // first, so the honest answer was `notAnEnd`. That was TRUE and still
        // wrong, because `notAnEnd` also meant "an ordinary chat message" and
        // was therefore silent — so a malformed stop aimed at the ring subsystem
        // was unloggable by construction, and the first draft of this comment
        // wrote that up as a win. Three families (Maxwell, Carnot, Tesla) named
        // the conflation independently; `admitCallEnd` now decomposes the
        // predicate. A correct answer filed under the wrong reason is still the
        // defect this PR exists to remove.
        isA<CallEndRefused>().having(
          (r) => r.reason,
          'reason',
          RingRefusal.endMissingAuthor,
        ),
      );
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
      expect(
        admitCallEnd(robot, meUserId: me, consent: RingConsent.none),
        isA<CallEndRefused>().having(
          (r) => r.reason,
          'reason',
          RingRefusal.consentWithheld,
        ),
      );
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
