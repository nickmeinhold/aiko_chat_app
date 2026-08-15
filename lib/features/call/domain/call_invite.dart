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
/// - **an unverified origin** — `originCryptoValid != true`. THE refusal the
///   whole design rests on. Everything above argues the signature covers the
///   body; this is where that argument is cashed. Absent or invalid signature →
///   no ring, fail CLOSED: a missed ring is recoverable (call again), a forged
///   one impersonates a person to get you into a room. (Cage-match #139, Carnot
///   + Tesla independently: the original `admitRing` read body/sender/time and
///   never looked at `origin` at all — the security essay was unenforced. Two
///   distant model families walked straight to it; the nearest family approved
///   the diff.)
/// - **not a DM** — the sentinel is deliberately human-readable so old clients
///   degrade gracefully, which means any HUMAN can type it. In a community
///   channel that rings every member at once. Refusing the bot half only
///   unplugged one horn of the megaphone (cage-match #139, Tesla). Keyed off the
///   island's `dm:` channel-id prefix, which is a CHECK constraint on the
///   gateway (`ck_channels_dm_prefix`, case-sensitive — island design 11), not a
///   client-side convention. Channel-wide calls are a real future feature; they
///   need their own consent model, not this door.
/// - **a bot sender** — bots are UNBLOCKABLE by island design (a bus actor has
///   no account to action; `moderation_service.py`, and claude-tasks#27 is open
///   for exactly this). Every other refusal here is something the user can
///   choose; a bot ring is one they could not switch off, in any channel they
///   are a member of. Refused until actor-scoped suppression exists — a
///   REVERSIBLE call, and the one to revisit when a robot should be able to ring
///   you back.
/// - **blocked sender** — defence in depth. The island already filters blocked
///   content, so this is normally unreachable; a ring is privileged enough to
///   refuse locally too rather than lean on an upstream filter.
/// - **muted conversation** — mute is attention-scoped and a ring is the loudest
///   attention there is. Muting a DM and then being rung by it would make mute a
///   lie.
/// - **stale** — older than [kCallInviteFreshness]; see that constant.
///
/// Freshness is measured on the **signed** [OriginEnvelope.signedAtMs], never on
/// the server-assigned [Message.createdAt]. `createdAt` is written by the
/// island, so keying freshness to it leaves the island able to resurrect a
/// genuine week-old invitation by re-stamping it — a replay the "unforgeable"
/// claim does not survive (cage-match #139, Tesla). `signedAtMs` is inside the
/// signature we just verified, so a replay would have to forge the signature.
///
/// **Named tradeoff:** this straddles two clocks (the SENDER's device vs ours),
/// so a peer whose clock is >10s off never rings us. That is the correct
/// direction — the alternative hands the freshness decision to the party the
/// signature exists to distrust. A monotonic fix needs a signed island "now";
/// tracked, not faked.
CallInvite? admitRing(
  Message message, {
  required String meUserId,
  required Set<String> blockedUserIds,
  required bool conversationMuted,
  required DateTime now,
}) {
  if (!isCallInviteBody(message.body)) return null;
  if (message.sender.userId == meUserId) return null;
  if (message.sender.kind != SenderKind.human) return null;
  // The signature check — see the doc above. `originCryptoValid` is computed
  // ONCE at ingest by the repository; `true` is the only admitting value
  // (`null` = unsigned/unverified, `false` = carried-but-invalid).
  if (message.originCryptoValid != true) return null;
  final origin = message.origin;
  if (origin == null) return null; // belt-and-braces: valid implies present.
  if (!isDmChannelId(message.channelId)) return null;
  if (blockedUserIds.contains(message.sender.userId)) return null;
  if (conversationMuted) return null;
  final signedAt =
      DateTime.fromMillisecondsSinceEpoch(origin.signedAtMs, isUtc: true);
  final age = now.difference(signedAt);
  // Negative age (signed in the future by a skewed clock) is not fresh — it is
  // unreadable, and admitting it would let a bad clock ring forever.
  // `!isNegative` is the guard; `> freshness` alone would admit it.
  if (age.isNegative || age > kCallInviteFreshness) return null;
  return CallInvite(
    channelId: message.channelId,
    from: message.sender,
    startedAt: signedAt,
  );
}

/// True when [channelId] is a DM, per the island's `dm:` prefix — which is a
/// gateway CHECK constraint (`ck_channels_dm_prefix`, case-sensitive; island
/// design 11 "Direct messages"), not a client-side naming convention, so it is
/// safe to key a trust decision on.
bool isDmChannelId(String channelId) => channelId.startsWith('dm:');
