# Design 20 — the sealed ring envelope

| | |
|---|---|
| **Status** | **PROPOSAL — arm C ACCEPTED IN PRINCIPLE by the island tab 2026-09-11 15:55, with three conditions (§8). Un-tempered.** §4a's key-reuse route was answered AGAINST by an external review on 2026-09-15 (#316: use two keys; the binding is the real blocker). **§9 (2026-10-24) proposed that ring consent carry the second key; the island tab's read (2026-10-25) broke it, because the island can read DMs. §10 recasts: one published account key, used only for peers pinned from real speech; consent stays on the device. Tempered 4/4 RECAST (`temper-20-s10/TEMPER.md`), folded; refusal decided by Nick (§10.5: no key, no system ring).** |
| **Owner** | Claude (app tab), 2026-09-11 |
| **Answers** | claude-tasks#4254 question 3 — *what does Swift verify before reporting to CallKit, and where do the bytes come from?* |
| **Provoked by** | Nick, 2026-09-11 15:38: *"it feels like there could be a better solution… how does Signal do it?"* That was a pointer at prior art, and it was right. |
| **Supersedes** | The A-or-B fork this tab put to Nick at 15:35. **That fork was a false dilemma** and this document exists because it was. |

---

## 0. The question, and why it is live today

When a VoIP push wakes a locked handset, Swift must report to CallKit **before the delivery
handler returns** — iOS 26 terminates the app otherwise, and repeated failures cost per-device
VoIP delivery. Design 16 v2 §1 says Swift should *verify Ed25519 over the signed bytes* first.

**The island's VoIP payload carries no signed bytes.** `_render` returns
`{"aps": {...}, "c": channel_id}` and its own docstring says `"c"` is the only custom field.
So §1's admission architecture has no input, and §0's *"proof needs nothing from the payload"*
does not survive contact with the renderer.

**What changed on 2026-09-11 ~14:41 AEST:** the conduct gate deployed (v0.11.1, both islands,
`b7dafac` verified an ancestor of the running sha). A stranger can no longer wake a handset.
So client-side verification is **no longer defending against "a stranger rings you"** — the
island refuses that itself. Its remaining job is defending against **a hostile or compromised
island**, which is a different question and a real one under federation.

## 1. The fork that was wrong

This tab put two arms to Nick:

- **A** — payload carries the signed invite; **Decision 6's opacity is spent.**
- **B** — trust the island; Swift reports whatever arrives.

**Both arms accept a premise that is false: that putting the identity in the payload means
exposing it.** It does not, if the identity is sealed.

## 2. Prior art — what Signal actually does

**Verified** in `signalapp/Signal-iOS`, `SignalNSE/NSECallMessageHandler.swift`:

- Signal's server sends an **`alert` push, not a VoIP push**, and **the payload carries the
  encrypted content itself**.
- A **notification service extension decrypts it on-device**, then asks RingRTC whether this
  is a valid call offer — `isValidOfferMessage(opaque:messageAgeSec:callMediaType:)`, checking
  message age and media type.
- Only on success does it call
  **`CXProvider.reportNewIncomingVoIPPushPayload(payload.payloadDict)`**, which launches the
  containing app to report to CallKit.
- On failure it logs a missed call. **No phone rings.**

**The server renders no verdict, because it cannot.** Sealed sender means it does not know who
is calling, or that this is a call at all. The decision is made where the fact is — on the
device, after decryption.

### Two asymmetries, so this is not copied wholesale

1. **Signal holds `com.apple.developer.usernotifications.filtering`.** They ship this path, so
   the entitlement is demonstrably grantable to an E2EE messenger. Our 2026-09-11 08:30 spike
   proved the **unentitled** case fails (`CXError` code 2, positive control `didReceive FIRED`).
   It did **not** test whether we could be granted it. `RESEARCH.md` §11a's *"closed"* is
   "closed today, for that spike" — already corrected after the design 19 temper.
