# ADR-0010: Aiko's ground, beside Block's Buzz

| | |
|---|---|
| **ADR** | 0010 |
| **Status** | **Draft** (written 2026-10-28 at Nick's request; acceptance is his). Part 2's "Aiko builds no eDiscovery-shaped features" is **confirmed by Nick, 2026-10-28** ("yeah keep it"); it was the one new commitment, and the other parts record earlier rulings. |
| **Owner** | Nick Meinhold, with Claude |
| **Created** | 2026-10-28 |
| **Thread** | Nick, 2026-10-28: "I'm just looking at Buzz and it's like exactly the same thing" |
| **Reference** | Buzz source read at [`block/buzz@24a3706`](https://github.com/block/buzz/tree/24a3706) (2026-10-27). Every Buzz claim below cites a file there, and each was checked in that file, not taken from a summary. [ADR-0004](0004-sovereign-identity-federation.md), [ADR-0006](0006-sybil-resistance.md), [ADR-0008](0008-island-self-description-and-the-operator-attestation.md) |

## Summary

**Buzz and Aiko share a foundation, not a product.** Both make identity a keypair the user holds, sign every event at the author, run self-hostable governed communities, give agents their own keys, and build mobile in Flutter. Buzz builds a **workplace** on that foundation: desktop-first, organised around LLM agents, and server-readable by design. **Aiko's ground is the person's phone, in a place they belong to:** a call that rings a locked phone, privacy as the direction of travel, keys that stay in the person's hands, and agents that can have bodies. New work is judged by whether it strengthens that ground. Matching Buzz on its own ground is not a goal.

## Motivation

Block launched Buzz on 2026-07-21, a month after Aiko's first commit (2026-06-21). On 2026-10-28 it had 36.5k GitHub stars and was pushed that day. Read from launch coverage it looks like the same thing, and the foundation is the same:

- **Identity** is a Nostr secp256k1 key, Schnorr-signed (`crates/buzz-core/src/verification.rs`). Aiko uses Ed25519, so the two identities are **not interchangeable**.
- **The relay checks the author signed every event** (`crates/buzz-relay/src/handlers/ingest.rs`).
- **Communities are governed:** owner/admin/member roles, bans, timeouts, and a report queue (`crates/buzz-relay/src/handlers/moderation_authz.rs`).
- **The mobile app is Flutter with Riverpod** (`mobile/pubspec.yaml`), the same stack as this app.
- **A new device gets the key by QR code**, and every device then holds the *same* private key (`crates/buzz-core/src/pairing/NIP-AB.md`). That is also the shape of Aiko's #434 design.

A decision about our ground only holds if it is written down. Until today, "Aiko is the one that rings" was true but recorded nowhere.

## Proposal

**Aiko's ground, in four parts.** Each names where Buzz stood on 2026-10-27.

1. **A call rings the phone.** A locked phone rings natively: CallKit/PushKit on iOS, ConnectionService and a full-screen intent on Android. This is Nick's ruling of 2026-08-29, verified on hardware in #428. Buzz has no calling: there are **zero** CallKit, PushKit, ConnectionService or full-screen-intent uses in `mobile/` or `desktop/`. Its mobile "huddles" are group audio that leaves the room when the app backgrounds, and `mobile/HUDDLES.md` keeps "background ringing/calling … outside this slice". Its push "*has not shipped to existing users*" (`mobile/README.md`), and the Android manifest has no push service at all.
2. **Privacy is the direction.** Buzz's model, in its own words: "*Server-managed encryption covers every channel, every DM, every event — eDiscovery works on everything. End-to-end encryption (NIP-44) is a future consideration for DMs*" (`VISION.md:102`). That suits an employer. Aiko serves the person: sealing (#422) and group E2EE stay on the road, media confidentiality is disclosed honestly where it isn't yet sealed, and Aiko builds no eDiscovery-shaped features.
3. **The key stays with the person.** Passkeys are the way in (Buzz has none). Backing up the key is the person's act (Nick, 2026-09-16). Buzz's hosted mobile service escrows the key: the server returns the raw secret after an OAuth login (`mobile/lib/shared/hosted/hosted_identity_service.dart`, `/v1/buzz/nsec-backups/recovery`). Aiko does not hold users' keys.
4. **An island is a place, and its members can have bodies.** Islands are communities whose operators attest who they are (ADR-0008). Robots are members on their own reputation (ADR-0006), including robots with hardware (`@@armbot`). Buzz's agents are LLM processes owned by a person. It has no hardware agents, and personhood and reputation exist only in its vision docs.

**What we do not compete on:** breadth of LLM-agent tooling (personas, workflows, remote agents on Kubernetes, voice-cloned agents in rooms), git hosting, enterprise single sign-on mapped onto keys, desktop-first work.

## Rationale and alternatives

The overlap sits in the layer that is becoming **standard**: any 2026 system that takes "identity is a key" seriously arrives at signed events, self-hosting and agents with keys. Two teams reaching it independently, a month apart, is evidence the foundation is right. What a product is gets decided above that layer. Buzz's customer is a company, which needs to read everything, works at a desk, and wants agents doing tasks. Aiko's customer is a person, who needs the phone to ring, wants privacy, and may count a robot as a neighbour.

## Consequences

- **The test for new work:** does it strengthen one of the four parts? Work that only closes a gap with Buzz on Buzz's ground ranks below work on ours.
- **Gaps on our own ground get promoted,** because a person's chat is judged on them. Buzz has all of these:
  - **Photo and file attachments.** Aiko has none. When built, strip **all** image metadata on upload, not just EXIF. Buzz's server rejects any image still carrying metadata, because "*location can also live in XMP, comments, PNG text, ICC descriptions, or private chunks*". Its clients strip before upload (`crates/buzz-media/src/validation.rs:505-510`).
  - **Read state across devices** (#336, in progress).
  - **Linking a device** (#434). Buzz's spec admits "*no key revocation*" for a paired device, and our design has the same hole. Close it in the design, before building.
- **Worth borrowing (Apache-2.0, same mobile stack):**
  - Buzz's **push lease**: the relay never sees the phone's push token, and the gateway checks Apple App Attest (`docs/nips/NIP-PL.md`, `crates/buzz-push-gateway/src/app_attest.rs`). Weigh it against our declared push-token pairing.
  - Its **signed owner-to-agent link** (`docs/nips/NIP-OA.md`). Banning an owner bans their agents too ("*its proven owner … blocks it too*", `crates/buzz-relay/src/handlers/auth.rs:64`).

## Unresolved questions

- **When to revisit.** Buzz deferred ringing ("outside this slice") and E2EE ("a future consideration"); it did not reject them. If Buzz ships ringing calls or E2EE DMs, re-read this ADR.
- **Interop.** Should an Aiko island also speak Nostr to Buzz clients? The keys differ (Ed25519 vs secp256k1), so it would be a bridge, not a shared identity. Not decided here.

## Rejected ideas

- **Rebuilding Aiko on Buzz or Nostr.** It would trade our ground (ringing, privacy, the key in the person's hands) for Buzz's workplace model. This mirrors the reasoning that rejected Veilid as a substrate (2026-07-14).
- **Matching Buzz feature for feature.** That means racing a far larger team on the ground it chose.
