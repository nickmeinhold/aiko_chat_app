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
/// **The exact scope of "unforgeable", stated honestly** (cage-match #139 R4,
/// Carnot). A verified origin proves that *the holder of `origin.rawPublicKey`*
/// authored THIS body, for THIS channel, at THIS signed instant. It does NOT
/// prove that the key belongs to the account named in `message.sender` —
/// `sender` is server-supplied metadata and is not covered by the signature. So
/// an island could present a genuinely-signed invitation under a rewritten
/// sender label, which would mis-attribute the caller and slip the block check.
///
/// That gap is APP-WIDE and pre-existing, not introduced here: it is the same
/// reason no affirmative "verified sender" tick has shipped (see
/// `Message.originCryptoValid` — "no affirmative UI ships until a trust root
/// binds key→account"). The ring inherits the app's trust root; it does not
/// weaken it, and it does not get to claim more than it. Tracked separately.
///
/// What the signature DOES buy here, and what the `kind` alternative would not:
/// the sentinel itself, the channel, and the start time are all inside the
/// signature, so a call cannot be conjured by flipping an unsigned field.
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

/// The pinned END body — the caller saying "I hung up". **Signed and durable —
/// never edit this string.**
///
/// A SECOND SENTINEL, NOT A NEW KIND, for exactly the reasons [kCallInviteBody]
/// is one: `signingBytes()` covers the body and NOT `kind`, so a stop carried as
/// a kind would be the one field an island could flip. It carries no parameters
/// either — the call it ends is named by the signed `replyTo`, which is inside
/// the same signature (see [admitCallEnd]).
///
/// WHY THIS IS A SMALLER DOOR THAN THE INVITE. The island does not need to learn
/// it: `push_service` wakes a handset only on the INVITE body, so an end message
/// is an ordinary message to the gateway and this stays an app-side change. And
/// the privilege runs the safe way — forging a *stop* suppresses a ring, which a
/// hostile island could achieve anyway by dropping the invite; forging a *start*
/// lights a camera.
///
/// Worded to mirror the invite so a client predating the feature degrades to a
/// readable line rather than breaking — the human words trailing the machine
/// anchor. This client renders it as an event and never shows the anchor (see
/// `chat_screen`), which is the half that must ship WITH the wire half: without
/// it, hanging up would put `aiko:call/1 · 📞 ended the call` back on screen as
/// a raw bubble — the exact thing the invite's render arm exists to prevent.
const String kCallEndBody = 'aiko:call/1 · 📞 ended the call';

/// True when [body] is the call-invitation sentinel.
///
/// Exact match, deliberately: a `startsWith`/`contains` test would let anyone
/// ring you by typing the sentinel with a word after it, and would make every
/// quotation of this doc a ringing message.
bool isCallInviteBody(String body) => body == kCallInviteBody;

/// True when [body] is the call-END sentinel. Exact match, same reasoning.
bool isCallEndBody(String body) => body == kCallEndBody;

/// A verified hangup: WHICH call ended, and WHO said so.
///
/// It exists so there is exactly ONE door. The end has two consumers — "stop the
/// ring that is ringing now" and "remember this, in case its invitation has not
/// arrived yet" — and the first version gave them different keys: the live path
/// checked caller and channel, the memory checked neither and then suppressed a
/// ring on the target id alone. A third party, or an end from another channel,
/// could pre-poison a ring the live path would have refused (cage-match round 2,
/// Carnot and Tesla independently). An irreversible cache must carry everything
/// needed to replay the original decision, so it carries all three fields and
/// both consumers run [endsInvite].
class CallEnd {
  const CallEnd({
    required this.targetServerMsgId,
    required this.fromUserId,
    required this.channelId,
  });

  /// The island ULID of the invitation being ended — the signed `replyTo`.
  final String targetServerMsgId;
  final String fromUserId;
  final String channelId;
}

