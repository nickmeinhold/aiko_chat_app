# Spike 17 — the P2P direct path, app side

**Status:** SPIKE. Merged or not, nothing in the product calls it. `LiveKitCallService`
remains the only call path the app ships.

**What it is for:** turning claude-tasks#3740's central claim from an argument into an
artifact that can go red.

> The hard part of P2P WebRTC is **rendezvous, not media** — so the centralised media plane
> is a workaround for a problem the Dart port dissolves, not a technical necessity.

---

## What is proven

| claim | how | where |
|---|---|---|
| `flutter_webrtc` is usable standalone, outside LiveKit's wrapper | `dart analyze` against the **locked** 1.6.0; every symbol resolves | — |
| Declaring it costs nothing | `pubspec.lock` moved exactly one line: `transitive` → `direct main`. No version moved, no package added | `pubspec.yaml` |
| Two peers complete offer → answer → trickle → **connected**, no SFU, no LiveKit, no signalling server | real `PeerConnection`s on a real host | `integration_test/p2p_direct_path_test.dart` |
| A candidate arriving before the remote description is buffered, not dropped | the trickle race, exercised | same |
| The relay instrument reads a live stats report, not a fixture | `getStats()` → nominated pair | same |
| The instrument cannot silently miscount | 12 pure-Dart tests, incl. must-not-lie arms | `test/features/call/ice_candidate_tally_test.dart` |

## What is NOT proven — read this before quoting the green

**Nothing about NAT traversal, and therefore nothing about fallback-vs-deletion.** Both peers
in the integration test are the same host and connect over loopback on `host` candidates. The
question that decides whether the SFU is a fallback or a deletion is *what fraction of real
calls cannot form a direct path*, and **this test cannot observe that.** It needs two devices
on two real networks.

The tally's verdict on this run (`usedRelay == false`) is a fact about a loopback. It is
asserted only to prove the instrument works against a live stack.

Also unproven: media quality, reconnection (ICE restart is a different mechanism from the
SFU path's backoff), mobile behaviour, and anything at all about battery.

## What is deliberately NOT built

- **No wire.** The obvious next step is carrying SDP in a signed message, the way the call
  invite already is. That is a **one-way door** — `kCallInviteBody` is a pinned sentinel in
  permanent signed history, and a new sentinel is the same kind of door on a contract the
  island tab co-owns. `CallSignalling` is an interface whose only implementation is an
  in-memory loopback. Wiring it is a separate, two-tab decision.
- **No transport-policy opinion.** `iceTransportPolicy` is a constructor argument with no
  default. The force-relay question *inverts* on a direct path — on an SFU there is no
  participant-to-participant channel so `.all` leaks nothing; on a direct path that channel
  is the whole mechanism. That is a decision for the design, not a constant for a spike to
  smuggle in.
- **Nothing wired to production.** No provider, no route, no UI, no telemetry hook.

## The instrument, and why it exists now rather than later

`IceCandidateTally` answers *how did this call actually connect?* — the number the SFU
decision needs and nobody has for aiko's users. Published WebRTC traversal figures are a fact
about someone else's population.

Two design points worth keeping:

1. **Gathered candidates are not the answer; the nominated pair is.** A peer gathers relay
   candidates whenever TURN is configured, which says nothing about the path taken. Reading
   gathered candidates as "relay used" would report relay on every call and be confidently
   wrong — a reading independent of the thing it measures.
2. **`usedRelay` is tri-state on purpose.** Null means *unmeasured*, not *no relay*. A bool
   would make "we didn't look" indistinguishable from "we didn't need one", and the entire
   point is counting relays.

## How to run it

```bash
flutter test test/features/call/ice_candidate_tally_test.dart   # pure Dart, anywhere
flutter test integration_test/p2p_direct_path_test.dart -d macos # real WebRTC stack
```

The macOS run prints `[P2P-SPIKE]` lines carrying the candidate tally.

## What this changes about the open questions

- **Gate 2 of #3740's three** (*"is `flutter_webrtc` usable standalone?"*, recorded NOT
  CHECKED) is **closed**. Cost: promoting one transitive dependency.
- **Gate 1** (a phone cannot reach an island's broker) is the island tab's measurement, and
  design 16 §6a adds the harder floor underneath it: a suspended iOS app holds no sockets, so
  the rendezvous can move but **the wake cannot**.
- **Gate 3** (cross-island rendezvous) is untouched and remains the genuinely open one.

Neither of the two live decisions is pre-empted: whether the sender-anonymity decision binds
the ring path, and whether the SFU is a fallback or a deletion. This spike takes no position
on either.

## Provenance

Claude (app tab), 2026-09-01, overnight, at Nick's request to leave something running.
Grounded in `pubspec.lock` (not the pub cache), the locked `flutter_webrtc` 1.6.0 source, and
`call_session.dart` / `livekit_call_service.dart` for the shape the direct path mirrors.
Claims about the island's broker and registrar are the island tab's, attributed as such and
not re-measured here.
