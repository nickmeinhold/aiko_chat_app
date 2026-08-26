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
// `encodeMultikey` — the allowlist is keyed on the canonical wire form of the
// signer's key, so a stored entry and a live envelope compare as the same string.
import '../../chat/domain/origin_envelope.dart';

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
/// Confirmed by Nick 2026-08-22 — AFTER first transmission, not before, and that
/// order is recorded rather than tidied. #3198 asked for the same hand-check the
/// invite body got; the live two-party runs that verified this feature had
/// already written the string into signed history by the time it was asked. The
/// cost happened to be nil (a handful of rows from test accounts, no users on
/// older builds) but that was luck, not process.
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
/// The SHAPE of a call end: the pinned body, a human author with an id, and a
/// reply that names the call being ended.
///
/// Shared by the ring and the screen so presentation cannot quietly be more
/// generous than admission. The render arm used to match the BODY alone, so a
/// message the ring would refuse still drew a centred "X ended the call" — a
/// second almost-gate with fewer clauses, which is how a UI ends up narrating
/// events the domain never admitted (cage-match rounds 6-7, Carnot).
/// The SHAPE of a hangup — body, an author, and a call it names. Authorization
/// is NOT here; it lives in [_mayRing], which both admission doors share.
///
/// The kind clause used to sit in this predicate, which quietly made the stop
/// gate COLDER than the start gate the moment `admitRing` widened: an
/// allowlisted resident could wake the handset and then could not silence it,
/// so the ring ran its full 30 seconds after the caller had already hung up
/// (cage-match — Carnot HIGH and Tesla, independently, which is the strongest
/// signal this review produced). A protocol whose start and stop have different
/// admission rules is not a protocol, it is two.
bool _isCallEndShape(Message message) =>
    isCallEndBody(message.body) &&
    message.sender.userId != null &&
    message.replyToId != null; // "names no call" — see admitCallEnd's doc

/// A verified sovereign origin: this key signed these bytes, checked at ingest.
bool _hasVerifiedOrigin(Message message) =>
    message.originCryptoValid == true && message.origin != null;

/// A call END the SCREEN may draw as an event rather than as speech.
///
/// Two deliberate divergences from [admitCallEnd], both about who is asking:
///
///   * YOUR OWN hangup renders (as "You ended the call") where the ring refuses
///     it — you do not ring yourself.
///   * `isMine` also EXEMPTS the origin verdict, and that is not a shortcut.
///     `originCryptoValid` is written when an INBOUND message is verified at
///     ingest; a row this device composed carries the signature it self-verified
///     at sign time and no verdict column, so requiring `true` here would stop
///     the app rendering its own call events at all. There is no adversary
///     between this device and its own cache — the verdict exists to judge
///     what ARRIVED.
///
/// Freshness, DM-ness, blocks and mutes are deliberately absent: they answer
/// "should this ring me NOW", and a call that happened yesterday still belongs
/// in history as an event.
///
/// HONEST LIMIT, stated precisely rather than generally (cage-match round 7,
/// Tesla). `replyToId != null` means "names A message", not "names THIS
/// invitation" — so a person can still type the sentinel as a reply to ANY
/// message and be drawn as a call event. Signing cannot separate them: this app
/// signs at birth, so a typed sentinel is signed exactly like a generated one.
///
/// Closing it needs the reply TARGET resolved and checked for an invitation
/// body, and this screen has no reply-target resolver at all today — it renders
/// no reply previews — so that is new machinery for a cosmetic spoof inside a
/// conversation the reader already chose to be in. Tracked rather than built.
///
/// What these clauses DO stop, which is the part with teeth: an unverified or
/// imported row, a bot, and an authorless actor being elevated into system
/// narration.
/// NOTE the explicit `kind` clause. It used to be inherited from
/// [_isCallEndShape]; that predicate now carries shape only, so the RENDER rule
/// is stated here to keep it exactly as it was. Whether a consented agent's
/// hangup should draw as a system event is a presentation decision, separate
/// from whether it may stop a ring, and it is deliberately NOT changed here.
bool isRenderableCallEnd(Message message, {required bool isMine}) =>
    _isCallEndShape(message) &&
    message.sender.kind == SenderKind.human &&
    (isMine || _hasVerifiedOrigin(message));

