# RESEARCH — group-E2EE key management for aiko-chat

> Movement 2 (Heat) artifact. Synthesis of three parallel bounded-research tracks (MLS / sender-keys / aiko-constraints), run 2026-07-14. Each track answered pre-baked questions with citations; this doc separates the metal from the slag and states the verdict the Cast is built on.

## TL;DR — the melt separated cleanly

**Cast sender-keys first; keep MLS as a documented endgame migration.** Both scheme-tracks and the constraints-track converged on this from opposite worldviews. The two constraints that dominate aiko's substrate — **frequently-offline phones (store-and-wake, no reliable iOS background delivery)** and **an undecided multi-device identity model (#27)** — both point away from MLS and toward sender-keys, *against* MLS's theoretically stronger security. The AI-member reality is a third thumb on the same scale. The one real cost of choosing sender-keys — you must build your own fork-detection/consistency layer that MLS would give for free — is real and folded into the design.

---

## Track A — MLS (RFC 9420)

- **No trustworthy Dart MLS.** The only Dart package (`openmls` v1.4.0 on pub.dev) is a 5-week-old, single-author, *unverified-publisher* FFI wrapper over Rust OpenMLS that auto-downloads prebuilt binaries — an unacceptable supply-chain posture to ship on. The Rust OpenMLS core IS credibly audited (SRLabs, 12 weeks, ending Oct 2025, fixes in v8.1/v7.3), but using it means committing to `flutter_rust_bridge` cross-compilation machinery per-arch — the same Rust-FFI weight the Veilid eval flagged, and a direct hit to the one-script-island goal.
- **Untrusted island fits the MLS Delivery-Service role** (RFC 9420 §16: "trusted AS, largely untrusted DS"). A malicious DS cannot decrypt or forge, and forks are *detectable* via per-epoch confirmation tags — but forks are **detected, not prevented**, and the DS sees all metadata.
- **The sharp edge: strict linear Commit-chain is hostile to sleeping phones.** Every member must process every Commit *in order* to advance epochs. A phone offline across N epochs must replay all N Commits or leave-and-rejoin **with loss of the messages in the missed epochs**. This forces the island to durably retain full Commit history per member (re-trusting the relay for availability). Direct collision with store-and-wake.
- **FS/PCS are cheap at 2-50 members** (TreeKEM is O(log N), 1-6 node ops) — but strong FS wants frequent Commits, and every Commit is another message a sleeping phone must replay. FS cadence and phone-offline-tolerance are in direct tension.
- **Falsifier CONFIRMED for MLS:** shipped MLS is per-device-leaf; the one-key-per-person alternative was proposed and *lost* in the IETF WG. Group-MLS is genuinely gated on the #27 multi-device decision.
- **AI member is the *ideal* MLS participant** (always-on, never triggers replay, can drive Commit cadence for sleepy phones).

**Track A bottom line:** MLS is the right *endgame* once (a) #27 is settled and (b) trusted Rust-FFI machinery exists — not a viable *first* cast.

## Track B — Sender-keys (Signal/WhatsApp group model)

