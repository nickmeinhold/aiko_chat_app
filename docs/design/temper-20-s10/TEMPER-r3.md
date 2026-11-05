# TEMPER round 3 (final) — design 20 §10

**Overall verdict:** UN-TEMPERED (provisional). Round 3 of 3; the cap is reached.
**Struck:** dt-1792894637, 2026-10-25. Maxwell SOUND; Noether, Carnot and Tesla RECAST; no dark seat.
**The bundle carried a DECIDED-CONSTRAINTS file this round** (Nick's rulings, platform measurements, island facts), so the panel could see what a fix must not cross.

## The round-3 question: is it shrinking toward the fix?

**No.** Under Nick's round-cap rule (2026-08-23) a non-shrinking run escalates to a design pass, never to a fourth round. Most of round 3's findings are defects that round 2's own folds introduced:

| Round-3 finding | Raised by | Introduced by |
|---|---|---|
| Epoch inside every message signature changes the shipped `aikochat:msg:v1` contract, and old verifiers fail closed | Noether, Tesla, Maxwell | round-2 freshness fold |
| The consent bucket is chosen by the caller (conversation id inside the seal), and a lookup miss falls through to "DMs default ON" | Noether | round-2 seal fold |
| The push handler has no index into a per-account snapshot (the payload names no account) | Tesla, Noether | round-2 per-account fold |
| Two devices sharing one key both write epoch n+1: a fork, with no way to give the other device the private half | Carnot, Tesla, Noether (silent rotation) | named in round 2, never folded |

Maxwell's SOUND is the author's vote, and it was the outlier. Three adversaries found the four rows above, and Maxwell found only the first.

## Other round-3 findings (for the design pass)
- The snapshot must encode the 2026-09-01 defaults (DM allowed unless revoked); the store is a positive set (Tesla).
- The capability bit is **replaced on every registration**, never latched (Tesla).
- Directional pins narrow DM reachability ("both must have spoken"); state it and tell Nick (Noether F6).
- The cutover cost lands on adopters, and the unsealed tier-3 path has no retirement date (Noether F5).
- If report-then-end proves visible (unmeasured), the table's four refusal rows all look the same to the user (Noether F4).
- Small items: the snapshot's at-rest class; native dedup by call id; trial-open across accounts.

## Bundle error, the author's
DECIDED-CONSTRAINTS listed "2026-08-25: sender anonymity on the ring path is in scope" as a decided ruling. **It isn't.** The record says Nick has never ruled on it ("appetite, not requirement"). Carnot's top finding (the island sees a caller-attributed invite) rests on that line. The disclosure is real and pre-existing (designs 12/16), §10 doesn't worsen it, and it remains **undecided**, not violated.

## Disposition: a design pass, not a fourth round
Candidate, which dissolves the largest cluster: **derive the X25519 key from the signing seed** with a domain-separated KDF, instead of minting and rotating it on its own. Every device holding the seed computes the same K. That leaves no second writer and no fork, no private-key distribution, and no epoch (so the message contract is untouched), and old seals still open because their K can be re-derived. K changes only when the signing key changes, which is the recovery-key path (ADR-0009 ref. 5). **Specialist gate first:** the 2026-09-15 review said "two keys", and whether two keys derived from one seed counts as reuse is the question to put to them. Then a fresh `/design-temper` on the recast.

---
<!-- Per-family strikes, arrival order -->

## MaxwellMergeSlam's Design Strike (round 3)

**Verdict:** SOUND

**Summary:** Two rounds of folding have closed the architecture: what remains is specialist work, one measurement, and decided tradeoffs, with one compatibility note to write down.

`Hans Gruber: "Now I'm going to count to three."` Third round. Nothing in what's left is fatal at this altitude.

I checked each fold against DECIDED-CONSTRAINTS:
- **Carrier and gate 7:** the IdentityDoc statement, accepted only for a signing key pinned from a signed message, crosses no ruling. Fetching when a DM opens reveals nothing the island doesn't already see from DM membership (2026-08-25 and 2026-09-05 hold).
- **Refusal:** branch (c) plus no key, no system ring, in two halves, with per-device capability cutover. That matches the 2026-10-25 rulings and the island's "missing means not capable".
- **Rate:** the per-recipient budget plus `block`. The per-pair counter is withdrawn, so 2026-09-01 holds.
- **Lost device:** the recovery key (ADR-0009 ref. 5) is named as the fix and correctly left undesigned.

**Fatal flaws:**
- None at architecture altitude.

**What holds:**
- Consent never touches the wire, and a withdrawal sends nothing.
- One account statement with a monotone epoch, freshness carried on messages, and rollback by omission defeated.
- Two stores (Keychain custody with a named class and cost; an atomically replaced policy snapshot per account), and admission requirements inside the seal.
- DM-only scope, stated honestly. Tier-3 removal is tied to capability and to the release.

**If RECAST, what to fold back (notes, not fatal):**
- **§10.0 step 3 changes the message-signing contract.** Putting the K epoch *inside* every message's signature means a new `aikochat:msg` version, and an app that predates it may show new messages as unverified. Either carry the epoch as a sibling signed field under the key statement's own tag, which old clients ignore, or bump to `msg:v2` deliberately, with old-client behaviour stated. The specialist picks; §10 should name the compatibility cost.
- **The caller's signed display name is self-asserted.** It's bound to the pinned key, so a peer you allowed can't pose as someone else's key, but they can call themselves anything. That's the same as a DM handle today, so name it, don't fix it.


## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The design conserves "a ring is sealed to a key the caller learned from speech, judged against a device-local map of consent" — but the map's key is handed to the party being judged, and the key's epoch is advanced on a channel that carries no speech, so neither invariant survives the path where the caller picks the bucket or the callee rotates silently.

**Fatal flaws:**

- **F1 — Consent is looked up in a bucket the caller chooses. (§10.3; §10.5 outcomes table, row 2.) CLASS: wrong key-holder / a known defect class re-opened.** The seal carries "the conversation id, used to look up consent (never the outer payload's `c`)". The island must not pick the bucket — correct — but the *caller* now does, and the caller is exactly the party consent exists to restrain. Nothing binds the claimed id to the conversation the invite was actually delivered in, and nothing states what a lookup *miss* means. Two paths break the invariant: (a) a caller revoked in DM X sends the invite into DM Y and claims Y — if Y's DM default is ON, it rings; (b) a caller claims an id the device has never seen — if the miss falls through to "DMs default ON", it rings. Path (b) is verbatim the defect `ring_allowlist_store-header.dart` records for the first version ("a key blessed anywhere could wake you from anywhere"), arriving through the conversation id instead of the key. Per-conversation consent is conserved only if the bucket is chosen by something the judged party cannot steer.

- **F2 — The epoch invariant is advanced by two channels; only one of them is speech. (§10.0 step 3; §10.1.) CLASS: ordering — a broken invariant across a silent event.** The caller's cached K advances *only* on the peer's messages ("it seals only to a cached K whose epoch matches the latest epoch seen on that peer's messages"). The callee's private K advances on *rotation*, a device action. §10.1 retains no superseded private K. So: callee rotates to n+1 and doesn't speak; the caller still holds K@n and still knows epoch n, so it seals to K@n and requests a wake; the callee holds only K@n+1; the seal fails to open; §10.5's table converts a friend's legitimate call into report-then-end until the callee next sends a message. Unbounded if the callee stays silent. The epoch high-water mark is a conserved quantity only if rotation is gated on the channel that publishes it.

- **F3 — Freshness rides inside the shipped message signature. (§10.0 step 3; queue items 1 and 6.) CLASS: coupling that should be removed rather than guarded; blast radius under-counted.** "Every signed message carries the sender's current K epoch inside its signature" mutates `aikochat:msg:v1:EdDSA` — the byte contract the island pins with golden vectors, that every verifier and every pin depends on, and that queue item 6 records as *shipped, never specialist-reviewed*. A ring feature is being charged to every message ever signed. And the benefit is narrower than it reads: the attack it defeats is island *omission*, and the island can produce the same denial by dropping the push — so what the epoch buys is "no flash instead of a flash", a benefit whose value is bounded entirely by F4's unmeasured behaviour.

- **F4 — The §10.5 decision is contingent on an unmeasured platform behaviour with no stated contingency. (§10.5, "Measurement owed before build".) CLASS: missing failure mode.** Decision (c) rests on report-then-end being an acceptable outcome. What a locked iPhone *shows and sounds* during it has never been measured, and the doc's own sentence — "if it's visible or audible, 'no system ring' means 'a flash at the ceiling's rate', and the ceiling is the only thing bounding it" — describes a different product: the allowlist's reworded job ("how the wake presents") collapses to "whether you are disturbed", four of the five table rows present identically, and the only remedy is `block`, which requires the user to be awake and inside the app.

- **F5 — The cutover's cost lands on the adopter, and the tier-3 path is never retired. (§10.5.) CLASS: under-counted blast radius / missing deprecation.** "Nobody goes dark at once" is true for the *laggard*; the device that declares the capability goes dark immediately — to every caller that has not updated *and* to every peer it has not mutually spoken with — while the caller's app shows "ringing" and the callee's handset shows nothing. The adopter is the enthusiast, and the design makes updating strictly worse for them. Meanwhile an un-updated device keeps today's unsealed tier-3 ring forever: the hostile-island ring path this whole design exists to close has no retirement date.

- **F6 — Constraint check, surfaced rather than buried. (§10.0 step 2; §10.5; DECIDED-CONSTRAINTS 2026-09-01.) CLASS: silent narrowing of a decided ruling.** The round-2 fold "pins are directional — the caller must have spoken too" keeps the letter of Nick's ruling (consent stays per-conversation, device-local, keyed on the signing multikey) but changes its effect: DM consent defaults ON, yet no DM peer can ring you until you have both exchanged signed messages *and* both updated. That is a product-visible change to a decided ruling and should go to Nick as such, not live in §10.0 step 2 as a mechanism detail. Not invalid — but it is no longer the consent default that governs reachability, and the doc should say so. (The per-pair counter withdrawal *is* handled correctly: §10.5 names its collision with the 2026-08-25 and 2026-09-01 rulings, which is exactly what a fold must do.)

Smaller, one line each: the policy snapshot is a readable list of who may ring you, and its at-rest class is unstated while the private K's is named (§10.3 vs queue item 9); the call id's role as the CallKit UUID is unstated, so a retried or duplicated push has no native dedup (§10.3, §10.5); with two accounts on one handset the seal's "intended recipient" is the only thing routing the open, and trial-open across accounts is unstated (§10.3, ADR-0009).

**What holds:**
- The core architecture: one published account-level X25519 key, sealed invites, native verification before CallKit, consent device-local. §10.0 step 1's move off the DM carrier is right and is verified against the island's own read (`models.py:814`; sealing the certificate was circular, and cutting the tie dissolves it).
- Pin-from-speech as the binding. The island holds no signing key, so it cannot forge a message or a statement; the pin comes from the one channel it cannot forge, and §10.0 step 2's alignment of "can be sealed to" with gate 7 is honest.
- Withdrawal by doing nothing. No grant and no withdrawal reaches the island; 2026-08-25 and 2026-09-01 are conserved.
- "No key, no system ring" as a *callee-side* rule. The caller-side half is a courtesy the wire cannot enforce, and the design knows it: the callee's report-then-end is the real enforcement, and it holds against a hostile island, an old island, and a junk-attaching peer alike.
- The per-device capability cutover, and "a missing capability field means NOT capable" — it lets the island deploy first without silencing the installed base.
- The two-store split (§10.3) and the DM-only descope (§10.4) — round 2's corrections, correctly folded.
- **The folds are honest.** I checked every round-1 and round-2 disposition against the text: R1-1 (must-report) → §10.5(c), decided by Nick; R1-2 (gate 7) → the statement leaves the DM; R1-3 (socket) → IdentityDoc `verificationMethod[]`; R1-4 (rotation/replay) → monotone epoch, superseded rejected; R1-5 (native source of truth) → §10.3; R1-6 (tier-3 downgrade) → no key, no system ring; R1-7 (groups) → round 1 wrongly called them free and round 2 descoped them. R2-1 → §10.1 + ADR-0009 ref. 5; R2-2 → epoch-on-message; R2-3 → per-device capability; R2-4 → per-pair withdrawn with the collision named; R2-5/6/7 folded. Nothing is marked folded that is not in the text.
- The island's IdentityDoc build is named as structural (storage, endpoint, wire shape, cage-match), not as free; the recovery-key cost is inherited from ADR-0009 and explicitly not fixable here; formats and constructions are correctly deferred to `crypto-review-queue.md`. What remains after F1–F6 is specialist work and named tradeoffs, not an unfounded premise.

**If RECAST, what to fold back:**
- **§10.3:** state that a conversation id with no consent entry is **not admitted** — native never infers the DM default; Dart materializes the default into the snapshot for known conversations — and require the sealed conversation id to equal the outer `c`, so the bucket is the delivery conversation. Add one sentence stating the residual: because DM consent defaults ON, per-conversation consent is per-peer in effect for any conversation the caller can send into, and `block` is the revocation that sticks.
- **§10.1:** add the retention rule for a superseded epoch — the device keeps the previous private K until an outgoing message has carried the new epoch, or the new epoch does not take effect until it has been published — with the grace window stated in the contract.
- **§10.0 step 3:** move the epoch out of the message signature's bytes (its own tag in the envelope, or a short-validity callee-signed statement), name the version transition and old-verifier behaviour, and re-weigh the mechanism's value after F4's measurement.
- **§10.5:** make the report-then-end measurement a build gate; state each row of the outcomes table as the user experiences it; name the re-decision (Nick) if it is visible or audible; add a deprecation point after which the island stops sending unsealed VoIP to *any* device, and say what the callee sees for a suppressed wake.
- **§10.0 step 2 / §10.5:** surface "pins are directional" to Nick as a change in the effect of the 2026-09-01 DM default-ON ruling, not as a mechanism detail.
- **§10.3:** pin the policy snapshot's at-rest class alongside the private K's; state the call id's role as the CallKit UUID/dedup key; state the multi-account open path and that a failed open is a denial.

## CarnotCodeCarver's Design Strike (round 3)

**Verdict:** RECAST

**Summary:** The folds remove substantial wasted work, but two architectural gaps remain: the ring path still exposes its caller to the island, and account-wide key rotation has no multi-device coordination protocol. Neither is a question of cryptographic bytes. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are.

**Fatal flaws:**
- Sender anonymity remains contradicted by the transport. The decided constraints explicitly put WHO IS CALLING in scope. Yet the island receives a caller-attributed DM invite, recognises its call meaning, routes it to the recipient, and recognises the named sealed-envelope field. Encrypting the inner invite hides its contents from Apple; it does not hide the caller from the island handling that request. Withdrawing per-pair counters removes retained history, not knowledge at dispatch. The accepted denial-of-ring tradeoff does not waive sender anonymity. §10 needs an anonymous wake-request architecture or an explicit Nick decision permitting this disclosure; the latter crosses a decided constraint.
- Rotation is still an account-wide distributed write without a coordination design. Every device copies the same keys, but §10.1 lets the current signing key authorise a successor without specifying who creates it, how every device acquires its private half, or when it becomes current. Two honest devices can publish different Ks at the same next epoch; an offline device can keep signing messages with the old epoch after another device advances. A caller's high-water mark cannot distribute secrets or resolve equal-epoch forks. The capability flag proves software support, not possession of the current private K. This is the second-writer problem from round 2, still unfolded.

**What holds:**
- Moving the statement out of DMs honestly removes automatic speech, unread counts, notifications and duplicated account state. Separating public key distribution from local consent removes the consent-event leak.
- The must-report fold is honest about the chosen branch, the missing entitlement and the unmeasured presentation. Report-then-end visibility is a named measurement gate, not grounds to reopen Nick's decision.
- The lost-device limitation is honestly priced. Shared signing keys cannot distinguish owner from thief; future recovery certification is explicitly unfinished.
- Per-device capability rollout, DM-only scope, separate secret custody and policy snapshots, and the structural cost of IdentityDoc are meaningful corrections.
- Epochs reject statements older than locally observed signed evidence. They do not establish global freshness when the island withholds that evidence; the claim should retain that boundary.
- The recipient wake budget and accepted denial-of-ring exposure are owned tradeoffs. Reintroducing per-pair counters would violate the decided constraints.

**If RECAST, what to fold back:**
- Draw the complete ring-request path and mark exactly where caller identity, recipient identity and call meaning become observable. Resolve the sender-anonymity contradiction before calling the architecture sound. If retaining today's attributed dispatch is proposed, explicitly ask Nick to amend the anonymity ruling; do not present sealing as satisfying it.
- Delete routine X25519 rotation from v1 unless its account-wide coordination is designed. A fixed shared K until account recovery avoids introducing an unsupported distributed state machine and preserves the one-copied-key ruling. If refresh stays, specify rotation authority, successor-secret distribution, concurrent-update resolution and behaviour of offline devices before publication.
- Correct the snapshot race description: an atomic replacement prevents torn reads, but does not bound the read-to-CallKit interval to the duration of the write. Keep the accepted stale-admission tradeoff, describe its actual boundary, and specify snapshot invalidation on sign-out.
- Keep construction and encoding with the human cryptographer. Identity disclosure and multi-device publication ordering belong to the architecture review. Dijkstra: "Simplicity is prerequisite for reliability." Delete the unsupported rotation machinery before adding guards around its entropy.


## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration." The score is true, and it still shakes where the folds left three live tones in the glass: two devices share one signing key and both write the epoch, that epoch is cut into the signature of every message, and the 3am handler has no index into the snapshot, so a legitimate ring and a junk wake are the same flash.

**Fatal flaws:**
- **The second writer was dropped on the floor (§10.1; ADR-0009 ref. 4; temper-r2 Tesla line).** Round 2 named it: a second writer cancels the epoch. The synthesis folded omission and the cold cache, and §10.1 still speaks as if an account has one successor, "epoch n+1, signed by the current signing key." Ref. 4 copies that signing key to every device, so every device is a clock. Two honest handsets each sign epoch n+1 over a different K. Peers match the integer (§10.0 step 3), fetch the one IdentityDoc the island happened to store, and seal to whichever private half is not on the phone that is locked in the other room. Open fails, the row taken is report-then-end, and the remedy Nick already accepted for a *hostile peer* is `block`. At 3am you block the friend. The public statement cannot carry the new private half to the other device, and the recovery key that could re-seat a successor is explicitly not designed yet. Routine refresh is specified as if it converges. It forks.
- **Freshness is welded into the shipped speech contract (§10.0 step 3; crypto-review-queue item 6).** "Every signed message carries the sender's current K epoch inside its signature" is the omission fix, and it is the right *channel* (the island can drop speech and cannot rewrite it). It is also a change to `aikochat:msg:v1`, the byte contract that already shipped and has never had a specialist's name on it. Old verifiers fail closed on the new bytes. The island is a carrier: it delivers the message anyway, and half the installed base watches the conversation that was supposed to prove freshness go unverifiable. The fold defeats a stale IdentityDoc by shaking the speech the epoch rides in. Queue item 1 asks the specialist *where* the bytes sit. The architecture never says what the installed base does while they move. Absence of an epoch (every message already in a conversation) and a forked epoch (flaw above) both fail the same way: the caller still has a cached K whose integer matches, requests a VoIP wake, and the callee's handset takes the flash row.
- **The snapshot is keyed per account and cannot be selected at wake time (§10.3; header on inherited consent).** Round 2's store fold is half-honest: secret custody is split from policy, the write is atomic, and "never the active account" is the right warning. The read is "whichever whole snapshot is current." A VoIP payload is still `c` plus an opaque blob (§4, Decision 6). It does not name an account. ADR-0009's premise is two accounts on one handset, one install, one PushKit handler. The handler that consults "the current snapshot" applies the foreground covenant to the background one, which is the inherited-consent defect the allowlist header already survived once, or it fail-closes and every ring for the account that is not "current" is report-then-end. Sign-out ordering, which round 1 required and round 2 did not write back, has the same shape: K and snapshot left behind, token still registered, and a signed-out account keeps waking. The one-write revocation window is named and small. The missing index is steady state.
- **Steady state inherits an empty allowlist (§10.5 "a peer you allowed"; 2026-09-01 default ON for DMs, OFF for groups; the store header).** The header is a positive set of multikeys. Empty means nobody. The ruling of record is the opposite for DMs: allowed until a local revoke, groups dark. §10.5's table sends "conversation not allowed" through report-then-end. If the snapshot ships the header's emptiness, every friend who has spoken, whose K is cached, whose seal opens and whose signature verifies, still takes the flash row. The accepted cost in §10.5 describes the cutover ("until both sides have the update"). It does not describe the steady state. What a locked phone shows and sounds during report-then-end is still unmeasured, and this reading makes that row the common case, bounded only by the recipient's 6 per minute.
- **Capability is described as a declaration, and the platform fact is a replacement (§10.5; decided constraint on `install_id`).** A missing capability field means not capable. §10.5 says a device "declares that capability when it registers" and the island then stops unsealed VoIP toward it. Said that way, the bit latches. A rollback, a restore, or a registration that omits the field leaves the island suppressing unsealed wakes toward a binary that cannot open a seal. Old callers go dark, and sealed wakes from new callers hit an app whose only ring is the unverified tier-3 path that same release was supposed to remove. Round 2's cutover fold is honest about island-deploys-first. It does not say each registration replaces the bit.

**Fold audit, so the honest parts stay put.** Round 1's trilemma, the per-DM post that self-satisfied gate 7, the IdentityDoc socket, the tier-3 downgrade, and the false "channels are free" claim are folded in truth: §10.0, §10.4, and §10.5 match Nick's choices, including "denial of ring is accepted" and the refusal of a per-(caller, callee) counter. Round 2's stolen-device window is honestly inherited by ADR-0009 ref. 5 and not pretended fixed. The per-pair rate is honestly withdrawn. Directional pins, agent speech, the island's real IdentityDoc cost, and the DM descope match the record. The crypto queue no longer describes the per-DM carrier. What was not folded is the second writer and the push-time read.

**What holds:**
- The tie stays cut. Publishing K in the account's IdentityDoc does not tell the island who consented, and withdrawing consent sends nothing (§10.0 step 6). That is the load-bearing decision, and it still holds under both tempers and the island's plaintext-DM read.
- Branch (c) is a real choice, with both halves: an honest caller with no cached K requests no VoIP wake, and an unsealed push is report-then-end (§10.5). The must-report counter is measured. Reopening (a) or (b), or putting a caller key on the island's wake budget, would cross rulings of record.
- Gate 7 still means conduct. Nothing in §10 posts into a DM, sealability may run ahead of wakeability across channels, and it cannot run behind. The island said so, and §10.5 records it.
- The envelope's shape check stays on the push blob (§8.1, §10.6.4). The island does not learn certificates. Opacity stays honest.
- One copied key, the thief window, first-contact substitution, the group fan-out, the `AfterFirstUnlock` gap, and the unmeasured flash are named as owned. Formats, HPKE versus a hand-rolled seal, and whether speech-TOFU is the binding #316 asked for belong to the specialist. None of those are grounds to melt the ore.

**If RECAST, what to fold back:**
- **§10.1 — one writer until the private half is copied.** State that a routine X25519 refresh is out of scope until a copy path has placed the new private K on every device of the account, and that only then may a statement be published. Until that path exists, epochs do not move; the only successor is ADR-0009 ref. 5, still undesigned. Add the collision rule a specialist cannot invent for you later: two signed statements at the same epoch, or a message epoch whose K differs from the fetched statement, are "no K" (caller requests no VoIP wake). A holder of the signing key can still mint a higher epoch; say that this is the already-accepted thief window, so nobody reaches for `block` when the other handset forked.
- **§10.0 step 3 — the speech contract has a stop condition.** Keep freshness on speech. Add that the epoch does not enter `aikochat:msg:v1` in place. New messages carry it under a versioned domain whose transition is explicit: messages with no epoch verify as they do today and mean "no K, no system ring"; a placement that makes old clients fail closed on ordinary speech does not ship. The specialist owns the bytes (queue items 1 and 6). The design owns the stop.
- **§10.3 — how the handler picks a covenant.** Replace "whichever whole snapshot is current" with the lookup the payload allows: try each account's Keychain K, then read only the policy snapshot for the K that opens the seal. Any other account's consent is invisible to that push. Sign-out deletes that account's snapshot and drops its push registration, so a signed-out account is not woken into a strobe. In the same paragraph, write the default the ruling already made: DMs are allowed until a local revoke, groups are not. An empty positive set is not the steady state.
- **§10.5 — the capability bit is replaced, not latched.** One sentence: every push-token registration overwrites the capability flag for that `install_id`, and a missing field clears it. The island suppresses unsealed VoIP only while the latest registration declared the capability.
