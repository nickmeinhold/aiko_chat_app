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

§9 ("consent carries the key") was broken by the island tab's read on 2026-10-25: the island
reads DM bodies, so a certificate sent on consent reveals the consent. §10 recasts it. Every
account announces its X25519 key to every DM peer, and consent stays device-local.

1. **The key statement format.** An account's Ed25519 key signs "my X25519 key is K". The open
   questions: the fields, expiry, version byte (§8.1), and the size against the 5 KB APNs budget
   (§8.2). It rides inside a DM, so it needs **its own inner domain tag, signed separately from the
   carrying message**. Otherwise its signature is under `aikochat:msg:v1` and it *is* a chat
   message (island tab's catch). `design 20 §10.1, §10.2`
2. **One layout, one tag per statement type.** This extends the existing
   `aikochat:msg:v1:EdDSA` / `aikochat:react:v1:EdDSA` length-prefixed pattern to the key
   statement and ADR-0009's link. **The signer structure goes in the tag, not in the number of
   signatures attached**: the link is mutual and the key statement is single, and a verifier
   that infers the type from the signature count can be fed a one-signature link. Is that
   enough domain separation? `design 20 §10.2, ADR-0009 ref. 2`
3. **The seal itself (arm C).** The caller seals the signed invite to K, and the callee's
   handset opens it natively (CryptoKit) before Dart runs. Questions: which construction (HPKE
   base mode, or a hand-rolled X25519 + HKDF + AEAD), what binds the envelope to its recipient
   and context, and replay. The inner invite already carries a timestamp, checked with a 5 s
   tolerance for clock skew (#393). `design 20 §4`
4. **TOFU on the DM's signing key as the binding.** The peer pins (signing key, K) per DM. The
   2026-09-15 review would accept published keys only with a binding users already trust. Is
   "the key I have been talking to in this DM" that binding? First-contact substitution by the
   island is the named residual risk. `design 20 §9.4.1, §10.4.4`
5. **One copied key per account (ADR-0009 ref. 4).** Every device holds the same Ed25519 and
   X25519 keys. Revoking a lost device therefore means rotating the account's key. We'd like a
   cryptographer to confirm this is a sound choice and not a known trap.

## Shipped, never specialist-reviewed

6. **The message signing byte contract.** Messages and reactions are signed at birth:
   the canonical bytes, field order, and domain separation between messages and reactions.
   `lib/features/chat/domain/message_signing.dart`, `docs/crucible/sovereign-message-signing/`
7. **did:key encoding of the identity.** Multicodec `0xed01` plus the raw pubkey.
   `lib/features/chat/domain/origin_envelope.dart`
8. **The Carried Record's trust model.** An Ed25519 signature proves possession of the key,
   not who holds it; is the record's stated model complete? `lib/features/chat/domain/carried_record.dart`
9. **Key storage at rest.** The per-(island, account) seed lives in the platform secure store,
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
