/// Cross-implementation conformance: does a signature produced by a SECOND,
/// INDEPENDENT implementation verify against ours?
///
/// This is the half of `test/live/ring_live_test.dart` that needs no island, no
/// second account and no password — and therefore the half that will actually
/// run. The live test answers two questions (does an independent signature
/// verify, and does a real hangup stop a real ring); only the second one needs
/// a network. Splitting them means the codec claim is checked on every
/// `flutter test` instead of on the rare deliberate live run.
///
/// It exists because the live harness spent a round unrunnable — its Python
/// signer lived only in /tmp — while the project record described the
/// instrument as complete. An instrument that runs never is indistinguishable
/// from one that is broken, and both read as green.
///
/// WHY THIS CANNOT BE REPLACED BY A DART TEST THAT SIGNS AND THEN VERIFIES:
/// a self-roundtrip proves self-consistency, not correctness. A codec can be
/// self-consistently wrong — it will happily sign and verify its own malformed
/// bytes forever. The only thing that catches that is bytes produced by code
/// that never shared a line with ours. `tool/ring_probe.py` is that code, and
/// it is itself pinned to the spec's published golden vector.
library;

import 'dart:convert';
import 'dart:io';

import 'package:aiko_chat_app/features/call/domain/call_invite.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run the independent signer and return the frame it emits.
///
/// SKIPPING AND FAILING ARE DIFFERENT ANSWERS, and collapsing them is how a
/// conformance check reports green while the thing it checks is broken. The
/// first version of this helper turned EVERY non-zero exit into a skip — so a
/// signer that had declared itself NON-CONFORMANT against the golden vector
/// would have been recorded as "not run", which reads as fine (cage-match round
/// 5, Carnot). The instrument existed to catch a self-consistently wrong codec
/// and had a mode where it silently declined to look.
///
/// So the probe hands back a distinct exit code — 3 for "I could not run",
/// anything else non-zero for "I ran and something is wrong" — and only the
/// first is a skip. A missing `python3` (which throws rather than exiting) is
/// the same class as 3.
({Map<String, dynamic>? frame, String? skipReason}) _vector({String? replyTo}) {
  const exitMissingDep = 3;
  final ProcessResult r;
  try {
    r = Process.runSync('python3', ['tool/ring_probe.py', 'vector', ?replyTo]);
  } on ProcessException catch (e) {
    // python3 itself is absent — an environment fact, not a conformance verdict.
    return (frame: null, skipReason: 'python3 not available: ${e.message}');
  }

  if (r.exitCode == exitMissingDep) {
    return (frame: null, skipReason: 'signer dependency absent: ${r.stderr}');
  }
  if (r.exitCode != 0) {
    // The probe RAN and reported a problem — a golden-vector mismatch, a signer
    // regression, a crash. Every one of those is the failure this test exists
    // to surface, and none of them is a skip.
    fail(
      'ring_probe failed (exit ${r.exitCode}) — this is a conformance FAILURE, '
      'not a missing tool:\n${r.stdout}\n${r.stderr}',
    );
  }
  final lines = '${r.stdout}'.trim().split('\n');
  return (
    frame: jsonDecode(lines.last) as Map<String, dynamic>,
    skipReason: null,
  );
}

void main() {
  test('an INDEPENDENT signer\'s invitation verifies against our verifier', () async {
    final (:frame, :skipReason) = _vector();
    if (frame == null) {
      markTestSkipped('conformance NOT checked — $skipReason');
      return;
    }

    // The probe's selftest already pinned its signingBytes against the spec's
    // published golden vector before it signed anything, so reaching here means
    // two implementations agree with the SPEC, not merely with each other.
    final origin = validateOrigin(
      (frame['origin'] as Map).cast<String, dynamic>(),
      frameClientMsgId: frame['client_msg_id'] as String,
    );
    // A null here is the SHAPE gate refusing the envelope outright — a distinct
    // failure from a bad signature, and worth its own assertion so the two
    // cannot be confused in a failure report.
    expect(
      origin,
      isNotNull,
      reason: 'our own admission gate rejected an independently-built envelope',
    );

    final ok = await verifyOrigin(
      origin!,
      channelId: frame['channel_id'] as String,
      body: frame['body'] as String,
      replyTo: frame['reply_to'] as String?,
    );

    expect(
      ok,
      isTrue,
      reason:
          'a signature from a separate implementation of signingBytes did not '
          'verify here. That is either the byte contract or the verifier — and '
          'it is exactly what our own sign-then-verify cannot tell us',
    );
    expect(
      frame['body'],
      kCallInviteBody,
      reason: 'the pinned sentinel drifted',
    );
  });

  test(
    'an INDEPENDENT signer\'s hangup verifies, reply_to inside the signature',
    () async {
      // The reply binding is the field this whole feature turns on, and it is
      // INSIDE signingBytes — so an implementation that dropped it would still
      // produce a valid-looking envelope whose signature covers the wrong tuple.
      // Signing the invitation alone would never catch that.
      const target = '01M0GS7FDWBVQ31950B1PTV2D5';
      final (:frame, :skipReason) = _vector(replyTo: target);
      if (frame == null) {
        markTestSkipped('conformance NOT checked — $skipReason');
        return;
      }
      final origin = validateOrigin(
        (frame['origin'] as Map).cast<String, dynamic>(),
        frameClientMsgId: frame['client_msg_id'] as String,
      );
      expect(origin, isNotNull);
      expect(frame['reply_to'], target);
      expect(
        frame['body'],
        kCallEndBody,
        reason: 'the pinned sentinel drifted',
      );

      expect(
        await verifyOrigin(
          origin!,
          channelId: frame['channel_id'] as String,
          body: frame['body'] as String,
          replyTo: frame['reply_to'] as String?,
        ),
        isTrue,
      );

      // NEGATIVE CONTROL — the instrument must be able to report failure.
      // Verifying with the reply binding stripped MUST fail, or the test above
      // proves nothing: a verifier that ignored reply_to would pass it happily.
      expect(
        await verifyOrigin(
          origin,
          channelId: frame['channel_id'] as String,
          body: frame['body'] as String,
          replyTo: null,
        ),
        isFalse,
        reason:
            'reply_to is inside the signed bytes — dropping it must break the '
            'signature, or this test cannot tell a bound hangup from a loose one',
      );
    },
  );
}
