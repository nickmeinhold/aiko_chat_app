# Design 16 — the CallKit ring, client half

**Status:** RECAST — struck 4/4 families 2026-09-01, verdict in [`16-callkit-ring-TEMPER.md`](16-callkit-ring-TEMPER.md).
**Do not build from this document as written.** Twelve fatal flaws stand; §2, §3 and §4 are
under recast, and the temper adopts a hard gate: no `CXProviderDelegate` line until flaw 5
(is ringing a capability of an established relationship?) is decided — reversibility is lost
once the phone rings.

**The other half of the record:** `../aiko-chat-island/docs/design/12-native-call-ui-callkit-connectionservice.md`.
That document is the island tab's and is deliberately not restated here. It names four
obligations as the app tab's and one of them it records us as having *taken*
(Decision 1c). None of them had a document in this repo until this one. This is that
document, and where it disagrees with design 12 the disagreement is marked, not folded in.

**Decision of record it rests on:** Nick, 2026-08-29 — the client will use **CallKit +
PushKit on iOS** and **ConnectionService + full-screen intent on Android**
(claude-tasks#3609; recorded in design 12's header).

**Tier:** trust boundary. The ring is the loudest privilege in the product and this design
moves the moment of decision to *after* it fires. Cage-match by law, and the design gets
a `/design-temper` before any of it is built.

---

## The one-sentence version

Every local gate this app enforces before a phone makes a sound stops being enforceable in
that order, because CallKit rings before Dart exists — so the client's job changes from
**deciding whether to ring** to **deciding how fast to stop**, and since the first of those
gates is the signature check, a product built on signed-at-birth would be shipping a ring
that fires before proof.

## What this supersedes

**claude-tasks#3588 is answered here, not fixed there.** #3588 is "the notification tap
does not route to the call". On the CallKit path there is no notification tap: there is a
`CXAnswerCallAction`, delivered to a Swift provider delegate. The missing-handler diagnosis
was correct and remains correct **for the alert path**, which survives for Android until
FCM lands (design 12 Decision 8) and for every non-call notification. So #3588 does not
close; it narrows to the alert path and stops being the ring's blocker.

The 17.55s-vs-10s measurement from 2026-08-31 keeps all of its force, for a reason that
outlives its own path — see §1.

---

## §1 — The two clocks collapse into one, and our code holds the constant in THREE places

Design 12 states the reconciliation:

> `_EXPIRATION_SECONDS = 60` (island) and `kCallInviteFreshness = 10s` (app) are two answers
> to one question... the two collapse into one number with a physical meaning (ring
> duration), derived from call semantics rather than wire latency.

Agreed, and this design adopts it. What design 12 could not see is that
`kCallInviteFreshness` is load-bearing in this repo in three places, and only one of them
is the gate everybody has been looking at.

| # | site | what it does | under the collapse |
|---|---|---|---|
| 1 | `call_invite.dart:815` | `age > kCallInviteFreshness → RingRefusal.stale` | becomes a liveness question (§2) |
| 2 | `ring_controller.dart:92` | forgets a held hangup after `kCallInviteFreshness * 2` | **must re-bind, or a ring outlives its own stop** |
| 3 | `call_invite_test.dart:996` | pins `kCallRingDuration > kCallInviteFreshness` | **becomes `X > X` — false** |

**Site 2 is the one that bites.** `_ended` holds a signed hangup that arrived *before* the
invite it names — at-least-once, locally-out-of-order delivery makes that ordinary, and
push makes it likelier by construction, because the island wakes a handset on the invite
body only. Retention is bounded on freshness×2 (20s) with the stated reason *"an end is
only useful while its invitation could still be ADMITTED"*. That reason is exactly right
and it is why the bound has to move: under CallKit the invitation can be admitted for as
long as the phone is ringing. A hangup garbage-collected at 20s while a 30s ring is still
audible is a phone ringing for a corpse **because we forgot the stop**, which is the
inverted failure design 12 names, arriving through our own retention policy rather than
through the island.

New bound: the hangup must be retained at least as long as a ring can last, plus delivery
slack. Concretely `kCallRingDuration + kPushDeliverySlack`, and `kPushDeliverySlack` is a
real constant that has to be argued, not a fudge — it is the answer to *"how late can a
stop arrive and still matter?"*

**Site 3 is a trap, and should be read as a compliment to whoever wrote it.** The test
group is literally named `'the two clocks are different numbers'` and pins both halves:

```dart
expect(kCallInviteFreshness, const Duration(seconds: 10));
expect(kCallRingDuration, greaterThan(kCallInviteFreshness));
```

That is the two-clock model written down as an assertion, with its reason in the comment
above it (*"conflating the staleness gate with the ring duration is how you ring for a call
that already ended"* — Nick, 2026-08-15). Collapse the clocks and both lines go red,
*correctly*. The failure mode is someone deleting the group to make the suite green, which
retires the invariant instead of replacing it — and the comment makes clear this test was
protecting a real thing Nick said. It must be replaced by the liveness invariant of §2 in
the same commit that collapses the constant, never in a later one, and the 2026-08-15
reasoning has to be shown to still hold under the replacement rather than deleted with it.

**What the 17.55s still proves, in the new frame.** It is not a fact about a gate we are
deleting. It is the only measured value we have for *the interval between a caller pressing
call and a human getting to the phone*, and under CallKit that interval is still the thing
the ring duration has to cover. It survives as a calibration input, not as a bug report.

## §2 — Freshness was a proxy; the object is liveness, and we already half-hold it

The gate asks *"was this signed recently?"*. What it is trying to know is *"is this call
still happening?"*. Those coincided when delivery was sub-second live-websocket, which is
why the constant read as correct for a year and why `call_invite.dart:60` justifies it with
*"live WS delivery is sub-second"* — a true sentence about the WS path, load-bearing on a
path it does not describe. On a locked handset the Dart isolate does not exist until the
human acts, so the "age" the gate computes is *delivery latency plus a person deciding to
pick up the phone*. It reads attention with an instrument built for transport.

**The authoritative liveness signal already exists and is already signed.** `kCallEndBody`,
carrying its target in a signed `replyTo`. `RingController._ended` already keeps them.
Liveness is therefore:

> A call is live if its signed invite is inside the ring window derived from
> `OriginEnvelope.signedAtMs`, **and** no signed end naming it has been seen.

Two properties worth stating because they are what make this safe to adopt:

- **`call_invite.dart:441`'s refusal survives untouched.** That comment refuses to key
  freshness to `Message.createdAt` because the island writes it and could re-stamp a
  week-old invite. Everything above keys off `signedAtMs` and a signed end. The island
  gains no new authority in this design. That constraint is answered, not stepped around
  — which was the explicit ask on #3588.
- **The replay case is still refused, by the same window.** The free positive control from
  2026-08-31 (a 41-minute-old backlog invite refused at 05:17:21, 42ms after sign-in) stays
  refused, because 41 minutes is outside any plausible ring window. The 17.55s tap is
  inside it. **One clock separates both cases** — which is the claim design 12 makes and
  this is the arithmetic that supports it in our code.

**The residual, named rather than buried:** a caller whose phone dies sends no end. Liveness
then rests entirely on the window, which is why the window cannot be large. It is a ring
duration, and a ring duration is a human-scale number with an independent reason to exist.

## §3 — Decision 1c: the ceiling we were recorded as having taken

Design 12:

> A CallKit ring is system UI drawn before Dart exists and **does not self-expire** — it
> ends only when something calls `reportCall(with:endedAt:reason:)`. So the 30s ceiling has
> to be re-established somewhere that survives app suspension. **The app tab owns
> re-establishing it and has taken it.**

**It had no home in this repo.** No design note, no task — a global tracker search across
`CallKit`, `PushKit` and the ring ceiling returns #3609 (the design question) and nothing
app-side. Recording that plainly, because a commitment the other half of a contract
believes we hold is worse than an unstarted one.

Today's ceiling is `RingController._republish()`, and it is already the right *shape*:

```dart
final left = kCallRingDuration - DateTime.now().toUtc().difference(live.startedAt);
```

Derived from the signed `startedAt`, never restarted, so no number of rebuilds extends a
ring. That derivation is the part to keep. What cannot survive is where it runs: a Dart
`Timer` in a process the OS has not started.

**Three candidates, none chosen. This is the fork the temper should hit hardest.**

- **(a) Swift owns the ceiling; Dart mirrors it.** The provider delegate schedules the
  end-call at `signedAtMs + kCallRingDuration` when it reports the call. Cheapest, and it
  is where the platform already requires code to run. Cost: the deadline now has **two
  enforcers**, and two enforcers of one deadline is the drift shape we keep paying for
  elsewhere — the constant must cross the method channel as a value, never be re-declared
  in Swift.
- **(b) Swift owns it outright; Dart's timer is deleted.** Subtracts the coupling instead
  of guarding it. Cost: the in-app ring (app already foregrounded, no push) still needs an
  expiry, so this arm has to show that path is genuinely the same path, or it is a
  capability amputation wearing a simplification's clothes.
- **(c) The island sets `apns-expiration` to the ring window and we treat undelivered as
  never-rang.** Reduces the problem but does not solve it — expiration bounds *delivery*,
  not the ring already drawn on a screen. Listed to be dismissed explicitly rather than
  silently.

Preference, stated so it can be argued with: **(b)**, with (a) as the fallback if the
in-app path resists. The reason is not elegance — it is that (a)'s failure mode is a
Swift constant drifting from a Dart one, which nothing goes red on.

## §4 — The inversion nobody has written down: our five local gates fire AFTER the ring

This is the finding this design exists for, and it is not in design 12.

`admitRing` is the app's single trust decision. Enumerated from the `RingRefusal` enum
rather than from its prose — the doc comment lists five, the enum carries **nine**
start-gate refusals of a real attempt, and the two that the prose omits are the two that
matter most:

| refusal | what it stops today |
|---|---|
| **`unverifiedOrigin`** | *"unsigned, or carried-but-invalid — the security-relevant refusal: a ring that could not prove who sent it"* |
| **`originMissing`** | verified but no envelope; an upstream invariant broke |
| `anonymousSender` | a sender with no `userId` — nobody you could name or block |
| `consentWithheld` | a non-human sender this conversation has not allowed |
| `notDirectMessage` | channel-wide ringing, gated until per-call consent exists |
| `senderBlocked` | a blocked sender (defence in depth over the island's filter) |
| `conversationMuted` | *"mute is attention-scoped and a ring is the loudest attention there is"* |
| `clockSkew` | signed in the future; a bad clock could otherwise ring forever |
| `noServerId` | a ring no hangup could ever name |

**The head of that list is signature verification.** In a product whose thesis is
signed-at-birth, `admitRing` refusing `unverifiedOrigin` is the moment the sovereign key
does its job for the loudest privilege in the app.

Design 12 Decision 4 states the platform constraint honestly:

> Since iOS 13, **every VoIP push must be reported to CallKit before the delivery handler
> returns**... The client cannot receive a VoIP push, check liveness, and decline to ring
> — it must ring first. So send-time correctness moves onto the island.

That sentence is true and its app-side consequence is unstated: **all nine refusals become
post-hoc.** The sequence is ring → Dart starts → `admitRing` → `reportCall(with:endedAt:)`.
Every one converts from *silence* into *a phone that rang and then stopped by itself*.

**Taken to the top of the table, that is the finding: an invite with a forged or absent
signature rings the handset — full-screen, through silent mode and DND — before anything
verifies it.** The verification still happens and still refuses, milliseconds later. But
the ring is not the consequence of the trust decision any more; it *precedes* it. A design
whose entire premise is that a ring must be provably from someone would be shipping a ring
primitive that fires before proof. That is a trust-boundary change, not an ordering detail,
and it is the sentence this document exists to put in front of a reviewer.

The obvious mitigation is worse than it looks: **have the island verify the signature
before it sends the VoIP push.** It can — the invite is a signed message it already stores.
But then the thing standing between a stranger and Nick's phone ringing at 3am is *the
island's* check, and the island is precisely the party `call_invite.dart:441` refuses to
trust with the freshness decision. Moving verification server-side to protect the ring
inverts the position the rest of the call design is built on. It may still be the right
trade — a ring that always fires and sometimes retracts may be worse than an island we
already depend on for delivery — but it must be argued, not assumed, and it belongs in the
same cage-match as design 12's Decision 7.

For `senderBlocked` the post-hoc ordering is arguably acceptable — a blocked sender is
already filtered island-side and this was only ever defence in depth. **For
`consentWithheld` and `conversationMuted` it is a product regression, and it is the kind a
user experiences as broken.** `push_service` already
carries the accepted risk that a muted DM wakes the handset *"because mute is client
state and you cannot un-ring a phone"* — priced against a banner. Under CallKit that same
accepted risk is a full-screen ring through silent mode and DND for a conversation the user
explicitly muted. Design 12 Decision 7 re-prices this island-side. The client half is:
**we cannot fix it here, and we must not pretend the local gate does anything it no longer does.**

**Three directions, none decided:**

- **(i) Move consent island-side.** The allowlist becomes something `should_wake` can
  evaluate, so a refused caller never gets a VoIP push at all. Correct and expensive: it
  publishes to the island a per-conversation fact the client currently keeps to itself
  (claude-tasks#3575 is the allowlist consent UI; this changes what that UI is promising).
  It is also a privacy trade — the island learns who you will accept calls from.
- **(ii) Ring, then retract fast, and say so in the UI.** Keep everything local; accept a
  sub-second ring for a refused caller. Needs a measured retraction latency before it can
  be called sub-second, and needs the settings copy to stop claiming mute silences calls.
- **(iii) Two push classes.** Callers who have passed consent get a VoIP push; everyone
  else gets today's alert. Ringing becomes a property of an established relationship. This
  is the most interesting arm and it is the least explored — it also makes first contact
  strictly quieter than an established one, which may be the correct product behaviour
  independent of the mechanism.

**This must not be decided by whoever is holding the keyboard when the code needs it.**
It is a product call about what mute and consent mean, and (i) and (iii) both change what
the island learns.

## §5 — Token kinds, and why our debt store is the sharp edge

Design 12 Decision 2 adds `token_kind` (`alert` | `voip`), and Decision 2a names the worst
state in the system: a sign-out that discharges only one kind leaves a routable VoIP row,
which under CallKit is *a stranger's phone ringing full-screen for the previous owner*.

Grounded in our code, three specifics:

- **`PendingUnregisterStore` keys `island → Set<token>` with no kind.** The set is already
  correct in shape (rotation makes multiple live tokens real — cage-match round 3), so the
  change is to record the kind alongside each token, not to restructure. `_maxPerIsland = 16`
  should be re-argued once each sign-out can owe two tokens rather than one; the eviction
  is logged, which is why this is a number to re-price and not a silent risk.
- **`DeviceRegistrar` has one token stream.** `ApnsTokenChannel` handles a single
  `didRegisterForRemoteNotifications` callback with a rotation stream. PushKit is a second,
  independent registry with its own rotation. Design 12 Decision 2's permission asymmetry
  is the part to hold onto: **a VoIP token requires no user permission at all**, so a user
  who declines notifications has a VoIP token and will never have an alert token. Our
  `requestPermission` treats a denial as an ordinary answer — correct, and it now also means
  *"reachable for calls, unreachable for messages"* is a normal state we must model rather
  than an error.
- **Unregister is `(user_id, token)`-matched island-side**, so the debt cannot be drained
  by a different user (already documented in `device_registrar.dart`). Two kinds does not
  change that; it doubles what a partial drain leaves behind. This intersects
  claude-tasks#3723 (sovereign-key-signed DELETE) — **if the signed unregister lands, it
  covers both kinds by construction**, which is an argument for sequencing #3723 before
  `token_kind` rather than after.

## §6 — The caller name, and the one place Dart cannot help

Design 12 Decision 6 lands on a Swift-readable caller-name cache (App Group /
`UserDefaults`, keyed by channel id) that Dart maintains as the roster updates, with three
honest tiers: local cache → `reportCall(with:updated:)` once Dart is up → the placeholder
`Aiko`. Adopted as written; the app tab owns the cache and the roster hook.

One app-side consequence to record: this cache is **a plaintext, on-disk map of channel id →
human name, readable without the app running.** That is a new artifact with a new exposure,
small but real, and it should be stated in the visibility-boundary doc (claude-tasks#3695)
rather than discovered by it.

## §7 — Sequencing

1. **§1 sites 2 and 3** — re-bind `_ended` retention, replace the pinned two-clock
   invariant. Small, and it is the only part that is safe to do before the fork in §4 is
   decided, because it is correct under every arm.
2. **§4 decided** by Nick. Everything downstream branches on it.
3. **§3 ceiling**, in the same change as the first Swift provider delegate.
4. **§5 token kinds**, sequenced against claude-tasks#3723.
5. **§6 cache**, with its line in #3695.

§3, §4 and §5 are **one cage-match, not three** — same trust boundary from three sides,
mirroring design 12's own sequencing note for its Decisions 4/5/7.

## Open questions

- **§4's signature ordering is the largest open question in this document** and it is not
  a product call — it is a trust-boundary call, and neither arm is comfortable: ring before
  proof, or move proof to the island. It may also be the strongest argument for arm (iii),
  since a VoIP push restricted to established relationships bounds who can fire an
  unverified ring at all.
- **§4's consent arms are the product question**, separately. (i), (ii) and
  (iii) have different privacy costs and (iii) may be right on its own merits.
- **`kPushDeliverySlack` has no value and no derivation.** It is the honest name for a
  number this design needs and has not earned.
- **The in-app ring path under arm (b) of §3** is unexamined — whether it is genuinely the
  same path as the push-woken one, or whether (b) amputates it.
- **Android is unscoped here.** ConnectionService, full-screen intent, and FCM's single
  token are design 12 Decision 8; the Play `USE_FULL_SCREEN_INTENT` declaration
  (claude-tasks#3615) is slower than the code and is Nick's to submit.
- **Retraction latency in §4 arm (ii) is unmeasured.** "Sub-second" is currently a hope.

## Provenance

Claude (app tab), 2026-08-31/09-01. Grounded in `call_invite.dart`, `ring_controller.dart`,
`pending_unregister_store.dart`, `device_registrar.dart`, `ios/Runner/AppDelegate.swift`,
design 12 read end-to-end, and claude-tasks#3588/#3609 read end-to-end including comments.
The measurement in §1 is from the 2026-08-31 on-device run. Claims about island internals
are design 12's and are attributed as such — **nothing here was verified against island
source by this tab**, and §5's `(user_id, token)` claim in particular is inherited from
`device_registrar.dart`'s own documentation rather than re-read from `moderation`/`push`
source. §4's gate table is enumerated from the `RingRefusal` enum's `startGate` flags, not
from the prose that describes them — the doc comment names five and the enum carries nine,
and the two the prose omits (`unverifiedOrigin`, `originMissing`) are the two §4 turns on.
