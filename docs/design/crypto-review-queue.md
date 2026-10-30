# Cryptographer review queue

What we want a specialist to look at, in the order we need it. Started 2026-10-25.

**How this list was made:** from every place the code or the design record uses cryptography
(a grep of `lib/` and the native targets for primitives, plus every doc that names a
cryptographer), not from memory. Add an entry when a design starts depending on a cryptographic
property. Strike one through once a specialist has signed it off, and link the review.

**Who:** the external applied cryptographer whose 2026-09-15 review answered design 20 §4a
(recorded on #316, "a fuller read is still pending"). Our stack is Dart `cryptography: ^2.9.0`
in the app and CryptoKit natively. We do **not** use libsodium, so advice that assumes it needs
translating.

**What reviews so far were not:** every TEMPER in `docs/crucible/` and every `/cage-match` is
a cross-family *model* review. They find logic and consistency defects. None of them counts as
a cryptographer's sign-off, and nothing below is marked done because a model panel approved it.

## Blocking: design 20 §10 (the sealed ring), PR #403

§10 has been through two design-temper rounds (4/4 RECAST each, folded). In its current shape,
an account publishes **one** signed X25519 statement in its IdentityDoc. A caller uses it only
for a signing key it pinned from a signed message, and freshness rides on speech: each message
carries the sender's current key epoch. Consent stays device-local.

0. **Gate for the next design pass: may the X25519 sealing key be DERIVED from the Ed25519
   signing seed** (a domain-separated KDF such as HKDF with a fixed `aikochat:ring-seal` label),
   rather than minted on its own? It dissolves round 3's largest cluster: every device computes
   the same K, so there's no fork, no private-key distribution and no epoch. The 2026-09-15
   review said "two keys, not one" against the *birational* reuse of one keypair. Is a separate
   key derived from the same seed acceptable, given that compromising the seed already
   compromises both under ADR-0009's copied keys? `design 20 temper-20-s10/TEMPER-r3.md`
1. **The key statement format.** Fields, epoch, expiry, version byte (§8.1), size, and its own
   domain tag, so it can never verify as a chat message. Also: how a message carries the current
   K epoch inside its signature. `design 20 §10.0, §10.1, §10.2`
2. **One layout, one tag per statement type,** with the signer structure in the tag, shared with
   ADR-0009's link. Is that enough domain separation? `design 20 §10.2`
3. **The seal itself (arm C).** HPKE base mode versus a hand-rolled construction, and binding the
   envelope to its recipient. The signed invite inside must carry the conversation id, intended
   recipient, freshness and the caller's name (round-2 requirements), so the island can't pick
   the consent bucket, relabel, replay or move the call. `design 20 §4, §10.3`
4. **TOFU on a signing key pinned from a signed message as the binding,** plus the rule that a
   key is accepted only if its epoch matches the latest seen on a message. Is that enough
   against an island that can omit statements? First-contact substitution is the named residual
   risk. `design 20 §10.0, §9.4.1`
5. **One copied key per account (ADR-0009 ref. 4).** Every device holds the same Ed25519 and
   X25519 keys. Round 2 showed the trap: a stolen device holds the signing key, so it can sign
   any rotation the owner could, and **recovery needs out-of-band re-verification by every
   peer**. **Decided, then DEFERRED, 2026-10-25 (ADR-0009 ref. 5):** a stolen locked phone can't sign; only a passcode-known thief can. Deferred design: an offline recovery key, kept only in the
   passphrase-encrypted backup, certifies the signing key and signs its successor after a loss
   (Matrix's master-key pattern). For review: the certification statement, how peers learn and
   pin the recovery key, and whether a backup restore can be used to impersonate the owner.
   `ADR-0009 ref. 5, design 20 §10.1`

## Shipped, never specialist-reviewed

6. **The message signing byte contract.** Messages and reactions are signed at birth:
   the canonical bytes, field order, and domain separation between messages and reactions.
   `lib/features/chat/domain/message_signing.dart`, `docs/crucible/sovereign-message-signing/`
7. **did:key encoding of the identity.** Multicodec `0xed01` plus the raw pubkey.
   `lib/features/chat/domain/origin_envelope.dart`
8. **The Carried Record's trust model.** An Ed25519 signature proves possession of the key,
   not who holds it; is the record's stated model complete? `lib/features/chat/domain/carried_record.dart`
9. **Key storage at rest.** (Nick, 2026-10-25: pin to `WhenUnlockedThisDeviceOnly`, PARKED in draft PR #416 until the in-app key backup ships, because "this device only" ends iCloud-restore identity continuity, the only path a new iPhone has today. They ship together.) The per-(island, account) seed lives in the platform secure store,
    (`flutter_secure_storage`), **with no accessibility or backup options passed**, so the
    class is whatever the package defaults to on each platform. Nobody has pinned it. ADR-0009's
    "one key, copied" relies on backup moving it, so it should be pinned deliberately: which
    class, and does Android's backup include it? `lib/services/sovereign_key_store.dart`

## Decided, not yet built (review before the build)

10. **Native Ed25519 verify parity.** Decided 2026-09-01 (design 16 v2): Swift verifies the
    ring's signature against the device-local consented keys before reporting to CallKit. It
    isn't built; the VoIP payload `{"c","k"}` carries no signature yet. When it is, can any
    input verify in CryptoKit and fail in Dart, or the reverse (non-canonical encodings,
    small-order points)? `lib/features/call/presentation/system_call_navigator.dart:88`
11. **In-app key backup encryption.** The backup has been decided but has no code yet, and its
    passphrase-to-key derivation and format want review before any is written.
    `docs/crucible/key-backup-and-known-keys/`
12. **Passkey-derived keys (PRF).** A WebAuthn PRF output, salted with the island id, would
    derive ADR-0009's per-island keys. Is that salt construction sound, and what happens when
    a platform reports PRF support but fails to deliver it? `docs/crucible/passkey-rooted-identity/`

## Parked, needs a specialist before it is reopened

13. **Media E2EE.** Calls are not end-to-end encrypted today (forced relay, SFU). claude-tasks#4185
    says this "needs a specialist", and the v1 group key-management crucible was struck down.
    `docs/crucible/group-e2ee-key-management/`

## Island side (from the island tab's read, 2026-10-25)

14. **Proof of possession at key registration.** It would let `signing_keys` flip from
    per-user to globally unique (island `models.py:1106-1113`). Until then the table records
    "account X presented key P at send time", which is not ownership.
15. **Verifying link signatures when a link is posted** (ADR-0009, "the link is the island's
    first proof of possession"). This is the island's first signature check, so its bytes must
    match the app's exactly: pin it with shared golden vectors, the way the msg/react tags are
    pinned today.
16. **Shape-only validation of the sealed push envelope (§8.1).** What do a version byte and a
    length bound leak, including the size-bucketing leak the friends crucible flagged?
