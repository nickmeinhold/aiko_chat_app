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

## Blocking: design 20 §9 (the sealed ring), PR #403

1. **The key certificate format.** One account's Ed25519 key signs "my X25519 key is K, for
   sealing ring invites to me". The open questions: the fields, expiry, version byte (§8.1),
   and the size against the 5 KB APNs budget (§8.2). Also domain separation, so a certificate
   can never verify as a chat message or a reaction, or the reverse. `design 20 §9.1, §9.4.4`
2. **One statement format for two jobs?** ADR-0009's link (two signing keys, each signing
   "A ↔ B") and §9's certificate (one key vouching for its sibling) are both a key making a
   signed statement about another key. The question is whether one envelope with distinct,
   domain-separated statement types is sound, or whether sharing a format invites confusion
   between them. `design 20 §9.4.5, ADR-0009 ref. 2`
3. **The seal itself (arm C).** The caller seals the signed invite to K, and the callee's handset
   opens it natively (CryptoKit) before Dart runs. The questions: which construction (HPKE base
   mode or a hand-rolled X25519 + HKDF + AEAD), what binds the envelope to its recipient and
   context, and replay. The inner invite already carries a timestamp, checked with a 5 s
   tolerance for clock skew (#393). `design 20 §4`
4. **TOFU pinning and revocation.** The peer pins (signing key, K) per conversation. Questions:
   is a first-contact key swap by the island the only substitution risk, and does a dropped
   signed withdrawal of K leave anything worse than "untidy"? `design 20 §9.4.1, §9.4.3`
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

## Island side

Owed by the island tab (asked 2026-10-25), e.g. `SigningKey` binding and the first proof
of possession that ADR-0009's link makes possible.
