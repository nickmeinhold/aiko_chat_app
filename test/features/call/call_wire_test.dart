import 'dart:math';

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
  group('golden vectors (shared with the island)', () {
    test('the valid invite parses to its id', () {
      expect(
        parseCallBody(kValidInvite),
        const CallBody(CallBodyKind.invite, kGoldenId),
      );
    });

    test('the valid end parses to the SAME id', () {
      expect(
        parseCallBody(kValidEnd),
        const CallBody(CallBodyKind.end, kGoldenId),
      );
    });

    for (final MapEntry(key: why, value: body) in kRejects.entries) {
      test('rejects: $why — an ordinary message, never a call', () {
        expect(parseCallBody(body), isNull);
      });
    }

    test('the builders produce the golden bytes exactly', () {
      expect(callInviteBodyV2(kGoldenId), kValidInvite);
      expect(callEndBodyV2(kGoldenId), kValidEnd);
    });
  });

  group('v1 is recognised forever, with no identity', () {
    test('both v1 sentinels parse, callId null', () {
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
        final id = mintCallId();
        expect(isCallId(id), isTrue, reason: id);
        expect(parseCallBody(callInviteBodyV2(id))?.callId, id);
      }
    });

    test('the extremes of 128 bits encode canonically', () {
      // All-zero and all-ones bytes: the leading char is the top three bits,
      // so the shape holds at both ends without a special case.
      expect(mintCallId(random: _Fixed(0)), '0' * 26);
      expect(mintCallId(random: _Fixed(255)), '7${'Z' * 25}');
    });

    test('builders refuse a non-canonical id rather than emit a non-call', () {
      expect(() => callInviteBodyV2('01jabc'), throwsArgumentError);
      expect(() => callEndBodyV2('8${'0' * 25}'), throwsArgumentError);
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
