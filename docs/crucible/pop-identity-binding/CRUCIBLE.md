# 🜂 CRUCIBLE — Proof-of-Possession Identity Binding

> The keystone that makes **"the public key IS the user id"** true: the handshake
> by which a gateway (and, later, a dumb island) stops **assigning** identity and
> starts **accepting** the sovereign Ed25519 public key as the identity, verified
> by a signed challenge.
>
> Forged 2026-07-13 from a live design conversation (passkeys → pubkey-as-uid →
> islands → "can we eliminate the gateway" → E2EE). Explicit target, human at the
> wheel: consent gate crossed by direct greenlight.

## The ore (verified real, not invented)

The seam is a **documented deferral sitting in the code**, not a wish:

- `lib/features/chat/domain/origin_envelope.dart:23` — *"the pubkey→account binding
  is peer PR B; until it lands, no 'verified sender' UI."*
- `lib/features/chat/domain/origin_envelope.dart:236-241` — today's verdict
  (`originCryptoValid`) means **"a valid signature exists over these content
  fields," NEVER "this sender IS this account."** The named tradeoff: no
  verified-sender UI until "peer PR B binds key→account."

That binding has never been built. It is the exact brick that
[task #21 (pubkey-as-uid)] and [task #24 (islands / broker-as-only-infra)] both
rest on. `blockedBy`: #24 → #21 + #25.

## Why this ore — heat + impact (kept separate from the evidence)

**The heat:** this is the single handshake that flips the gateway from **namer**
to **attester** — the architectural inversion the entire federation north star
turns on. It is the load-bearing artifact the memory graph keeps insisting the
*identity-resolution seam* is, not the social buttons. Build it once and the
*same primitive* — sign a domain-separated challenge with the sovereign key —
authenticates you to a gateway **today** and to a dumb MQTT island **tomorrow**
(#24's `AUTH`-packet challenge is the same handshake at a different layer).

**What it changes (impact, not affect):** it removes a concrete thing — the
gateway's authority to *be* your identity. Identity moves from the server to the
pocket. Downstream it unblocks verified-sender UI (a shipped-but-dark capability),
pubkey-as-uid, and the islands topology. Aliveness 3 (Nick dropped everything to
chase it across four messages) × Impact 3 (transfers sovereignty; unblocks two
tracked epics).

## The claim to falsify (the one thing that would prove this is slag)

**If the binding is ~entirely gateway-side work** (peer repo `aiko-chat-island`,
Python) with only a thin app veneer, then this is **not an `aiko_chat_app`
crucible** — it is a peer-repo design that got mis-homed here, and the honest move
is to hand it across the repo boundary, not forge it in this tree. **Heat must
resolve the app/gateway split first.** If the split lands ~entirely gateway-side,
the candidate dissolves *as an app-repo forge* and Temper should say so.

Secondary falsifiers the temper should press:
- If replay/domain-separation can't be done without the gateway advertising a
  stable identity the app can pin, the "islands are interchangeable" premise cracks.
- If the E2EE-aware key-material decision (one Ed25519 vs Ed25519+X25519) can't be
  made without committing to a specific E2EE scheme (#25), the "decide it now"
  scope-widening was premature and should be pulled back.

## Scope (what this forge decides)

1. **The PoP handshake**: gateway/island issues a challenge; app signs it with the
   sovereign Ed25519 key; verifier records `pubkey ↔ session`. Domain-separated +
   replay-bound the SAME way message signing already is (verifier identity + fresh
   nonce + timestamp INSIDE the signed bytes — key-substitution discipline mirrored
   from `signingBytes`), so a login signature to gateway A cannot be replayed to
   gateway B.
2. **The app/gateway split**: what lands in `aiko_chat_app` (Dart) vs
   `aiko-chat-island` (Python). This is the primary falsifier — resolve it in Heat.
3. **Key material, E2EE-aware** (one notch wider, task #25): a single Ed25519
   signing key, or Ed25519 + a companion X25519 for future ECDH/E2EE. Best practice
   leans separate-key (avoid cross-protocol reuse) — temper this, don't assume it.

## Explicitly NOT in scope (guard against the forge sprawling)

- Full E2EE, esp. group/MLS (#25) — this forge only decides **key-material
  readiness**, not the encryption scheme.
- Multi-device seed portability (#21's A/B/C/D decision) — the binding must not
  *preclude* those, but doesn't choose among them.
- The islands transport itself (#24) — this forge produces the auth primitive
  islands will reuse, not the MQTT transport.
- A petname/human-naming layer (Zooko hazard) — named as a downstream dependency,
  not designed here.

## Hazards the temper must strike (carried from the conversation)

1. Multi-device = multi-identity (sovereign key is device-local, NOT synced,
   unlike passkeys).
2. Block-evasion == no-recovery (same coin: a fresh keypair sheds bad reputation
   for free — a moderation hole in a reputation-defense model).
3. The pubkey is a global, unrotatable correlation handle across gateways.
4. Human-naming floats free of identity (Zooko — needs a petname layer).
5. Android Keystore is wiped on uninstall (free identity rotation) vs iOS Keychain
   survives reinstall — an asymmetric evasion surface.

## Prior art to ground Heat against

- **Nostr** — pubkey identity + signed events + client-chosen dumb relays;
  **NIP-42** is literally a relay challenge-response auth. Closest match.
- **SSB** — Ed25519 identity + signed append-log + untrusted pub relays;
  Secret-Handshake (SHS) is its mutual-auth.
- **Matrix** — trusted homeserver replicas (the model we're moving *away* from).
- **MQTT 5.0 Enhanced Auth** — `AUTH` packet challenge-response / SCRAM (the #24
  reuse target).
- Nostr AND SSB both rejected DHT-for-storage in favor of relays — DHT's right
  layer is relay *discovery*, not message storage.

## Movements

- [x] **Ore** — target pre-selected (explicit), ore verified real, consent crossed.
- [ ] **Heat** — deep research → `RESEARCH.md` (app/gateway split FIRST; then the
      handshake designs, key material, replay defense).
- [ ] **Cast** — `DESIGN.md` (problem, shape, build order, blast-radius, claims to
      falsify, rejected alternatives).
- [ ] **Temper** — `/cage-match` (4-family) over CRUCIBLE + RESEARCH + DESIGN,
      hunting fatal design flaws. ≤3 re-cast rounds.
- [ ] **Blade** — plan mode: tempered design → ordered, approvable plan.
