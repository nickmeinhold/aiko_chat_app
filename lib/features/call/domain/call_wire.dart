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

/// A call's identity: a grammar-checked call/2 id, and nothing else.
///
/// **ONE MEANING FOR ABSENCE (design 22).** A call's identity used to travel
/// as `String? callId`, and null meant three things: a v1 call, a screen that
/// names no call, and an id nobody passed. Each of a dozen sites re-derived
/// which, and they disagreed, through six review rounds. Now a call IS a
/// [CallRef], and `CallRef?` null means only "no call".
///
/// **v1 IS NOT A CALL** (design 22 v2.0, Nick 2026-10-06). No store build ever
/// placed a v1 call, so a v1 body is history: it renders, and it never rings,
/// admits, answers or ends. That is why there is no `V1` variant here.
///
/// **Equality is the id alone.** The channel a call rings on is stored beside
/// the ref and checked at the door by [oneChannelPerCall], so the rule that a
/// call is one DM lives in one function, which island #3196 may one day
/// change, and not inside `==`.
final class CallRef {
  /// [id] must be a canonical call id — see [isCallId].
  CallRef(this.id) {
    _checkCallId(id);
  }

  /// The ref [id] names, or null if it is not a call id. For decoding a
  /// boundary (the native bridge) where a malformed id is dropped, never thrown.
  static CallRef? tryParse(Object? id) =>
      id is String && isCallId(id) ? CallRef(id) : null;

  final String id;

  @override
  bool operator ==(Object other) => other is CallRef && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CallRef($id)';
}

/// THE door policy for a call's channel: a call is one DM today.
///
/// [stored] is the channel the call was first seen on; [seen] is the channel
/// an event for the same [CallRef] names now. The single seam a cross-channel
/// gathering (island #3196, design 12 Decision 1b) would change. Nothing else
/// encodes this rule.
bool oneChannelPerCall(String stored, String seen) => stored == seen;

/// A recognised call body. [call] is null exactly for a v1 body, which is
/// history and never a call.
final class CallBody {
  const CallBody(this.kind, this.call);

  final CallBodyKind kind;

  /// The call a v2 body names. Null for v1.
  final CallRef? call;

  @override
  bool operator ==(Object other) =>
      other is CallBody && other.kind == kind && other.call == call;

  @override
  int get hashCode => Object.hash(kind, call);

  @override
  String toString() => 'CallBody(${kind.name}, ${call?.id ?? 'v1'})';
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
  if (invite != null) {
    return CallBody(CallBodyKind.invite, CallRef(invite.group(1)!));
  }
  final end = _v2End.firstMatch(body);
  if (end != null) return CallBody(CallBodyKind.end, CallRef(end.group(1)!));
  return null;
}

/// True when [id] is a canonical call id.
bool isCallId(String id) => _callIdPattern.hasMatch(id);

/// The v2 invite body for [call].
String callInviteBodyV2(CallRef call) => '$_v2Prefix${call.id}$_inviteTail';

/// The v2 end body for [call] — the hangup for the call that invite named.
String callEndBodyV2(CallRef call) => '$_v2Prefix${call.id}$_endTail';

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
CallRef mintCall({Random? random}) => CallRef(mintCallId(random: random));

/// The id [mintCall] wraps. Exposed for the grammar's own tests.
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