- **Model:** pairwise X3DH + Double Ratchet sessions (the hard part), plus a symmetric **sender-key** broadcast layer — each sender distributes a chain key + Ed25519 signing pubkey once per member over pairwise channels, then encrypts each message once and the relay fans it out (O(1) per message).
- **Membership: add is cheap** (one pairwise distribution to the newcomer per sender); **remove is O(N²)** (every remaining member rotates + re-distributes a fresh sender key, since the removed member holds everyone's current chain key). Amortized "rotate on first send after change."
- **FS is coarse, automatic PCS is ABSENT.** The broadcast chain key ratchets by hashing only — no DH re-injection — so a compromised chain key exposes all that sender's future messages until an explicit refresh. Group heals only as a *side effect* of membership change. The first formal analysis (eprint 2023/1385) proves only a "weak" security notion and proposes "Sender Keys+". **Named tradeoff, not silent.**
- **Async: sender-keys STRUCTURALLY beats MLS** — no lockstep epochs. A message decrypts iff you hold that sender's chain key and can ratchet to its iteration, *independent of intervening group-state changes*. Offline-for-a-week is a non-event: catch up per-sender-chain, standard bounded skipped-key caching. **This is the single most decision-relevant fact for our topology.**
- **Multi-device: DEFERS #27.** Fanout is already per-device at the pairwise layer; the broadcast layer never needs a "person" notion. Ship "one device = one participant" now, add "person = device set" as a pure roster concern **without touching the wire protocol**. Falsifier resolved *for this scheme*.
- **`libsignal_protocol_dart` exists (MixinNetwork, full sender-key layer) but is GPL-3.0** — a copyleft landmine for a proprietary app. Use as a *correctness oracle to read*, clean-room reimplement.
- **AI member fits cleanly** (always-on = easiest node) but is the **fattest compromise target** given weak PCS → mandate periodic AI sender-key rotation.

**Track B bottom line:** the right first cast — simpler, async-native, multi-device-deferring, buildable on primitives we already hold — at a named FS/PCS cost tolerable at human-scale groups with periodic rotation.

## Track C — aiko constraints (adjudicating between the schemes)

- **Q1 — primitives.** `cryptography: ^2.9.0` (in-tree, prod-proven for Ed25519) has **every primitive we need**: X25519, Ed25519, HKDF, ChaCha20/**XChaCha20**-Poly1305, AES-GCM, HMAC, SHA-2, BLAKE2, Argon2id — uniform across iOS/Android/web. **Missing: all protocol layers** (HPKE, Double Ratchet, TreeKEM, sender-keys, MLS). **Decisive asymmetry:** sender-keys is buildable directly from these primitives (**no HPKE needed**); MLS-from-scratch *additionally* requires implementing HPKE (RFC 9180) + TreeKEM against external vectors — materially larger and higher-risk.
- **Q2 — AI-member threat wrinkle (argued both ways, committed).** A cloud AI member sees 100% of its group's plaintext in real time *by design* — a plaintext-exposure floor no protocol property can lower. This makes MLS's *premium* PCS **over-provisioned** for AI-containing groups. **But FS/PCS are NOT moot:** they still defend against every party except the AI's own provider (relay, device thieves, other members), and — the strongest point — **PCS is what makes AI *removal* enforceable**, and the AI is the member most likely added-then-removed. Verdict: thumb toward the *simpler tier*, keep FS/PCS at sender-key level, **preserve efficient membership change above all**. (If inference ever moves on-device/confidential-compute the floor vanishes and the calculus flips — treat "AI member" as an interface, don't foreclose it.)
- **Q3 — how untrusted is "untrusted".** Even a content-blind island is **trusted for ordering, delivery/liveness, and non-equivocation** — it can't read or forge membership (given an honest identity layer) but it **can fork the group** by reordering/dropping/showing divergent views, and sees all metadata. **MLS gives a transcript hash for free to detect forks; sender-keys gives nothing comparable → we must build our own roster/transcript-consistency check.** This is the one clean point *for* MLS, and the sharpest tension in the decision. Ghost-member defense is an **Authentication-Service / federation (#1760) problem, not the relay's** — a dumb island buys nothing there.
- **Q4 — #27 coupling. Group-E2EE is NOT blocked on #27.** Every deployed system (Signal/WhatsApp/iMessage) puts **devices** at the crypto layer and **person** as a mapping on top. aiko already has a per-device key (`SovereignKey`). Design against a device-granular interface `GroupMember = { memberId, devices: Set<DeviceKey> }`; #27 decides only the *policy* populating `memberId→devices` and the membership-churn cost profile — **not the crypto, not the scheme choice.** Sharp verdict: **design now, don't wait on #27.**
- **Q5 — media E2EE (solved, scheme-independent).** Random per-blob **XChaCha20-Poly1305** key + SHA-256 ciphertext hash + pointer, all carried inside the E2EE message; blob stored once for the whole group; **never derive the blob key from the group key** (would break FS re-fetch of old media + new-member history access). Distinct sealing domain tags (`aikochat:seal:v1:...`, `aikochat:blob:v1:...`) extending the existing length-prefixed domain-separation discipline in `signingBytes()`.

**Track C bottom line:** #27 doesn't gate the design; the AI-member reality nudges toward the simpler tier; we have primitives for sender-keys-from-scratch but not MLS-from-scratch; and whichever we pick we owe a fork-detection layer MLS would give free.

---

## The synthesized verdict (what the Cast is built on)

1. **Scheme: sender-keys first.** Pairwise X25519 Double Ratchet + symmetric sender-key broadcast, clean-room built from `cryptography 2.9.0` primitives. `libsignal_protocol_dart` (GPL-3.0) is a read-only oracle; every codec/ratchet step pinned to **external known-answer vectors**, never self-roundtrips ([[c0de]] self-referential-test blindness).
2. **Membership interface is device-granular** (`GroupMember = {memberId, devices}`) so #27 is a policy decision *above* the crypto, deferred cleanly.
3. **Sealing is signing's mirror** — a new domain-tagged, length-prefixed canonical structure (`aikochat:seal:v1:XChaCha20Poly1305`), distinct from `aikochat:msg:v1:EdDSA` (reusing the signing tag was flagged a bug in the PoP crucible). Extend the `signingBytes()` discipline.
4. **Media E2EE:** per-blob random XChaCha20-Poly1305 key + SHA-256 hash + pointer in the message; never from the group key.
5. **Build the fork-detection layer sender-keys doesn't give free** — a roster/transcript-consistency check (members compare a roster hash out-of-band or via a periodic shared beacon) so a partitioning island is *detectable*.
6. **Named tradeoffs** (owner + mitigation, carried to Cast/Temper): coarse FS + no automatic PCS → **periodic mandatory sender-key rotation** (especially the always-on AI member, the fattest target); O(N²) removal cost accepted at human-scale groups; the relay retains ordering/liveness/metadata trust.
7. **MLS is the documented endgame migration**, triggered by a *real* (not speculative) need: large/high-churn groups, a strong-automatic-PCS requirement, #27 settled to per-device, and trusted Rust-FFI machinery in place.

### Open variables the Cast must enumerate (no silent TODOs)
- Exact wire encoding of the sealed envelope + sender-key distribution message (Multikey vs base64url — the same still-open decision `sovereign_key_store.dart` flags for the pubkey).
- The fork-detection mechanism's concrete shape (out-of-band roster-hash compare vs an island-published signed roster beacon) — a design fork to resolve in Cast.
- Skipped-key cache bound (`MAX_SKIP`) and eviction policy.
- Where sender-key state persists (extend `flutter_secure_storage` / Drift cache?).
- Whether the pairwise Double Ratchet is full-fat or a reduced variant for the first cast (the multi-week footgun-dense core — scope carefully).

### Sources
RFC 9420 (MLS) · OpenMLS audit (blog.phnx.im) · pub.dev/packages/openmls · "WhatsUpp with Sender Keys" eprint 2023/1385 · arxiv 2301.07045 · Signal Double Ratchet spec · en.wikipedia.org/wiki/Sender_Keys · libsignal_protocol_dart (GPL-3.0) · WhatsApp multi-device (engineering.fb.com 2021) · WhatsApp Security Whitepaper · pub.dev/packages/cryptography.
