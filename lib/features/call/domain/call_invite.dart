/// A call invitation — the "ring" (#2808).
///
/// **The invitation is an ordinary signed message.** Not a new `MessageKind`,
/// not a new WS frame. Three reasons, in the order they'd survive a cage-match:
///
/// 1. **It is unforgeable by construction.** `signingBytes()` covers
///    domainTag ‖ pubkey ‖ channelId ‖ clientMsgId ‖ signedAtMs ‖ body ‖ replyTo
///    — and NOT `kind`. A ring is the highest-privilege message in the app: it
///    lights up a remote device and offers to turn on a camera. Carried as a
///    `kind`, the one field that triggers the camera would be the one field the
///    island (or anything between) could forge, while the body it rides on stays
///    sound. In the body, the signature covers the ring itself.
/// 2. **Every parameter is already inside the signed envelope.** The room IS the
///    channel id (island handoff #2726), the caller IS the signing key, the start
///    time IS `signedAtMs`. So the body carries NO parameters — there is nothing
///    to forge because nothing is passed. [kCallInviteBody] is a pure sentinel.
/// 3. **It inherits the whole authz/moderation stack through the door that
///    already exists** — auth, membership visibility (`acl.readable_channel`),
///    existence-hiding 404-not-403, takedown retractions, and the block
///    content-filter (island `docs/design/11-direct-messages.md`). A blocked
///    account cannot ring you, for free. A new frame would have to re-earn every
///    one of those.
///
/// Cost, named rather than hidden: the invitation is a real row in permanent
/// signed history, so [kCallInviteBody] is a ONE-WAY DOOR — changing it is a v2
/// with a compatibility branch, never an edit. Pinned by a golden test.
library;

import '../../chat/domain/message.dart';

/// The pinned invitation body. **Signed and durable — never edit this string.**
/// A client that predates the feature renders it as a readable line of text
/// rather than breaking, which is why the human words trail the machine anchor.
///
/// Confirmed by Nick 2026-08-15 before first transmission to a live island.
const String kCallInviteBody = 'aiko:call/1 · 📞 started a call';

/// How old an invitation may be **on arrival** and still ring.
///
/// This is the STALENESS gate, not the ring duration — the two are different
/// clocks and conflating them is how you ring for a call that ended (Nick,
/// 2026-08-15). Live WS delivery is sub-second, so 10s is generous for
/// freshness; anything older is history replay (app reopen, reconnect drain,
/// scrollback) and must stay silent.
const Duration kCallInviteFreshness = Duration(seconds: 10);

/// How long a ring rings once admitted — a human-reaction clock. After this it
/// stops ringing; the invitation remains in history as the record that it
/// happened.
const Duration kCallRingDuration = Duration(seconds: 30);

/// True when [body] is the call-invitation sentinel.
///
/// Exact match, deliberately: a `startsWith`/`contains` test would let anyone
/// ring you by typing the sentinel with a word after it, and would make every
/// quotation of this doc a ringing message.
bool isCallInviteBody(String body) => body == kCallInviteBody;

/// An admitted, ringable invitation — the room to join and who is calling.
class CallInvite {
  const CallInvite({
    required this.channelId,
    required this.from,
    required this.startedAt,
  });

  /// The LiveKit room to join. The room IS the channel id (#2726).
  final String channelId;

  /// The caller, as carried on the signed message.
  final MessageSender from;

  /// When the caller started the call (the message's server timestamp).
  final DateTime startedAt;

  @override
  bool operator ==(Object other) =>
      other is CallInvite &&
      other.channelId == channelId &&
      other.from.userId == from.userId &&
      other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(channelId, from.userId, startedAt);

  @override
  String toString() => 'CallInvite($channelId, from=${from.userId})';
}

/// **The single door every ring passes through.** Returns the invitation if
/// [message] should make this device ring, or null.
///
/// Pure on purpose: "should this device ring" is the whole trust decision, and a
/// decision spread across a widget, a provider and a stream filter is a decision
/// nobody can test. Every caller funnels here.
///
/// Refusals, and why each one is its own clause:
/// - **not the sentinel** — an ordinary message.
/// - **sent by me** — the caller's own send echoes back through the same inbound
///   path; ringing yourself is the degenerate first case, not an edge case.
/// - **blocked sender** — defence in depth. The island already filters blocked
///   content, so this is normally unreachable; a ring is privileged enough to
///   refuse locally too rather than lean on an upstream filter.
/// - **muted conversation** — mute is attention-scoped and a ring is the loudest
///   attention there is. Muting a DM and then being rung by it would make mute a
///   lie.
/// - **stale** — older than [kCallInviteFreshness]; see that constant.
///
/// Freshness is measured on the server-assigned [Message.createdAt] against
/// device [now]. **Named tradeoff:** that straddles two clocks, so a device
/// whose clock is more than ~10s behind the island will never ring, and one far
/// ahead will ring on replayed history. Server time is the right anchor (it is
/// the one both participants share and neither controls) and the alternative —
/// trusting arrival order — silently rings the whole backlog on reconnect drain.
/// A monotonic fix needs an island-supplied "now"; tracked, not faked.
CallInvite? admitRing(
  Message message, {
  required String meUserId,
  required Set<String> blockedUserIds,
  required bool conversationMuted,
  required DateTime now,
}) {
  if (!isCallInviteBody(message.body)) return null;
  if (message.sender.userId == meUserId) return null;
  if (blockedUserIds.contains(message.sender.userId)) return null;
  if (conversationMuted) return null;
  final age = now.difference(message.createdAt);
  // Negative age (a message stamped in the future by a skewed clock) is not
  // fresh — it is unreadable, and admitting it would let a bad clock ring
  // forever. `!isNegative` is the guard; `> freshness` alone would admit it.
  if (age.isNegative || age > kCallInviteFreshness) return null;
  return CallInvite(
    channelId: message.channelId,
    from: message.sender,
    startedAt: message.createdAt,
  );
}
