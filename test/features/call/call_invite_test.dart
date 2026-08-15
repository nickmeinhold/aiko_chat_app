import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
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

  Message invite({
    String from = robin,
    String channelId = 'dm:aaa:bbb',
    String body = kCallInviteBody,
    Duration age = const Duration(seconds: 1),
  }) =>
      Message(
        clientTempId: 'm1',
        id: 'm1',
        channelId: channelId,
        sender: MessageSender(
            userId: from, kind: SenderKind.human, label: 'Robin'),
        body: body,
        createdAt: now.subtract(age),
        deliveryState: DeliveryState.sent,
      );

  CallInvite? admit(
    Message m, {
    Set<String> blocked = const {},
    bool muted = false,
  }) =>
      admitRing(m,
          meUserId: me,
          blockedUserIds: blocked,
          conversationMuted: muted,
          now: now);

  group('the pinned sentinel', () {
    // GOLDEN. This string is signed and written to permanent island history, so
    // it is a ONE-WAY DOOR: a change is a v2 with a compatibility branch, never
    // an edit. If this test fails, you are about to fork the wire — stop.
    test('is byte-for-byte what a peer will verify forever', () {
      expect(kCallInviteBody, 'aiko:call/1 · 📞 started a call');
    });

    test('matches exactly — a sentinel with anything appended is NOT an invite',
        () {
      // A startsWith/contains test would let anyone ring you by typing the
      // sentinel with a word after it, and would make every quotation ring.
      expect(isCallInviteBody(kCallInviteBody), isTrue);
      expect(isCallInviteBody('$kCallInviteBody and now you ring'), isFalse);
      expect(isCallInviteBody('look: aiko:call/1 · 📞 started a call'), isFalse);
      expect(isCallInviteBody(''), isFalse);
    });
  });

  group('admits', () {
    test('a fresh invite from a peer in an unmuted, unblocked conversation', () {
      final got = admit(invite());
      expect(got, isNotNull);
      expect(got!.channelId, 'dm:aaa:bbb');
      expect(got.from.userId, robin);
      expect(got.startedAt, now.subtract(const Duration(seconds: 1)));
    });

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

    test('a blocked sender', () {
      expect(admit(invite(), blocked: {robin}), isNull);
    });

    test('a muted conversation', () {
      // Mute is attention-scoped and a ring is the loudest attention there is.
      expect(admit(invite(), muted: true), isNull);
    });

    test('a stale invite — history replay must not ring the backlog', () {
      expect(admit(invite(age: kCallInviteFreshness + const Duration(seconds: 1))),
          isNull);
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
}