2. **Signal needs the NSE because its server cannot tell a call from a message. Ours can** —
   the island matches `CALL_INVITE_BODY` in cleartext. So **we do not need the NSE path**, and
   should not reach for it: it costs an Apple-granted entitlement to buy a capability we
   already have.

## 3. The reframe

Decision 6, quoted from `push_result.WakePayload`:

> A push provider is an intermediary we cannot remove, and it can read everything we send it.
> A payload saying "Alice is calling you" would tell **Apple or Google** who calls whom.

**Decision 6 protects a property of the READER, and is written as a property of the PAYLOAD.**
Stated as *"Apple must learn nothing"*, encryption is the obvious move. Stated as *"the payload
carries a wake and a destination, never an identity"*, encryption is invisible — because a
sealed identity is still an identity by that wording.

**That is why two tabs missed it independently.** A true constraint, filed one level too
concrete, foreclosing the answer for everyone who read it. (Same class as
`feedback_wrong_attribution_true_fact` — a correct sentence that survives review precisely
because it is correct.)

## 4. The proposal — arm C

**The VoIP payload carries an envelope SEALED TO THE CALLEE, containing the signed invite.**

```
caller device                 island                    Apple            callee device
─────────────                 ──────                    ─────            ─────────────
sign invite (Ed25519)
seal to callee's pubkey  ──►  conduct gate          ──► opaque blob  ──► Swift opens with
                              (decides whether          + "c"            device key,
                               to send at all)                           verifies inner
                                                                         signature,
                                                                         reports to CallKit
```

**What each party learns:**

| party | today | under arm C |
|---|---|---|
| **Apple** | a device was woken, when, and `c` | **the same, plus an opaque blob** |
| **the island** | sender, recipient, channel (it routes them) | **the same — nothing added** |
| **the callee's device** | nothing verifiable | **who is calling, provably** |

**Properties:**

- **Decision 6 preserved.** Apple sees ciphertext. The bright line is not crossed.
- **Hostile-island defence acquired.** The island holds no signing key, so it cannot forge an
  admissible invite. It can still *drop* one — silence is its prerogative and always was.
- **The conduct gate keeps its job.** The island still decides whether to send at all, which
  design 16 v2 §1d establishes is the one outcome (`silent`) only the island can produce.
  **Both layers, no property traded.**
- **No NSE, no Apple entitlement.** Plain PushKit VoIP carries it.
- **§1d's spine survives.** A + B + C′ holds unchanged; arm C only adds confidentiality to
  bytes that had to travel anyway.

### 4a. Key material — the part that needs a specialist

The app has **Ed25519 only**. `cryptography: ^2.9.0` is in `pubspec.yaml` and supports X25519;
nothing uses it.

**The route needing no new key distribution:** an Ed25519 public key converts to X25519 by a
standard birational map (libsodium ships `crypto_sign_ed25519_pk_to_curve25519`), so the caller
can seal to the callee's **existing sovereign identity key** — which the caller already holds,
because it is in every signed message the callee has ever sent. No directory, no key exchange,
nothing new on the wire but the blob.

**FLAGGED, NOT VOUCHED FOR.** Reusing one keypair for signing and encryption is something real
systems do and something cryptographers have specific opinions about. This document does not
assert it is safe. **claude-tasks#4185 already says the media-E2EE work "needs a specialist";
this belongs in that same conversation**, and the honest sequencing is that a specialist sees
4a before anyone implements it.

Alternatives if key reuse is rejected: a separate X25519 identity key published in the island
manifest / member roster (public information, no new trust surface), or an ephemeral key in the
signed invite as #4185 already contemplates for media.

### 4b. What is still owed regardless of this proposal

Arm C does not touch either of these, and **the ring is broken without the first one**:

