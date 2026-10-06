/// The call wire format: the one place that recognises and builds call bodies.
///
/// Two versions, both permanent:
///
///  * **v1** — `aiko:call/1 · 📞 started a call` / `… ended the call`. Exact
///    strings, no identity. In signed history, so recognised forever.
///  * **v2** — `aiko:call/2 <ULID> · 📞 started a call` / `… ended the call`.
///    The ULID is the CALL'S IDENTITY, minted by the caller and carried inside
///    the signed body, so it is as authentic as the signature (island design 12,
///    Decision 1; bytes pinned jointly 2026-10-06 in that design's addendum and
///    in app design 21).
///
/// **WHY A CALL NEEDS AN IDENTITY AT ALL.** A channel is not a call: one channel
/// rings, ends, is answered and rings again inside a minute, and every message
/// that said only "channel X" could land on the wrong one. The device also
/// cannot tell "the same invite delivered twice" from "a new call on this
/// channel" without an id the SENDER chose. Design 21 has the full account —
/// three cage-match rounds of findings that were all this one missing concept.
///
/// **ONE PARSER.** The island has exactly one recogniser (`parse_call_body`);
/// this is its twin. Every other predicate in the app derives from
/// [parseCallBody], so the wake decision on the island and the admission
/// decision here read the same grammar. The shared golden vectors in
/// `call_wire_test.dart` are byte-identical to the island's
/// `tests/test_call_wire_v2.py`.
library;

import 'dart:math';

/// Which half of a call a body is.
enum CallBodyKind { invite, end }

/// A recognised call body. [callId] is null exactly for v1.
final class CallBody {
  const CallBody(this.kind, this.callId);

  final CallBodyKind kind;

  /// The v2 call identity, or null for a v1 body (which has none).
  final String? callId;

  bool get isV2 => callId != null;

  @override
  bool operator ==(Object other) =>
      other is CallBody && other.kind == kind && other.callId == callId;

  @override
  int get hashCode => Object.hash(kind, callId);

  @override
  String toString() => 'CallBody(${kind.name}, ${callId ?? 'v1'})';
}

/// The v1 invite sentinel. **Signed and durable — never edit this string.**
const String kCallInviteBodyV1 = 'aiko:call/1 · 📞 started a call';

/// The v1 end sentinel. **Signed and durable — never edit this string.**
const String kCallEndBodyV1 = 'aiko:call/1 · 📞 ended the call';

const String _v2Prefix = 'aiko:call/2 ';
const String _inviteTail = ' · 📞 started a call';
const String _endTail = ' · 📞 ended the call';

/// A canonical call id: 26 characters of UPPERCASE Crockford base32, leading
/// character `0`-`7`.
///
/// The leading `[0-7]` is what makes the id fit in 128 bits (26 × 5 = 130, so
/// the top two bits must be zero) — which is what maps it losslessly onto the
/// UUID CallKit and ConnectionService require. A string that fails this is not
/// a call id, and a body carrying one is not a call: it is an ordinary message.
final RegExp _callIdPattern = RegExp(r'^[0-7][0-9A-HJKMNP-TV-Z]{25}$');

// FULLMATCH, never a prefix. A prefix test would hand anyone a wake primitive
// with arbitrary trailing content — the reason v1 was exact-match from the
// start. The frame is fixed and the only variable is a constrained 26-char id.
final RegExp _v2Invite = RegExp(
  '^${RegExp.escape(_v2Prefix)}([0-7][0-9A-HJKMNP-TV-Z]{25})'
  '${RegExp.escape(_inviteTail)}\$',
);
final RegExp _v2End = RegExp(
  '^${RegExp.escape(_v2Prefix)}([0-7][0-9A-HJKMNP-TV-Z]{25})'
  '${RegExp.escape(_endTail)}\$',
);

/// The call body [body] is, or null if it is not one.
CallBody? parseCallBody(String body) {
  if (body == kCallInviteBodyV1) {
    return const CallBody(CallBodyKind.invite, null);
  }
  if (body == kCallEndBodyV1) return const CallBody(CallBodyKind.end, null);
  final invite = _v2Invite.firstMatch(body);
  if (invite != null) return CallBody(CallBodyKind.invite, invite.group(1));
  final end = _v2End.firstMatch(body);
  if (end != null) return CallBody(CallBodyKind.end, end.group(1));
  return null;
}

/// True when [id] is a canonical call id.
bool isCallId(String id) => _callIdPattern.hasMatch(id);

/// The v2 invite body for [callId].
String callInviteBodyV2(String callId) {
  _checkCallId(callId);
  return '$_v2Prefix$callId$_inviteTail';
}

/// The v2 end body for [callId] — the hangup for the call that invite named.
String callEndBodyV2(String callId) {
  _checkCallId(callId);
  return '$_v2Prefix$callId$_endTail';
}

void _checkCallId(String id) {
  if (!isCallId(id)) throw ArgumentError.value(id, 'callId', 'not a call id');
}

const String _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Mints a call id from 128 bits of `Random.secure()` — NO timestamp.
///
/// A ULID conventionally spends 48 bits on a millisecond timestamp. This one
/// does not, on purpose: the id rides the wake payload to Apple and Google
/// (island addendum 2026-10-06: "the island's guarantee is the shape, not the
/// content"), so every bit in it should say nothing. Any 128-bit value encodes
/// to a canonical id — the leading character is the top three bits, always
/// `0`-`7` — so pure randomness satisfies the shape without a special case.
/// Sortability, the timestamp's only job, is something calls do not need.
String mintCallId({Random? random}) {
  final rng = random ?? Random.secure();
  var value = BigInt.zero;
  for (var i = 0; i < 16; i++) {
    value = (value << 8) | BigInt.from(rng.nextInt(256));
  }
  final chars = List<String>.filled(26, '0');
  final mask = BigInt.from(31);
  for (var i = 25; i >= 0; i--) {
    chars[i] = _crockford[(value & mask).toInt()];
    value = value >> 5;
  }
  return chars.join();
}
