# CRUCIBLE — group-E2EE key management for aiko-chat

> Movement 1 (Ore) artifact: the enthusiasm case + the falsifier. Written at the consent gate, before Heat. The excited author's voice — to be struck cold in Temper (Movement 4), not trusted as-is.

**Captured:** 2026-07-14 (live design session, immediately after the Veilid-rejection + build-our-own-E2EE decisions).
**Target:** GH `nickmeinhold/claude-tasks#1962` (E2EE keystone: messages are signed-not-sealed) + #25. Cross-cutting.
**Slug:** `group-e2ee-key-management`.

## The pick

Design the **group key-management scheme** that lets aiko-chat channel messages be end-to-end encrypted (sealed), not merely signed — for a topology of phones-as-lightweight-participants + an **untrusted island relay/store**, with **AI members** who hold keys and decrypt to run inference.

## Why this one (aliveness × impact)

- **aliveness: 3** — It's the load-bearing next step the whole sovereign thesis waits on, and the crypto seam is so clean it's begging for its mirror. `lib/features/chat/domain/message_signing.dart` is a domain-separated, length-prefixed, self-verifying canonical-byte layer; sealing is its mirror image. Nick named it explicitly. *Oh, of course.*
- **impact: 3** — E2EE is what makes "the island is a replaceable untrusted relay" TRUE rather than aspirational. Today the island reads every byte. This is the keystone (#25) that everything downstream (federation, robots-as-members, "better than Matrix") structurally rests on.
- **product: 9** (peak of the visible substrate).

**Aliveness evidence (concrete, not affect):** the signing layer already solved the hard-and-boring half — canonical bytes (`signingBytes`), fail-loud crypto-boundary invariants, immediate self-verify, a reserved `keyVersion` rotation slot (`sovereign_key_store.dart:30-33`), and `cryptography: ^2.9.0` (X25519 + ChaCha20-Poly1305 + HKDF) already in `pubspec.yaml`. The forge can spend all its heat on the unsolved part.

**Impact evidence:** #25 is titled "the E2EE keystone" and today's decisions (Veilid rejected, build our own island) put it on the critical path — the island's untrusted-relay property is a claim until messages are sealed.

## The spark (the one line that makes me want to drop everything)

*Half of E2EE is already built and tempered in this repo — sealing is signing's mirror, so the only new metal to melt is group key management.*

## The falsifier (what would prove this ore is slag RIGHT NOW)

**Group-E2EE may be blocked on multi-device identity (#27, OPEN).** MLS and every group ratchet assume each member is one stable identity-key leaf. If aiko has not decided whether identity is per-device or per-person, then "who is a member of this group" is undefined and the ratchet has no stable leaf. If Temper confirms group key management cannot be decoupled from #27, the honest output is **"design #27 first"** — a real negative result, not a plan.

Secondary falsifier: the **AI-member-decrypts-to-cloud** reality may make protocol-level forward-secrecy / post-compromise-security partly moot for any group containing a cloud-hosted AI member (that provider sees plaintext by the member model). If FS/PCS buys little for aiko's actual threat model, an expensive MLS-grade ratchet could be over-engineering — a simpler sender-keys scheme may be the right first cast.

## Rejected framings (carried to Cast/Temper)

- "Just use MLS (RFC 9420)" — assumes the #27 leaf question is settled and that a Dart MLS implementation exists/is viable. Both unverified at Ore time; Heat must check.
- "Sender-keys like Signal groups" — simpler, but its FS/PCS story on membership change is weaker; is that acceptable given the AI-member caveat? A real tradeoff, not a foregone conclusion.

## Seam already in place (grounds Cast)

- `lib/services/sovereign_key_store.dart` — Ed25519 identity key, software-held (Secure Enclave is P-256-only), `keyVersion` slot reserved for rotation.
- `lib/features/chat/domain/message_signing.dart` — `signingBytes` canonical structure + `kSigningDomainTag = 'aikochat:msg:v1:EdDSA'`; sealing wants a *distinct* domain tag (reusing signing's was flagged a bug in the PoP crucible).
- `lib/features/chat/data/transport/envelopes.dart`, `origin_envelope.dart`, `message.dart` — the wire/envelope seam sealing plugs into.
- Sibling tempered designs: `docs/crucible/sovereign-message-signing/`, `docs/crucible/pop-identity-binding/`.
