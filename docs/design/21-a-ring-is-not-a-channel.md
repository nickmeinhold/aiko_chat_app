# Design 21 — A ring is not a channel: identity for the Android ring

**Status:** DRAFT for `/design-temper`. Not a decision.
**Origin:** PR #210 (`feat/android-ring`, claude-tasks#4421) reached the cage-match round cap (3)
with real findings in every round. Under the 2026-08-23 ruling, a diff still producing findings at
round 3 goes to a design pass, not to a fourth review round. This note says what the rounds found
and proposes the shape underneath them.

## What is built (and hardware-verified)

The Android receive half of the call ring. An FCM data push `{c, k}` reaches `AikoMessagingService`.
`CallRing.handle` applies a total function on `k`. `call_invite` puts up an insistent full-screen
notification, shows a native `IncomingCallActivity` over the keyguard, and warms the shared Flutter
engine so `admitRing` admits the signed invitation while the phone rings. Answer requires an unlock,
then emits `answered` over `call/actions` to the existing `SystemCallNavigator`, which joins only an
admitted invitation. Verified on a Pixel 4 / Android 13: cold + dozing + locked → ring, `call_end`
→ stop, Answer 40s after signing → call screen with camera, Decline → warmed engine torn down.

## What three rounds found

19 real findings were fixed across rounds 1-3. Their distribution is the evidence for this note:

| class | instances (round) |
|---|---|
| **Event applied to the wrong ring** — an action, listener or callback names only a channel, and lands on a different ring of that channel, or on the next engine | stale `ended` in the held buffer (r1 ×3 seats); ring screen bound to a displaced caller (r1, r2); backstop no-op at the expiry boundary (r2); `ended` after Answer lost (r2 ×2 seats); duplicate invite after Answer re-rings a taken call (r3); expired ring's posted `ended` fires against the new ring (r3); keyguard callback answers the old ring and finishes the new caller's screen (r3); held buffer drained into a later engine (r3 ×2 seats) |
| **One record, several concerns** — the SharedPreferences record is the ring phase AND the answer latch | Answered state added (r2), then overwritten by any invite (r3) |
| Lifetime / threading, each fixed once and not recurring | exported answer surface (r1), work outside FCM's wake lock (r1), one engine with two lifetimes (r1), two clocks (r1), reboot clock (r2), deferred-registration race (r1) |

The third row converged: each was fixed and nothing came back. The first two rows did not. Each fix
removed one instance and the next round found another, which is the signature of a missing concept,
not of careless code.

## The missing concept

**A ring has an identity, and the code uses the channel as that identity. A channel is not an
identity.** One channel can ring, end, be answered, ring again, and be displaced, all within a
minute. Every message that says only "channel X" is ambiguous about which of those rings it means:

- the stop listeners (`onRingStopped(channel)`),
- the `call/actions` events (`{action, channel}`),
- the held buffer that carries those events to a Dart that isn't listening yet,
- the keyguard callback (`openAnswered(c)`),
- the persisted record (one slot, keyed by channel),
- the timer (patched in r2 to `(channel, at)`, which was the first local instance of the fix this
  note proposes).

## Proposed recast

1. **A ring id, minted locally per ring.** `CallRing.ring` mints an opaque id (a counter, or
   `elapsedRealtime` + boot count) the moment a ring begins. Everything a ring creates carries it:
   the notification's intents, the ring screen's binding, the timer, the stop-listener callback, the
   keyguard callback, and the `call/actions` event. Every transition is keyed on `(channel, ringId)`.
   An event whose ring id isn't the current one is a no-op by construction. That removes the
   wrong-ring class instead of guarding each of its sites.
2. **The answer is its own slot, not a phase of the ring record.** `Ringing` and `Answered` are
   different facts with different lifetimes (60s vs 120s) and different enders (`call_end` while
   ringing vs `call_end` / Dart teardown after answer). Two slots: a new invite never touches the
   answer slot, and a duplicate invite for an answered `(channel)` is recognised as the same call
   *if* the island's invite carried an identity (see Q1). Until then, see Q2.
3. **The event buffer belongs to an engine, not to the process.** `held` lives on the engine
   `AikoEngine.obtain` creates and dies with it. An event emitted with no engine is buffered for the
   engine about to be created *by this ring*, keyed by ring id, and dropped if that ring retires
   first.
4. **`call/actions` carries the ring id to Dart.** `SystemCallNavigator` holds answers keyed by
   `(channel, ringId)`, and an `ended` for a different ring id doesn't consume them.

## Open questions — the temper should attack these

- **Q1. Should the ring id come from the WIRE?** The island's invite has a server message id. A
  wire-level identity, e.g. `{c, k, m}` with `m` = the invite's server id, which `call_end` already
  names via `reply_to`, would let the receiver tell *the same call delivered twice* from *a new call
  on the same channel*. A local id can't make that distinction. Tesla's r1 concern (a redial inside
  60s after a lost `call_end` is swallowed as a duplicate) and r3 finding 1 are both that missing
  wire field. Cost: an island change (#4421 contract), and FCM `data` stays `map<string,string>`.
  **Is a local id worth building if the wire id is the real answer?**
- **Q2. Without a wire identity, what is a duplicate?** Today: same channel, still Ringing. With
  an Answered slot: is `invite(c)` while Answered(c) a duplicate (drop), or a new call (ring
  again)? Both are wrong in one case. This may be undecidable on the current wire, which would make
  Q1 a prerequisite, not an option.
- **Q3. Is the iOS side carrying the same flaw?** `CallKitRinger` keys its UUID map by channel and
  has `answeredCallTrustWindow` (8h) because of a duplicate-push incident. If the right answer here
  is a wire identity, iOS should probably converge on it too.
- **Q4. Is this the wrong frame?** The rounds also kept finding *lifetime* defects
  (engine × activity × ring). Maybe the deeper missing concept is "who owns the engine", and identity
  is a symptom. The author has been inside this diff for a night.

## What is NOT in question

The native lock-screen ring screen, warming the engine at push time, the compile-time calling gate,
the single answer door (non-exported activity), and doing the work inside FCM's wake lock were each
challenged in review and held. The hardware results stand.
