# App-side key continuity — design scope (#2299)

> **Status: DESIGN ONLY. Nothing here ships.** This document exists to make the
> affirmative "✓ verified sender" badge honest — and to establish that *the naive
> version is unshippable*. It produces a recommendation and a priced fork, not
> code. The posture call (interim now vs wait) is Nick's — it is a security-posture
> judgment, not a technical one.
>
> Parent: `../sovereign-message-signing/wire-half/DESIGN.md` §"Verified-sender
> update — 2026-07-27". Read that first: it is where Nick *deliberately held* the
> ✓, and this doc is the design of what would eventually release it.

---

## TL;DR

- The ✓ is held not because the app can't verify a signature (it can —
  `verifyOrigin`), but because it takes the **key → account binding on the
  island's word**. A malicious/compromised island can mint a key, TOFU-register it
  as any user, sign, and the app would render ✓.
- **Key continuity** — pin the pubkey the app first sees for a sender, locally,
  independent of the island; warn on change — is the *only* thing that turns ✓
  into a check on the operator. It is the SSH-host-key / Signal-safety-number move.
- **A naive pin-and-warn is unshippable**: it false-positives on every legit key
  change (second device, recovery re-key, rotation). Distinguishing legit rotation
  from attack is **genuinely gated** on the multi-device identity model (#17) and
  rotation semantics (#21 / island #1865). Continuity cannot ship before them.
- The **interim `/v1/keys` cross-check** is cheaper but buys **almost nothing
  against the stated threat**: the island answers `/v1/keys` too, so a malicious
  operator forges the roster consistently. It is a data-consistency probe against
  an *honest-but-buggy* island, not a defense against a dishonest one — and it
  **does not justify the affirmative ✓**.
- **Recommendation: WAIT for real continuity (gated on #17/#21). Do not ship the
  interim as a security feature or a badge.** Rationale and the priced fork below.

---

## 1. Threat model — what each mechanism actually defends

Three distinct guarantees are in play. They are routinely conflated; the whole
point of holding the ✓ is that only the third one earns it.

| Mechanism | Defends against | Residual gap |
|---|---|---|
| **Signature verify** (`verifyOrigin`, shipped) | Transit tampering, corruption, our own signing/verify drift. Proves *"the holder of some key signed these content bytes"*. | Says nothing about *whose* key. A malicious island forges a valid signature under a key it minted. Also position-unbinding (below). |
| **Interim `/v1/keys` cross-check** (proposed, unbuilt) | An **honest-but-buggy** island that registers `sender_pubkey` under the wrong `user_id`, or a display/roster mismatch. Proves *"this pubkey is, per the island, a registered key of the displayed user"*. | **The island is authoritative for both the message AND the roster.** A dishonest operator serves a self-consistent forgery. Zero operator defense. |
| **Key continuity** (this design, gated) | A **malicious/compromised operator**. The pin is captured locally on first sight and is island-independent; a later island-sourced key substitution is *visible* as a change. Proves *"this is the same key this device has always seen for this sender"*. | TOFU window (the very first sight is still island-sourced — same as SSH). Legit-change ambiguity (§2). Does not by itself bind key→human across devices (that is #17). |

### Two independent reasons the ✓ overclaims today

Both are named in the parent DESIGN §"Verified-sender update"; restated so this
doc is self-contained:

1. **Island-sourced binding.** The app verifies the *signature* but takes
   `sender_pubkey → user_id` on the island's word — it never queries `/v1/keys`
   or cross-references against a local record. Malicious island ⇒ mint key ⇒
   TOFU-register as victim ⇒ sign ⇒ app renders ✓.

2. **Content-integrity, not position-binding** (the "named limitation" in the
   parent DESIGN). `message_view` carries no frame-level `client_msg_id`; the
   signed id lives only inside `origin`, so the check is self-referential.
   `originCryptoValid` proves *"a valid signature exists over these content
   fields,"* NEVER *"this sender signed THIS message position."* A dishonest
   gateway could relocate a validly-signed origin onto a different row with
   identical channel/body/reply and it verifies.

**Continuity addresses reason 1. It does NOT address reason 2** — position-binding
needs the gateway to carry and echo the frame `client_msg_id` (an island change,
out of scope here). A truthful ✓ needs *both* fixed. This is load-bearing for the
recommendation: even fully-shipped continuity is **necessary but not sufficient**
for the affirmative ✓ on its own.

### The residual gap in each, stated precisely

- **Signature verify alone:** any-key-signed. Gap = whose key. (100% of the
  operator threat open.)
- **+ interim `/v1/keys`:** island-asserted-key-of-user. Gap = the island is the
  liar *and* the notary. (100% of the *operator* threat still open; closes only
  the honest-island roster-bug subset.)
- **+ continuity:** same-key-as-first-seen, island-independent. Gap = the TOFU
  first-sight window, legit-change ambiguity (§2), and position-binding (reason 2,
  separate island work).

---

## 2. The false-positive problem — why naive pin-and-warn is unshippable

Naive pin-and-warn: *store the first `sender_pubkey` seen for a `user_id`; if a
later message from that `user_id` carries a different pubkey, warn.* The warning
is a scary, trust-eroding, security-grade signal ("this person's key changed —
possible impersonation"). It **must not cry wolf**, or users learn to dismiss it
and it protects nothing — worse than absent.

Every one of these is a **legit** key change that a naive pin flags as attack:

| Legit cause | Task | Why it changes the pubkey | What continuity must know to NOT warn |
|---|---|---|---|
| **Second device** | **#17** (multi-device identity) | Each device mints its own sovereign key (`SovereignKeyStore.loadOrCreate`, per-device seed). A user on phone + tablet has **two simultaneously-valid** keys. | That `user_id` legitimately maps to a **set** of current keys, and which keys are co-valid *now*. Requires the multi-device identity model to define device enrolment + the authoritative co-valid set. |
| **Recovery re-key** | **#21** | User lost the device/seed (`clear()` mints a fresh identity — "reads as a NEW author, no recovery" today). The new key is legitimately theirs. | A recovery ceremony that **attests** the new key to the old identity (continuity of *person* across a *key* discontinuity) — the exact thing #21 must define. Without it, recovery is indistinguishable from takeover. |
| **Rotation / soft-revoke** | **#21 / island #1865** | `key_version` bump: a user rotates a possibly-compromised key; old key retired, new key active. | The rotation semantics: `key_version` ordering, soft-revoke state (active/retired/compromised), and whether a signed **rotation link** chains new-key to old-key so the app can accept the change *because it is cryptographically endorsed by the prior key* rather than merely asserted by the island. |

**The common shape:** a pin store keyed by `user_id → single pubkey` is the wrong
data model. The real world is `user_id → a rotating, multi-holder SET of keys with
lifecycle state`, and the transitions between set-states are either
**self-authenticating** (a rotation signed by the outgoing key — safe to accept
silently) or **externally-attested** (a recovery ceremony — safe to accept) or
**neither** (unexplained substitution — *this* is what warrants the warning).

Continuity is only safe once #17 and #21 answer:

- **#17 must resolve:** the authoritative *current co-valid key set* for an
  identity, and how a new device is enrolled into it (so a second device is an
  additive, non-warning event, not a substitution).
- **#21 / island #1865 must resolve:** the rotation state machine (`key_version`
  ordering + soft-revoke states) **and** whether rotations/recoveries carry a
  cryptographic link the app can verify **without the island's word** — because a
  link the *island* vouches for re-introduces exactly the operator trust the pin
  exists to remove. A rotation endorsed by the *outgoing key* is island-independent
  and safe; a rotation endorsed only by the island is not continuity at all.

Until these exist, the warning cannot distinguish attack from Tuesday. **Do not
ship a pin-and-warn — and do not ship a ✓ built on one.**

---

## 3. The interim `/v1/keys` cross-check — exact shape, cost, and honest semantics

### What exists today

- The island shipped the binding: `signing_keys` table + `POST/GET/DELETE
  /v1/keys` (TOFU on every signed send), live on both prod islands.
- The app does **not** call it. `ChatRestApi` (`lib/features/chat/data/chat_rest_api.dart`)
  has no keys method. The app has **no sender→key store** independent of the island
  beyond the per-row `sender_pubkey` column on the drift-cache message row
  (`drift_cache.g.dart`) — which arrives *in the same island message* as the
  `user_id` it would be checked against, so it is not an independent source.

### The interim, precisely

- **When:** on ingest of a signed inbound message whose `(sender.user_id,
  origin.sender_pubkey)` pair has not yet been confirmed this session — call
  `GET /v1/keys?user_id=<id>` (batched/cached per user to avoid per-message cost).
- **What it asserts:** `origin.sender_pubkey ∈ island's registered key set for
  sender.user_id`. I.e. *"the island agrees this pubkey belongs to this user."*
- **What UI it justifies:** at most a **weak, non-security** indicator —
  *"sender matches island record."* It **does NOT justify the affirmative
  operator-proof ✓**, and it should not render as one. Honestly it is closer to
  the existing `originCryptoValid` telemetry than to a badge: a
  data-**consistency** signal, not a trust signal.
- **Cost:** ~an afternoon. One `ChatRestApi` method, a per-user roster cache, a
  call site in `_persistInbound`. No new durable local store, no migration.

### Why it buys almost nothing against the stated threat

The stated threat (parent DESIGN, Nick's hold) is a **malicious/compromised
operator**. That same operator serves `/v1/keys`. So it returns a roster
*consistent with its own forgery* — pubkey P it minted, registered under victim V,
and `GET /v1/keys?user_id=V` cheerfully includes P. The cross-check passes. **The
notary is the forger.** Against the actual threat, the interim closes 0%.

What it *does* catch: an **honest** island with a **bug** — a pubkey registered
under the wrong user, a display/roster desync, our own mis-stitching of
`sender.user_id` to `origin.sender_pubkey`. Real but narrow, and a *correctness*
concern, not the *security* concern that holds the ✓.

### The honest badge semantics it would support

| Signal | Honest claim | Earns the ✓? |
|---|---|---|
| `originCryptoValid == true` (today) | "a valid signature exists over this content" | No |
| + interim `/v1/keys` match | "…and the island agrees this key is this user's" | **No** — island-trusting |
| + continuity (pinned, island-independent, legit-change-aware) | "…and this is provably the same sender even if the island lies" | **Yes** (with position-binding, reason 2, also fixed) |

The interim moves the app one rung up a ladder whose top rung is the *only* one
that earns the badge. Shipping a badge at the middle rung is precisely the
overclaim Nick held the ✓ to avoid.

---

## 4. Storage / design sketch — the eventual pin store (DESIGN ONLY)

> No implementation. This is the shape continuity *would* take once #17/#21
> unblock it, recorded so the interim's honest scope and the eventual target are
> legible together.

**Local, island-independent, durable.** Sits beside `SovereignKeyStore` (which
holds *our* key); this holds *others'* observed keys. Not the drift cache — that is
island-sourced message data; the pin store's whole value is that it is a
*separate* record the island cannot rewrite.

**Keyed by identity, holding a set — never a single "current" key** (that is the
[identity-as-mutable-key](../../../CLAUDE.md) collision: a lone "current" slot
silently clobbers a co-valid second-device key). Sketch:

```
PinnedSender
  identityId        // the STABLE identity anchor from #17 — NOT necessarily
                    // user_id (user_id may be island-reassignable; #17 defines
                    // the durable anchor). This choice is gated on #17.
  keys: Set<PinnedKey>

PinnedKey
  rawPublicKey      // 32-byte Ed25519, the pinned material
  keyVersion        // from the envelope (§message_signing MessageSignature.keyVersion)
  state             // active | retired | compromised   (rotation, #21/#1865)
  firstSeenMs       // local clock at first sight (the TOFU anchor)
  lastSeenMs
  provenance        // how it entered the set: first-sight | rotation-linked |
                    // recovery-attested | (never: island-asserted-only)
```

**Rotation-awareness.** `keyVersion` + `state` mirror the envelope's reserved
`key_version` slot (already carried, constant `1` today). A rotation is accepted
into the set **silently** only when it arrives with a link the app can verify
*without the island* — a new-key record signed by an in-set outgoing key (the
"rotation link" #21 must define). A key change with **no** such link and **no**
#17-defined device-enrolment is the *only* case that surfaces the warning.

**Migration path (additive, non-breaking):**

1. Store starts **empty**; first sight of each sender pins silently (pure TOFU, no
   warning — there is nothing to contradict yet).
2. When #17 lands: backfill `identityId` anchor; second-device keys enter as
   additive set members, not substitutions.
3. When #21/#1865 lands: `state` + rotation-link verification gate the
   silent-accept vs warn decision.
4. Only after 1–3 does any **warning UI** or affirmative **✓** turn on — and the
   ✓ additionally requires reason-2 position-binding (separate island work).

Each stage is safe on its own (a pin store that only ever silently pins and never
warns is inert — it cannot false-positive), so the store can be *built* early and
*activated* incrementally. That is a genuine option (§5) but distinct from shipping
a warning.

---

## 5. Recommendation + priced fork

### The fork

**Arm A — ship the interim `/v1/keys` cross-check now.**

- **Buys:** catches honest-island roster bugs / our own stitching bugs; lays the
  `GET /v1/keys` REST plumbing the eventual pin store reuses.
- **Costs:** ~an afternoon. **Does NOT** defend against the operator (the stated
  threat), **does NOT** justify the ✓. Risk: a "sender matches record" indicator is
  one product decision away from being read as the very badge Nick held —
  overclaim creep. Adds an island round-trip on the ingest path.
- **Honest ceiling:** a data-consistency probe. Should stay instrumentation-grade
  (telemetry / a muted indicator), never a trust badge.

**Arm B — wait for real continuity (gated on #17/#21), build nothing user-facing now.**

- **Buys:** the next thing shipped is the *actual* operator defense, on the correct
  `user_id → key SET + lifecycle` data model, with no false-positive foot-gun and
  no intermediate overclaiming badge.
- **Costs:** the ✓ stays held until #17 **and** #21/#1865 land (and reason-2
  position-binding). Genuinely blocked on cross-repo identity work — this is not
  idleness, it is correct sequencing. The honest-island roster-bug subset stays
  uncaught in the interim (low severity — our signing path is self-verifying and
  the base-rate probe already watches for invalid origins).

### What I'd recommend

**Arm B — wait.** Reasoning:

1. The interim's security value against the *named* threat is **zero**; its only
   real value is honest-island bug-catching, which is a correctness nicety, not the
   thing holding the ✓.
2. Its main hazard is exactly the failure Nick already chose to avoid: a
   near-badge that reads as trust it hasn't earned. Building it invites a later "why
   not just show the ✓ when it matches?" — re-litigating a settled call.
3. Continuity's data model (`identity → key set + lifecycle`) is **defined by**
   #17/#21. Building interim plumbing keyed on the wrong model (`user_id → single
   key`) is machinery ahead of the design that shapes it — and risks being thrown
   away.

**One qualified exception, if Nick wants motion now:** build the pin store's
*silent-TOFU-only* first stage (§4 migration step 1) — it pins, it never warns, it
is inert and cannot false-positive — **without** the interim `/v1/keys` call and
**without** any UI. That starts accumulating island-independent observations today
(so continuity has history to reason over when #17/#21 land) at near-zero risk. It
is *not* the interim cross-check and does *not* touch the island. I'd take this over
Arm A if the goal is "make forward progress without overclaiming."

**The posture call is Nick's** — whether the honest-island bug-catching of Arm A is
worth an island round-trip and the overclaim-creep risk is a security-posture
judgment, not a technical one.

### The single most important open decision for Nick

**Does #17 make the durable identity anchor `user_id`, or a separate
key-independent identity id?** Everything downstream keys off this: the pin store's
primary key, whether a recovery re-key preserves identity, and whether the ✓ can
ever mean "same *person*" vs merely "same *key*." Continuity cannot be safely
designed past the sketch until #17 answers it. It is the gate on the gate.

---

## Appendix — grounding (as-read, this branch)

- **App verifies signature, not binding:** `chat_repository.dart` `_persistInbound`
  → `verifyOrigin` (`origin_envelope.dart:320`); verdict stored as
  `originCryptoValid`, probed (never alarmed) via
  `ChatTelemetry.originVerificationFailed`.
- **No `/v1/keys` client:** `ChatRestApi` (`chat_rest_api.dart`) exposes no keys
  method. Confirmed by grep — the app never calls it.
- **No independent sender→key store:** only the per-row `sender_pubkey` column
  (`drift_cache.g.dart`), which arrives inside the island message — not independent.
- **Per-device key minting:** `SovereignKeyStore.loadOrCreate` (`sovereign_key_store.dart`)
  — per-device seed ⇒ multi-device = multiple valid keys; `clear()` re-mints as a
  "new author" ⇒ recovery = legit key change.
- **`key_version` slot reserved, constant `1`:** `MessageSignature.keyVersion`
  (`message_signing.dart`), `SovereignKey.keyVersion` — carried on the wire, ready
  for rotation to be a value change.
- **Position-binding limitation (reason 2):** parent DESIGN §"Named limitation".
- **`/v1/keys` shape:** `../pop-identity-binding/DESIGN.md` (`signing_keys` table,
  `POST/GET/DELETE /v1/keys`, `GET` returns island-asserted/TOFU keys — the pop
  crucible itself notes a client can't build a trusted badge from `GET /v1/keys`).