/// **Is [message] a verified hangup at all?** The single door, and the only
/// place an end message is ever judged.
///
/// Deliberately says NOTHING about what is ringing. That question is
/// [endsInvite]'s, and separating them is what lets an end that OVERTAKES its
/// own invitation be remembered under the same clauses it would have been
/// admitted under.
///
/// Refusals, each its own clause:
/// - **not the sentinel** — an ordinary message.
/// - **my own echo** — I ended my own call; there is nothing here to stop.
/// - **an unverified origin** — `originCryptoValid != true`. Fail CLOSED, which
///   here means KEEP RINGING. The asymmetry with [admitRing] is deliberate: an
///   unverified *start* must not light a camera, an unverified *stop* must not
///   silence a genuine call. Both refusals preserve the ring.
/// - **a bot** — mirroring [admitRing]. Unreachable while an end must match a
///   human's invitation, but the two gates sit side by side and asymmetric
///   clauses are how a later reader "fixes" the wrong one.
/// - **names no call** — a stop with no `replyTo` is about everything or nothing.
/// - **has no author** — `MessageSender.userId` is null for an external actor.
///   "Only the caller may end the call" is unanswerable without one, and an
///   authorless stop would then be a stop from anybody.
CallEnd? admitCallEnd(Message message, {required String meUserId}) {
  if (!isCallEndBody(message.body)) return null;
  final from = message.sender.userId;
  if (from == null) return null;
  if (from == meUserId) return null;
  if (message.sender.kind != SenderKind.human) return null;
  if (message.originCryptoValid != true) return null;
  if (message.origin == null) return null; // valid implies present
  final target = message.replyToId;
  if (target == null) return null;
  return CallEnd(
    targetServerMsgId: target,
    fromUserId: from,
    channelId: message.channelId,
  );
}

/// Does [end] end [invite]? Applied identically whether the end arrived while
/// the invitation was ringing or before it existed.
///
/// The binding is the SERVER id, and that is not a preference: a live probe
/// showed `reply_to` is an FK onto `messages.id`, so a frame carrying a
/// `client_msg_id` there is refused outright (`no_reply_target`) and the hangup
/// never leaves the device. Comparing the client id would have matched a message
/// that cannot exist.
///
/// FRESHNESS NEEDS NO CLOCK, and that falls out of the binding: a replayed end
/// can only match an invitation still live, and a live invitation is at most
/// [kCallRingDuration] old. Re-delivery is idempotent.
bool endsInvite(CallEnd end, CallInvite invite) {
  final serverId = invite.serverMsgId;
  if (serverId == null) return false; // nothing a reply_to could have named
  // Only the account that started the call may end it, and only in the channel
  // it was started in. (Inherited caveat: `sender` is server-supplied and outside
  // the signature, so this is exactly as strong as the app's trust root and no
  // stronger — see admitRing. What IS signed is the end body and its reply
  // binding; the claim is not cryptographic caller identity.)
  return end.targetServerMsgId == serverId &&
      end.fromUserId == invite.from.userId &&
      end.channelId == invite.channelId;
}

/// An admitted, ringable invitation — the room to join and who is calling.
class CallInvite {
  const CallInvite({
    required this.inviteId,
    required this.serverMsgId,
    required this.channelId,
    required this.from,
    required this.startedAt,
  });

  /// Stable identity: the signed, content-bound `clientMsgId` from the origin
  /// envelope. Two deliveries of ONE invitation share it; two genuine
  /// invitations never do.
  ///
  /// Identity used to be structural (caller + channel + timestamp), which made
  /// "have I already seen this?" unanswerable across a dismissal — press Ignore,
  /// and the same invite replayed through live+history dual delivery within the
  /// freshness window rang all over again (cage-match #139 R2, Carnot). A thing
  /// you must remember having dismissed needs a name, not a shape.
  final String inviteId;