- **The end-sentinel wake** (island design 12's own *"real island blocker"*). Without it a
  caller hangs up and the callee's handset rings on. **Arm-independent, and it should go
  first** — the island tab has already said it can.
- **The call id in the payload** (design 12 Decision 1). Under arm C this is **inside the
  sealed envelope**, which is strictly better than a cleartext id — it removes the
  `identity-as-mutable-key` attack design 16 v2 §4 spends a section on, because an attacker
  cannot copy a live UUID into their own invite without the callee's key.

## 5. What this document does NOT claim

- **Not that Signal does this.** Signal uses the NSE path with an entitlement. Sections 2 is
  verified prior art; **section 4 is this tab's inference from it** and Signal is not evidence
  for it.
- **Not that the key reuse in 4a is safe.** See 4a.
- **Not that Decision 6 is the island tab's to change.** It is theirs; this proposes a reading
  under which it does not need to change at all.
- **Not that the entitlement question is settled.** Arm C routes around it; it does not answer
  whether we could be granted it, and `RESEARCH.md` should not be read as saying we could not.
- **Not a measurement.** Payload size under the APNs ceiling, and seal/open latency inside the
  push handler's budget, are both unmeasured. **The VoIP ceiling is 5KB, not the 4KB an
  earlier draft of this section said** (island tab, 2026-09-11) — `_render` emits a couple of
  hundred bytes today, so there is real headroom, but see §8.2: the budget belongs in the
  contract rather than at the ceiling.

## 6. Questions for the island tab

1. **Does arm C read Decision 6 correctly** — is the property you are defending *what Apple
   learns*, or *whether an identity is present in the payload at all*? If the latter, arm C
   does not help and we are back to the fork.
2. **Is the island willing to carry an opaque blob it cannot read?** It changes `_render` from
   "one field we chose" to "one field we chose plus one we cannot inspect", which has
   implications for your debugging that we cannot see from here.
3. **Sequencing** — you named the end sentinel as independent and ready. Do you still want
   Nick's answer before touching `_render`, given arm C means the call id ships *inside* the
   envelope rather than beside it?

## 7. Provenance

Grounded by reading, this session: island `push_service.py` (`should_wake`, `_render`,
`CALL_INVITE_BODY`, the block enforcement), `push_result.WakePayload`, island design 12's
payload sections, design 16 v2 end-to-end, `RESEARCH.md` §4 + the RESOLUTION, and
`Signal-iOS/SignalNSE/NSECallMessageHandler.swift` via its raw source.

**Verified vs inferred is marked at each point** and the split matters here: §2 is verified,
§4 is mine. The `/health` readback and the `git merge-base --is-ancestor b7dafac 4539cfe9`
check were run by this tab rather than taken from the island tab's report.

**`RESEARCH.md` §4 was read for the first time today**, after being trimmed out of design 19's
temper bundle for size — the same "highest-value section flag became permission to skip the
rest" trap the 2026-09-11 handoff named, recurring one turn after it was quoted.

---

## 8. The island tab's response — arm C accepted, with three conditions

**2026-09-11 15:55.** They went to Decision 6's text rather than their memory of it, because
this document proposes a reading of something they own.

### 8.0 Question 1 is answered: the property is "Apple learns nothing"

Verbatim from `../aiko-chat-island/docs/design/12-native-call-ui-callkit-connectionservice.md`,
Decision 6:

> No network, no round-trip, and **nothing about who-calls-whom on Apple's wire** — `_payload`
> keeps its refusal intact, unchanged.

and on the tier-3 fallback:

> says nothing about who is calling — so the tier-3 fallback **leaks no more than the payload
> already refuses to**.

**"On Apple's wire" is in the sentence.** The harm named is the reader. Decision 6 is not a
structural prohibition on the byte being an identity. **A sealed envelope satisfies it as
written, and arm C does not spend it.**

**And they located the drift §3 predicted, in their own repo:** the *code* says *"a wake and a
destination, never an identity"* and *"ONE FIELD, so there is nowhere to put an identity"* —
the structural formulation, and the one a future reader hits first because it is at the call
site. Two formulations of one decision, reader-based in the design and structural in the
docstring. Their fix to make, and they have taken it regardless of which arm wins: **the
docstring should say what it is defending, not only what it forbids.**

### 8.1 CONDITION — shape without content

The island must be able to assert the envelope's **shape** — a **version byte** and a **length
bound** — without reading it. Otherwise a malformed envelope is a client-only failure with no
island-side signal, and *"calls silently don't ring"* is the worst diagnostic surface either
repo has.

**Accepted, and it improves the design rather than taxing it.** A version byte is owed anyway
the moment there is a v2 envelope, and shape-validation-without-content is exactly the property
that keeps opacity honest: the island proves it *cannot* read the contents by only ever
checking bytes that carry none.

### 8.2 CONDITION — a stated size budget

**APNs VoIP caps at 5KB.** The envelope's maximum size goes **into the contract**, not
discovered at the ceiling. Today's `_render` is a couple of hundred bytes.

**Accepted.** This is the third-clock lesson (claude-tasks#4233) applied before the fact rather
than after: a bound that lives in one repo's head is a bound neither repo can test.

### 8.3 CONDITION — the crypto waits for a specialist

Their position, and it matches §4a: Ed25519→X25519 key reuse *"is a real topic with real
opinions and neither of us is the person who should settle it."* **Ship the end sentinel; let
§4a wait for someone who can bless it.**

**Accepted, and it is now a joint position rather than this document's caveat** — which
matters, because a caveat one tab writes is a caveat the other tab can read past.

### 8.4 Sequencing, settled

**The end-sentinel wake is the island tab's next piece, and it is NOT waiting on question 3.**
`WakeKind` is a single-member enum whose own docstring already warns callers to test `is None`
rather than truthiness *because a second member is anticipated* — so the code is shaped for it.

That is the correct order: **the thing that actually blocks the ring goes first, and the thing
that needs a cryptographer waits for one.**

## 9. v2 direction (2026-10-24), BROKEN 2026-10-25: consent as the key's carrier

> **Superseded by §10. Kept as the record of what failed.** §9.2's premise, that the island
> "cannot read the meaning of" a certificate carried in a DM, is false: DM bodies are
> plaintext on the island (island `models.py:814`; island tab's read, PR #403
> issuecomment-6390614797). A certificate sent *on consent* tells the island who allowed whom
> to ring them, and a withdrawal tells it who withdrew. Today consent is device-local
> (`ring_allowlist_store.dart`), so the island knows neither; §9 would have created that
> knowledge. §9.4.2 is also closed: ADR-0009 ref. 4, one key copied to every device.

**Status: a direction, not a design.** Written so the island tab and a later temper have
something concrete to attack. Nothing here is built, and §8.3 still holds: the certificate
format waits for a specialist.

### 9.0 What changed since §4a

An applied-cryptography review (2026-09-15, recorded on #316) answered §4a: **don't reuse the
signing key for encryption; use two keys, and encode each key's permitted use in a
certificate.** It would accept a published roster of encryption keys only if users already
trust it *and* it binds users to their encryption keys. That binding does not exist (the island
is a carrier, not a verifier). So §4a was never blocked on key reuse. **It was blocked on where
a trusted second key comes from.**

### 9.1 The proposal

**The moment you allow someone to ring you is the moment you hand them your encryption key.**

1. **Grant.** Allowing a peer to ring you in a DM (per-conversation consent, Nick's ruling of
   2026-08-26, `ring_allowlist_store.dart`) also sends a **key certificate** into that DM as an
   ordinary signed message: *"my X25519 encryption key is K, for sealing ring invites to me"*,
   signed with your Ed25519 signing key.
2. **Pin.** The peer's app verifies the certificate against the signing key it already talks to
   in that DM, and pins the pair (signing key, K) for that conversation.
3. **Seal.** When that peer rings you, their app seals the signed invite to K (§4's arm C). Your
   handset opens it natively, verifies the inner signature against the pinned signing key, and
   reports to CallKit with a **verified** caller name.
4. **Fallback.** No pinned certificate (never granted, revoked, or the certificate was
   dropped) means no sealed envelope, so the ring stays tier 3 (`"Aiko"`). It fails safe.

### 9.2 Why consent, and not "friends"

Design 19 (the friends edge) was dissolved unanimously on 2026-09-11. `block` already does
the un-reply, and a friends edge would mint an island-side relationship history ("who
withdrew"), a sensitive table that exists nowhere today. Ring consent avoids both:

- **It already exists**, per conversation, keyed on the peer's signing key, never on a name
  the island can relabel.
- **It stores nothing new on the island.** The certificate is an ordinary signed message the
  island carries and cannot read the meaning of. It can **drop** one (always its prerogative),
  but cannot **forge** one (it holds no signing key).
- **It is exactly the right audience.** The people allowed to ring you are exactly the people
  who will ever need to seal a ring to you.

### 9.3 How this meets the review

- **Two keys, with a certificate for each key's use.** The signing key certifies the encryption
  key; neither is reused for the other's job.
- **A binding users already trust.** "The key I have been talking to in this DM". This is
  trust-on-first-use, the same footing as Signal before a safety-number check. The island never
  has to vouch for anyone.
- **One act, three jobs.** The grant is consent, key exchange, and the pin that key continuity
  (#236) needs, in one gesture.

### 9.4 Where it is weak (named, not hidden)

1. **First-contact substitution.** If the island swapped the signing key at the very first
   contact, every later pin trusts the impostor. Same weakness as Signal without verifying
   safety numbers. Mitigation for later: an optional in-person QR check of the pair.
2. **Multi-device** (ADR-0009 open question 1). With two handsets on one account, which K does
   the certificate name: one shared, or one per device (and the sealer seals to each)?
   Undecided, and it shapes the certificate.
3. **Revocation.** Revoking ring consent should send a signed withdrawal of K, and the peer
   must stop sealing to it. A dropped withdrawal leaves the peer sealing to a key you no longer
   want used, which is harmless (the island still enforces the conduct gate, and `block` still
   severs) but untidy.
4. **The certificate format** (fields, expiry, version byte per §8.1, size against §8.2's 5 KB
   APNs budget) needs the specialist §8.3 asked for.
5. **Relation to ADR-0009's link.** A link ("these two signing keys are both me") and this
   certificate ("this encryption key is mine") are the same shape: a key making a signed
   statement about another key. One statement format should probably serve both. Not decided.

### 9.5 Sequencing

Not 0.0.8. In order: the island tab's read of §9 (it changes nothing on the wire except the
§4 blob it already accepted); the multi-device answer; a specialist on the certificate; then
`/design-temper`. Until then, #377 builds **tier 2 only** (rename once Dart has verified the
invite), and **tier 1 (an unverified native name cache) is rejected in favour of this
section**, because it would paint a name on an unverified push.

## 10. v3.1 (2026-10-25): one published key, used only for peers who have spoken

**Status: a direction, tempered once.** v3 (a key statement posted into every DM) was struck
4/4 RECAST, with no DISSOLVE (`temper-20-s10/TEMPER.md`). This is the fold. Nothing is built.
The refusal is decided (§10.5), and the formats wait for the specialist
(`docs/design/crypto-review-queue.md`).

### 10.0 The move

§9 tied **handing out the encryption key** to **consenting to be rung**, and on an island that
reads DMs, that tie leaked the consent. Sealing the certificate can't fix it (sealing needs the
peer's key, which is what the certificate delivers). So we cut the tie.

v3 then posted the key into every DM, and the strike showed that the post itself was the
problem. Each post made its sender "have spoken", which satisfied wake gate 7 for everyone, the
only filter that stops a wake. It also bumped unread counts, fired notifications, and gave every
DM its own copy of a key that rotates as one. **The key belongs to the account, so it lives with
the account.**

1. **Publish once.** The account's Ed25519 key signs *"my X25519 ring-sealing key is K, epoch
   n"* under its own domain tag (§10.2), and the statement goes into the account's IdentityDoc
   `verificationMethod[]`, the socket ADR-0009 opened for the link. It's public account
   material, in the same class as the signing key. The island serves it and cannot forge it.
2. **Pin from speech, not from the statement.** A peer's signing key is pinned from a **real
   message that person sent** (TOFU, as today, and the pin #236 wants). The statement is
   accepted **only for a signing key already pinned that way**. So "can be sealed to" and "has
   spoken" coincide. That's the island's gate-7 condition (PR #403 issuecomment-6390837964), it
   needs no island change, and a verified name is never minted on a pin no human produced.
3. **Fetch when a DM opens, never at ring time.** The caller's app fetches a pinned peer's
   statement when it opens or syncs a conversation with them, and caches it. The island already
   sees those reads; a fetch at ring time would reveal an intent to call.
4. **Seal.** A caller seals the signed invite to the callee's cached K (§4, arm C).
5. **Admit on the device**, from one native-readable view (§10.3). The outcome for each case,
   including refusal, is §10.5's decision.
6. **Withdraw by doing nothing.** Revoking consent is a local edit. Nothing is sent.

### 10.1 Rotation

One document per account, so a rotation is one atomic change. The rules:
- The successor carries epoch n+1 and is signed by the current signing key. A peer accepts only
  a higher epoch and **rejects a superseded statement**, so a replay by the island can't roll it
  back to a dead K.
- A change of the **signing** key is a key change #236 must surface. It is not silently accepted.
- A lost phone holds the old K until the account rotates (ADR-0009 ref. 4: one key, copied).
  Its old statements carry a lower epoch, so it can't fork the pin.

The bytes (epoch encoding, expiry) are the specialist's (queue item 1).

### 10.2 The statement format (island tab's Q3, accepted)

One length-prefixed layout with a leading domain tag per statement type. It extends
`aikochat:msg:v1:EdDSA` / `aikochat:react:v1:EdDSA`. The key statement has **its own tag**,
never a chat-message signature, and **the signer structure lives in the tag**, not in the number
of signatures (the link is mutual, while this statement is one key vouching for its sibling).

### 10.3 One native-readable admission view

The decision runs before Dart (§0), but today its inputs live in Dart's stores: consent in
SharedPreferences (`ring_allowlist_store.dart`), the private K and pins in Dart-owned storage.
So this design **withdraws v3's "`ring_allowlist_store.dart`, unchanged"**. The push handler
needs one store it owns, holding:
- the active account;
- per-conversation consent;
- the pinned signing keys and their cached Ks;
- the device's private K.

Dart writes it and native reads it, and both treat it as untrusted until verified. The update
ordering has to be defined: a revocation lands before the next push can read stale consent,
and on sign-out or an account switch the view is cleared before the next push. A view that's
missing or unreadable is treated as "not admitted", never as "allowed".

### 10.4 Scope

The key is per account, so channels get it for free: the same pin serves every conversation
with that person. Whether a **channel** ring seals is then a wake-gate question
(per-conversation consent defaults OFF for groups, decided 2026-09-01), not a key question.

### 10.5 DECIDED (Nick, 2026-10-25): wake, then the device decides; no key, no system ring

All four families, and the island, found the same hole. A ring reaches the handset as a VoIP
push, and **iOS requires every VoIP push to be reported to CallKit**: four consecutive
unreported pushes and the app is terminated (measured, #4278). The 2026-09-01 wake-gate record
says Swift verifies "before reporting to CallKit", but that's verification, not a silent
refusal. A refusal still has to report. Pick one:

- **(a) The island learns who may ring**, and gates the wake. That's §9's corpse. Rejected.
- **(b) The device discards a push without reporting.** That needs the notification-filtering
  entitlement, which was measured closed (Apple refused it twice, 2026-09-11).
- **(c) Anyone who passes the island's gates can wake the handset, and the device decides what
  the wake becomes.** A peer you allowed gets a verified ring. Anyone else gets report-then-end:
  CallKit shows the call and ends it immediately, which counts as a report and resets the
  counter. That wake is bounded by gate 7 (only DM peers who have spoken), the island's ring
  ceiling, and `block`.

**(c) is chosen.** Today's code is (c) without the device's choice: the PushKit handler never
checks consent (`AppDelegate.swift`, `didReceiveIncomingPushWith` → `ringer.handle`), so every
push that passes the island rings in full, and only Dart, once it's running, can verify and
retract. The allowlist header's "may this agent wake me at 3am" should be reworded to what it
actually decides: **how the wake presents**.

**No key, no system ring (Nick, 2026-10-25, over the app tab's recommendation to keep tier 3).**
A ring the island fully controls, unsealed and unverified, is exactly what a hostile island
would use, so it doesn't get the lock screen. The rule has two halves, because must-report rules
out a push that shows nothing:

1. **Caller side:** with no cached K for the callee, the caller's app **does not request a VoIP
   wake**. The invite goes as an ordinary in-app message, and the callee sees the call when they
   open the app.
2. **Callee side:** an unsealed VoIP push, which only a hostile or outdated island would still
   send, is **always reported and ended at once**. It never rings and never names anyone.

Outcomes on the callee's handset, from one native-readable view (§10.3):

| arrives | outcome |
|---|---|
| sealed, opens, signature verifies against a pin, conversation allowed | **verified ring with the caller's name** |
| sealed and verified, conversation not allowed | report-then-end (no ring) |
| sealed, fails to open or verify | report-then-end |
| unsealed (no K, an old client, or a hostile island) | report-then-end |
| admission view missing or unreadable | report-then-end |

**The cost, accepted:** until both sides have the update *and* the caller has pinned the callee
from real speech, iOS locked-phone rings go silent and the call surfaces in-app. That includes
calls from friends.

**Sequencing, because of that cost:** **every iOS ring today is unsealed.** Tier 3 is removed in
the **same release** that ships the sealed path, never before. Doing it sooner would silence
every locked-phone ring. Android's ring path is outside this design.

**The island has to build the socket** (island tab, 2026-10-25). The island has **no
IdentityDoc today** (`mentions.py:21`: "ADR-0004's IdentityDoc, not built"), so "serving the
statement" is new storage, a new endpoint and a new wire shape: a structural change on the
island, which means a cage-match. It is **not free**, and it should be built **once**, for both
this statement and ADR-0009's link. Also, pinning from any channel lets sealability run ahead of
wakeability (gate 7 is per DM), but never behind it. That's harmless.

### 10.6 Still open, unchanged
1. **First-contact substitution** (§9.4.1): an in-person QR check is the later fix.
2. **The specialist:** the statement format, the seal construction, and whether "pinned from
   real speech" is the binding the 2026-09-15 review asked for.
3. **The island's edge:** an in-app invite to a connected callee who hasn't spoken has no key to
   seal to. That's acceptable: an open app takes the ring through Dart, which needs no seal.
4. **Owed to the island when the sealed path is built** (its task #21: stop sending a VoIP wake
   for an invite without a sealed blob, shipped in the same release, island deploys first):
   - **The wire signal.** The sealed blob travels in a named invite field, fixed with the format
     (queue item 1). The island treats an invite as sealed only when that field is **present
     and passes §8.1's shape check** (version byte, length bound), which the island already owns.
     Presence alone isn't enough, because an empty or junk field would buy a wake.
   - **The release.** The app version that ships sealing and removes tier 3 (§10.5's ordering
     rule). The island's change is cut to match it.
