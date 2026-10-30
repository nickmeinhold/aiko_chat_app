import 'dart:math';

import 'package:aiko_chat_app/features/call/domain/call_invite.dart'
    show kCallInviteClockSkewTolerance, kCallInviteFreshness;
import 'package:aiko_chat_app/features/call/domain/call_wire.dart';
import 'package:flutter_test/flutter_test.dart';

// SHARED GOLDEN VECTORS. Byte-identical to the island's
// `tests/test_call_wire_v2.py` (agreed 2026-10-06, pinned on both sides). If
// one of these changes, the other repo's copy must change in the same breath —
// a wake the island sends must be a call this app admits, and vice versa.
const kValidInvite =
    'aiko:call/2 01JABCDEFGHJKMNPQRSTVWXYZ0 · 📞 started a call';
const kValidEnd = 'aiko:call/2 01JABCDEFGHJKMNPQRSTVWXYZ0 · 📞 ended the call';
const kGoldenId = '01JABCDEFGHJKMNPQRSTVWXYZ0';
const kRejects = <String, String>{
  'lowercase ulid':
      'aiko:call/2 01jabcdefghjkmnpqrstvwxyz0 · 📞 started a call',
  'overflow lead 8':
      'aiko:call/2 81JABCDEFGHJKMNPQRSTVWXYZ0 · 📞 started a call',
  '25 chars': 'aiko:call/2 01JABCDEFGHJKMNPQRSTVWXYZ · 📞 started a call',
  'excluded letter I':
      'aiko:call/2 01JABCDEFGHIKMNPQRSTVWXYZ0 · 📞 started a call',
  'trailing content':
      'aiko:call/2 01JABCDEFGHJKMNPQRSTVWXYZ0 · 📞 started a call!',
  'v1 tail, no space':
      'aiko:call/201JABCDEFGHJKMNPQRSTVWXYZ0 · 📞 started a call',
};

void main() {
  // MIRROR PIN, shared with the island: aiko-chat-island
  // `tests/test_call_hold.py::test_the_hold_outlasts_the_apps_freshness_with_
  // the_documented_margin` pins these same two numbers. The island holds a
  // stranger's call invite for `call_hold.HOLD_MS` (60 s) past
  // max(signed_at, receipt), then delivers it so it arrives too old to ring:
  // a missed call on every app version (Nick, 2026-10-29; design 25). The hold
  // is sized against THIS window. Widening either constant here can make it too
  // short, and a stranger's late invite would ring. So move the island's
  // `HOLD_MS` FIRST, then update these goldens on both sides, the way the
  // call/2 vectors below change.
  group('the window the island\'s stranger-call hold is sized against', () {
    test('freshness is 10 s and clock-skew tolerance is 5 s', () {
      expect(kCallInviteFreshness, const Duration(seconds: 10));
      expect(kCallInviteClockSkewTolerance, const Duration(seconds: 5));
    });
  });

  group('golden vectors (shared with the island)', () {
    test('the valid invite parses to its id', () {
      expect(
        parseCallBody(kValidInvite),
        CallBody(CallBodyKind.invite, CallRef(kGoldenId)),
      );
    });

    test('the valid end parses to the SAME id', () {
      expect(
        parseCallBody(kValidEnd),
        CallBody(CallBodyKind.end, CallRef(kGoldenId)),
      );
    });

    for (final MapEntry(key: why, value: body) in kRejects.entries) {
      test('rejects: $why — an ordinary message, never a call', () {
        expect(parseCallBody(body), isNull);
      });
    }

    test('the builders produce the golden bytes exactly', () {
      expect(callInviteBodyV2(CallRef(kGoldenId)), kValidInvite);
      expect(callEndBodyV2(CallRef(kGoldenId)), kValidEnd);
    });
  });

  group('v1 is recognised forever — as history, never a call', () {
    test('both v1 sentinels parse, with no call (design 22 v2.0)', () {
      expect(
        parseCallBody(kCallInviteBodyV1),
        const CallBody(CallBodyKind.invite, null),
      );
      expect(
        parseCallBody(kCallEndBodyV1),
        const CallBody(CallBodyKind.end, null),
      );
    });

    test('v2 tails are v1 tails, codepoint for codepoint', () {
      // An older build renders a v2 body as text; this is what keeps that text
      // reading "📞 started a call" rather than a bare machine string.
      expect(kValidInvite.endsWith(kCallInviteBodyV1.substring(11)), isTrue);
      expect(kValidEnd.endsWith(kCallEndBodyV1.substring(11)), isTrue);
    });

    test('a v1 body with a word after it is not a call (exact match)', () {
      expect(parseCallBody('$kCallInviteBodyV1 '), isNull);
      expect(parseCallBody('$kCallEndBodyV1!'), isNull);
    });
  });

  group('minting', () {
    test('every minted id is canonical — 1000 draws', () {
      for (var i = 0; i < 1000; i++) {
        final call = mintCall();
        expect(isCallId(call.id), isTrue, reason: call.id);
        expect(parseCallBody(callInviteBodyV2(call))?.call, call);
      }
    });

    test('the extremes of 128 bits encode canonically', () {
      // All-zero and all-ones bytes: the leading char is the top three bits,
      // so the shape holds at both ends without a special case.
      expect(mintCallId(random: _Fixed(0)), '0' * 26);
      expect(mintCallId(random: _Fixed(255)), '7${'Z' * 25}');
    });

    test(
      'a CallRef refuses a non-canonical id, so no builder can emit one',
      () {
        expect(() => CallRef('01jabc'), throwsArgumentError);
        expect(() => CallRef('8${'0' * 25}'), throwsArgumentError);
        expect(CallRef.tryParse('01jabc'), isNull);
        expect(CallRef.tryParse(42), isNull);
        expect(CallRef.tryParse(kGoldenId), CallRef(kGoldenId));
      },
    );
  });

  group('CallRef (design 22 v2.1)', () {
    test('equality is the id alone', () {
      expect(CallRef(kGoldenId), CallRef(kGoldenId));
      expect(CallRef(kGoldenId).hashCode, CallRef(kGoldenId).hashCode);
      expect(CallRef(kGoldenId) == CallRef('0' * 26), isFalse);
    });

    test('oneChannelPerCall is the single channel policy', () {
      expect(oneChannelPerCall('dm:a:b', 'dm:a:b'), isTrue);
      expect(oneChannelPerCall('dm:a:b', 'dm:c:d'), isFalse);
    });
  });
}

class _Fixed implements Random {
  _Fixed(this.byte);
  final int byte;
  @override
  int nextInt(int max) => byte % max;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}