  /// The island's ULID for this invitation — what a hangup's `reply_to` names.
  ///
  /// A SECOND id, and the duplication is the wire's, not ours. [inviteId] is the
  /// signed `clientMsgId`: content-bound, stable across deliveries, and the only
  /// id either party can compute. But the gateway's `reply_to` is an FK onto
  /// `messages.id`, so it resolves the SERVER id and refuses a client one with
  /// `no_reply_target` — verified against the live island, which is the only
  /// place that fact is written down. So identity uses one and the wire binding
  /// uses the other. Null if the island did not name it (it always does for an
  /// inbound message; the field is nullable because [Message.id] is).
  final String? serverMsgId;

  /// The LiveKit room to join. The room IS the channel id (#2726).
  final String channelId;

  /// The caller, as carried on the signed message.
  final MessageSender from;

  /// When the caller started the call — the SIGNED `signedAtMs`, not the
  /// island-written server timestamp. (The two disagree, and only one of them is
  /// inside the signature.)
  final DateTime startedAt;

  /// Equality is IDENTITY, not shape — see [inviteId].
  @override
  bool operator ==(Object other) =>
      other is CallInvite && other.inviteId == inviteId;

  @override
  int get hashCode => inviteId.hashCode;

  @override
  String toString() => 'CallInvite($inviteId, $channelId, from=${from.userId})';
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
///   unplugged one horn of the megaphone (cage-match #139, Tesla).
///
///   [isDm] is resolved by the CALLER from the app's own channel model, and is
///   deliberately NOT re-derived from the channel id here. The first version of
///   this gate tested `channelId.startsWith('dm:')`, citing the island's
///   `ck_channels_dm_prefix` CHECK constraint — and that constraint is real, but
///   it is on `channels.aiko_channel` (the BUS name), while the id the app
///   receives is `channels.id`, a bare ULID. So the prefix never matched and the
///   ring would have refused EVERY genuine DM in production. Six adversarial
///   review rounds missed it because all of them, and I, reasoned from the same
///   design doc; one live `POST /v1/dm` refuted it in a second. The real
///   discriminator is `channels.kind == 'dm'`, which the app already models.
///   Channel-wide calls are a real future feature; they need their own consent
///   model, not this door.
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
  required bool isDm,
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
  if (!isDm) return null;
  if (blockedUserIds.contains(message.sender.userId)) return null;
  if (conversationMuted) return null;
  final signedAt = DateTime.fromMillisecondsSinceEpoch(
    origin.signedAtMs,
    isUtc: true,
  );
  final age = now.difference(signedAt);
  // Negative age (signed in the future by a skewed clock) is not fresh — it is
  // unreadable, and admitting it would let a bad clock ring forever.
  // `!isNegative` is the guard; `> freshness` alone would admit it.
  if (age.isNegative || age > kCallInviteFreshness) return null;
  return CallInvite(
    inviteId: origin.clientMsgId,
    serverMsgId: message.id,
    channelId: message.channelId,
    from: message.sender,
    startedAt: signedAt,
  );
}

// `isDmChannelId` was DELETED here, not merely unused.
//
// It tested `channelId.startsWith('dm:')` and its doc called that "safe to key a
// trust decision on". It is not: the `dm:` prefix is a CHECK constraint on
// `channels.aiko_channel` (the bus name), while the id the app receives is
// `channels.id`, a bare ULID — so the predicate answered false for every genuine
// DM in production. Six adversarial review rounds reasoned from the same design
// doc and missed it; one live `POST /v1/dm` refuted it in a second.
//
// The gate was fixed to take `isDm` from the app's own channel model, which left
// this helper with zero callers — but a dead function is not an inert one. It
// sat one import away from the ring's trust decision, wearing a doc that told
// the next reader it was authoritative, and channel-wide calls are a real future
// feature whose author would have found it and believed it. A confirmed-false
// helper is a loaded gun, so it is removed rather than left for a grep to find.