/// A call INVITATION the screen may draw as an event. Same authorship floor and
/// the same `isMine` reasoning — fixing only the hangup would have left the
/// identical leak one line above it.
bool isRenderableCallInvite(Message message, {required bool isMine}) =>
    isCallInviteBody(message.body) &&
    message.sender.userId != null &&
    message.sender.kind == SenderKind.human &&
    (isMine || _hasVerifiedOrigin(message));

CallEnd? admitCallEnd(
  Message message, {
  required String meUserId,

  /// The SAME consent set [admitRing] is given. A hangup is admitted by exactly
  /// the rule that admitted the ring — see [_isCallEndShape].
  required Set<String> ringAllowedKeys,
}) {
  if (!_isCallEndShape(message)) return null;
  if (!_hasVerifiedOrigin(message)) return null;
  final origin = message.origin;
  if (origin == null) return null; // verified implies present
  if (!_mayRing(message.sender, origin, ringAllowedKeys)) return null;
  final from = message.sender.userId!;
  if (from == meUserId) return null;
  final target = message.replyToId!;
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
  // Only the account that started the call may end it, and only in the channel
  // it was started in. (Inherited caveat: `sender` is server-supplied and outside
  // the signature, so this is exactly as strong as the app's trust root and no
  // stronger — see admitRing. What IS signed is the end body and its reply
  // binding; the claim is not cryptographic caller identity.)
  return end.targetServerMsgId == invite.serverMsgId &&
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
  /// uses the other.
  ///
  /// NON-NULLABLE, and that is a claim about the ingest layer rather than a
  /// convenience. Every message that can reach a ring is built by
  /// [Message.fromView] — live fanout (`gateway_transport.dart`) and history
  /// (`gateway_rest_api.dart`) both — and that factory reads the id as
  /// `v['msg_id'] as String`, a hard cast: a frame without one throws there and
  /// never becomes a [Message] at all. [Message.id] stays `String?` for the
  /// LOCAL optimistic row, which is this device's own echo and is refused by
  /// [admitRing] one clause earlier.
  ///
  /// It was `String?` for one round, purely because [Message.id] is — and three
  /// separate guards grew on that nullability (an upgrade-on-replay branch here,
  /// a null check in [endsInvite], a nullable-key map lookup in the ring). All
  /// three defended a state the cast above makes unrepresentable, and the dead
  /// branch went on to generate a HIGH review finding for a bug that could not
  /// occur. Refusing the null at the door deletes all three.
  final String serverMsgId;

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
/// May this sender ring at all — the kind gate, widened by explicit consent.
///
/// The plain reading of `kind != human` is "no bots". That is NOT what it does
/// on the live gateway, and the gap is invisible from inside this repo. The
/// deployed island reports the sender's kind as:
///
///     if sender_user is not None: return "human"   # ANY account, unconditionally
///     if channel.kind in ("llm","robot"): return channel.kind
///     return "actor"
///
/// So `kind` answers "did the sender hold an account?", never "is the sender a
/// person" — and the clause only ever fires on `actor`, the accountless bus
/// participant. Measured, not inferred: a resident agent holding its own account
/// and key rang a real handset through this path on 2026-08-26, and the gateway
/// labelled it `human`. The island's unreleased source starts reporting true
/// kinds (island #3096), at which point that same resident would be refused —
/// a capability regressing with no change here. This is the widening that has to
/// land first (claude-tasks#3448).
///
/// Three properties, each chosen against a specific way this could go wrong:
///
/// 1. **Keyed on the KEY, never the account or the label.** `signingBytes`
///    covers the pubkey; `sender.userId` and `sender.label` are server-supplied
///    and NOT covered, so an island in the middle can rewrite them (the app-wide
///    key→account gap, #3166). An allowlist keyed on anything the island can
///    rewrite is an allowlist the island controls.
///
/// 2. **Consulted only AFTER the signature verifies** — enforced by call order
///    in [admitRing]. Scoped honestly: this is defence for a future refactor,
///    NOT a property today's tests establish. Reversing the two still refuses,
///    because the crypto check runs before any invite is returned either way;
///    the test that claimed to pin the order was void and now pins the real
///    invariant instead (an unverified envelope never rings, consent or not).
///
/// 3. **An allowlisted ringer must still be BLOCKABLE** — against an island that
///    is BUGGY, not one that is LYING. `userId != null` is required, so
///    allowlisting a keyed-but-accountless actor cannot mint exactly the
///    unblockable ringer the `actor` refusal exists to prevent: consent that
///    cannot be withdrawn is not consent.
///
///    SCOPED, because an earlier version of this comment claimed more than the
///    code can deliver (cage-match round 2, Carnot HIGH). `sender.userId` is
///    server-supplied and OUTSIDE `signingBytes` — the same fact property 1
///    relies on — so a HOSTILE island can staple any non-null id to an
///    accountless actor and satisfy this check while the id names nothing the
///    block path can reach.
///
///    That is not a hole this gate opens, and the reason matters: `kind` is
///    unsigned too, so a hostile island already bypasses the allowlist entirely
///    by reporting `human`. Against that adversary nothing here helps, and the
///    honest answer is the app-wide key→account trust root (#3166), not another
///    clause. What this check DOES buy is real and worth keeping: it closes the
///    island's own `actor` arm, where `userId` is genuinely null, and it holds
///    for every sender rather than only allowlisted ones.
///
/// Everything else still applies: block, mute, DM-only, freshness, own-echo. The
/// allowlist widens ONE gate; it is not a bypass.
bool _mayRing(
  MessageSender sender,
  OriginEnvelope origin,
  Set<String> ringAllowedKeys,
) {
  // FIRST, for EVERY sender — not only allowlisted ones (cage-match, Carnot
  // HIGH). The earlier version returned true for `human` before this check, so a
  // malformed or hostile island row with `kind: human` and a null `userId` rang
  // and then could not be blocked: `blockedUserIds.contains(null)` never
  // matches. Whoever may wake you must always be someone you can name and
  // refuse. Closing it at the single door rather than per-branch.
  if (sender.userId == null) return false;
  if (sender.kind == SenderKind.human) return true;
  if (ringAllowedKeys.isEmpty) return false; // the overwhelmingly common path
  return ringAllowedKeys.contains(encodeMultikey(origin.rawPublicKey));
}

CallInvite? admitRing(
  Message message, {
  required String meUserId,
  required Set<String> blockedUserIds,

  /// Multikey (`z…`) public keys this handset has consented to be rung by even
  /// though the island does not call them people. DEVICE-LOCAL by design — see
  /// [_mayRing]. Empty is the correct default and preserves the old behaviour
  /// exactly.
  required Set<String> ringAllowedKeys,
  required bool conversationMuted,
  required bool isDm,
  required DateTime now,
}) {
  if (!isCallInviteBody(message.body)) return null;
  if (message.sender.userId == meUserId) return null;
  // The signature check — see the doc above. `originCryptoValid` is computed
  // ONCE at ingest by the repository; `true` is the only admitting value
  // (`null` = unsigned/unverified, `false` = carried-but-invalid).
  //
  // MOVED AHEAD OF THE KIND GATE, and the order is now load-bearing rather than
  // incidental: the kind gate below may consult the SIGNER'S KEY, and a key read
  // off an unverified envelope is a key anyone can claim. Verify, then consult.
  if (message.originCryptoValid != true) return null;
  final origin = message.origin;
  if (origin == null) return null; // belt-and-braces: valid implies present.
  if (!_mayRing(message.sender, origin, ringAllowedKeys)) return null;
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
  // The island's id is REFUSED here rather than carried as a null. Unreachable
  // via either production producer (see [CallInvite.serverMsgId]) — so this is
  // the door where an impossible state stops being representable, not a runtime
  // hope. A ring with no server id could never be stilled by a hangup anyway:
  // `reply_to` is an FK onto `messages.id`, so there would be nothing to name.
  final serverMsgId = message.id;
  if (serverMsgId == null) return null;
  return CallInvite(
    inviteId: origin.clientMsgId,
    serverMsgId: serverMsgId,
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
