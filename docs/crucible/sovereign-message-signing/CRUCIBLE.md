# CRUCIBLE — Client-side sovereign message signing

> The enthusiasm case, stated so the Temper adversary can see exactly what heat was smuggled into the design. Movement 1 output (Ore), written at the consent gate. Forged 2026-07-08.

## The pick

Give every outbound chat message a **sovereign signature the app produces itself**: the phone generates an ed25519 keypair, holds the private key in device secure storage, signs a canonical serialization of each message, and attaches `sender_pubkey` + `sig` as fields the gateway carries **opaquely**. Message origin becomes *provable by the sender's key* instead of *asserted by the gateway's JWT session*.

## Why it glows (aliveness 3)

- The federation north-star (Design 06, 08; multiple memory files) is one idea: **identity owned by no gateway.** Today the opposite is literally hard-coded — `SendFrame` at `lib/features/chat/data/transport/envelopes.dart:211` says *"NO sender field by construction (server derives it — I5)."* The gateway is the **sole** authority on who said what.
- This is the **one federation primitive the app can fix unilaterally** — no `#1760`, no island tab, no peer-owned gateway edit. The signature bytes are gateway-opaque passthrough. It's the phone doing the phone's own job (Design 08: "the phone holds the self").

## Why it matters, and why NOW (impact 3)

- Design 08 §9, in its own words: **"Sign messages with the sovereign key from day one... Catastrophic to retrofit."** Every day messages flow unsigned is more unsigned history and a larger migration. Cheap today, catastrophic deferred — the impact-timing dial pinned to max.
- It unlocks the relay-and-verify federation paths (Design 06 §5 courier path, Design 08 delivery ladder) "for free" later: a courier/peer can carry a message and the recipient can verify origin *without trusting the carrier*.
- Design-for-subtraction, aimed at the future: sign now → the direct-P2P and blind-relay paths need no new identity work when they arrive.

## The falsifier (fired at Ore — this is why the ore is real)

**"Slag if messages are already signed with a device-sovereign key."**

Instrument (2026-07-08):
- `SendFrame` (`envelopes.dart:212-233`) carries only `clientMsgId`, `channelId`, `body`, `replyTo`. No `sig`, no `pubkey`.
- Only crypto dep is `crypto: ^3.0.7`, used solely for OAuth PKCE sha256 (`broker_auth_client.dart`).
- Passkey (WebAuthn) keys are non-exportable and auth-ceremony-scoped — they cannot sign an arbitrary chat body.

→ Messages are **not** signed. The design's "already true" was a **laundered assumption**; the enthusiasm was wrong, which is exactly why the ore is gold. **Ore confirmed real.**

## The brittleness I already smell (hand this to the Temper)

Signing is app-owned and cheap. **Key *management* is not.** Open, coupling-prone questions:
- One key per **device** or per **account/identity**? (Device is app-autonomous; account-identity couples to Design 06's sovereign-identity model, which is island/peer-coordinated.)
- Rotation, revocation, multi-device, recovery-when-phone-lost.
- The **trust root**: signing proves "the holder of key K said this"; it does NOT by itself bind K to a human/account. That binding is federation's (Design 06 / #1760) job.

**Proposed scope discipline (the line the Temper must test):** ship the **signature bytes** — forward-compatible ed25519, detached sig over a canonical serialization, gateway-opaque — while treating **trust-root binding + verification + cross-device key lifecycle as explicitly out-of-scope, named-open**. If that line doesn't hold, the candidate may be premature. That's the strike I want.

## Rejected alternatives (carried forward for Cast)

- **Passkey management UI (#2)** — real but partly gateway-blocked; not app-autonomous.
- **Delivery-state receipts (#3)** — needs gateway read-receipts; gateway-shaped.
- **Freezed migration (13 domain types)** — real inward debt, but a chore: aliveness 1. No glow.
- **Do nothing until Design 06 settles** — the alternative the Temper will surely raise; the counter is the "catastrophic to retrofit" timing, but it must be defended, not assumed.

## Scores

- Aliveness **3** — evidence: it's the north-star made concrete and app-ownable; the gateway-owns-identity fact is hard-coded and this is the one unilateral fix.
- Impact **3** — evidence: removes the design's own named "catastrophic" future retrofit and unlocks the relay/courier federation paths.
- Product **9**. Peak of the melt.
