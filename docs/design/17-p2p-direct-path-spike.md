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
| This host can discover its **public** address via STUN — the precondition for a real cross-internet direct call | `srflx` candidate gathered against two independent public STUN operators | `integration_test/p2p_stun_reflexive_test.dart` |

Measured 2026-09-01 on macOS, against the locked `flutter_webrtc` 1.6.0:

```
[P2P-SPIKE] caller: selected=host/host gathered[host=21]
[P2P-STUN]  gathered: {host: 21, srflx: 1}
```

The first line is the direct connection with no SFU. The second is the same stack reaching
the internet and learning its own public address — `srflx=1` is the token that says a call
to another network is *possible from here*.

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

---

## Round 1 cage-match ledger (2026-09-01)

Seats: Maxwell + Kelvin + Carnot + Tesla — 4/4. Diff 58KB at `-U9999` (lockfile cut to
`-U3` to keep every seat inside its validated range).

| Verdict | |
|---|---|
| Kelvin | APPROVE (one style nit) |
| Carnot | REQUEST_CHANGES |
| Tesla | REQUEST_CHANGES |
| Maxwell | COMMENT |

| Finding | Raised by | Real? | Disposition |
|---|---|---|---|
| `usedRelay` reports **false** from a half-resolved pair | Carnot + Tesla (independently) | **yes** | fixed — `true` needs one relay, `false` needs both ends known; RED arm proven by reverting |
| Selected pair took first nominated-**or**-succeeded in stats order | Tesla | **yes** | fixed — `succeeded` mandatory, nominated preferred, ties break on bytes carried |
| The dangling-id test dangles BOTH ids, so it cannot catch the one-sided case | Tesla | **yes** | fixed — one-sided arm added; live test now asserts `selectedPairFullyResolved` |
| Trickle-buffer test passes with the buffer deleted | Carnot + Tesla | **yes** | fixed — `_OfferDelayingSignalling` forces the race; run reports `candidates delivered BEFORE the offer: 1` |
| `dispose()` after the expects leaks native PeerConnections on any red | Carnot + Tesla | **yes** | fixed — `addTearDown` at construction, both integration tests |
| `iceTransportPolicy` is a `String?` on a knob whose typo changes architecture evidence | Carnot | **yes** | fixed — `P2pIceTransportPolicy` enum |
| `start()` failure strands `_connectedCompleter` → caller hangs | Maxwell | **yes** | fixed — completes false and rethrows |
| `dispose()` closes a signalling channel it did not create | Maxwell | **yes** | fixed — ownership follows construction |
| `unawaited(send)` leaves an unhandled zone error | Maxwell | **yes** | fixed — explicit `catchError`, contract written not merely intended |
| `{...r.values}` spread last could clobber `id`/`type` | Maxwell | **yes** | fixed — spread first |
| Doc said "five ICE candidate types", enum holds four | Tesla | **yes** | fixed |

**Round 1 was NOT clean** — eleven findings survived verification as real, which is the
point of running it. A second round is owed before this could be called closed by the
Round 9.7 bar; it is a spike nothing calls, so that is a gate on *promoting* it, not on
leaving it here.

### Named residuals, not fixed

- **The instrument's true-positive arm has never rung.** Tesla's sharpest concern: twelve
  fixtures and a loopback prove the tally can see `host`. It has never seen an actual TURN
  relay against a live stack, and that is the reading the SFU decision needs. Needs a TURN
  server; noted rather than faked.
- **`readSelectedPair` is macOS-shaped.** A mobile `getStats()` that stringifies numbers,
  emits `googCandidatePair`, or spells the type `relayed` is a different instrument wearing
  this one's name. First mobile run must re-verify, not assume.
- **Multiple m-lines.** One data channel means one pair. When `localStream` grows a second
  media section, "the pair that carried the most bytes" is a heuristic, not a definition.
- **`p2p_stun_reflexive_test.dart` is comment-gated, not glob-gated** — a run of the whole
  `integration_test/` folder inherits Google/Cloudflare uptime. (CI is closed in this repo,
  so nothing runs it today.)
- Kelvin returned **APPROVE with zero real findings** on a round where two other families
  found a genuine instrument bug. Per the skill's own rule that is a coverage gap, not
  agreement, and it is recorded as such rather than banked.
