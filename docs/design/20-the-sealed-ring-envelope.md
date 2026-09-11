# Design 20 — the sealed ring envelope

| | |
|---|---|
| **Status** | **PROPOSAL, un-tempered.** Nothing here has survived a cross-family adversary or a cryptographer. |
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
- **Not a measurement.** Payload size under APNs' 4KB ceiling, and seal/open latency inside the
  push handler's budget, are both unmeasured. Both are cheap to measure and neither is
  obviously a problem — 4KB is roomy for one signature plus a small envelope.

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
