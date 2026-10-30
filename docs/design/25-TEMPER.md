# TEMPER.md — Design 25: first contact asks native first

**Overall verdict:** RECAST, with the frame moved: **the fix belongs on the island.** One DISSOLVE (Tesla) and three RECASTs. A DISSOLVE needs two families to be decisive, but all four families put the same finding first.
**Struck:** dt-1793233191, 2026-10-29. Families seated: Maxwell, Carnot, Tesla, Noether (all four; Wu disabled).
**Bundle:** `25-first-contact-asks-native-first.md`, `23-the-session-survives-the-lock.md`, and app #443 cage-match ledgers rounds 1 and 2.

## Per-family verdicts
| Family | Verdict | One line |
|--------|---------|----------|
| Maxwell (Claude) | RECAST | `Woke` is treated as the only conduct voucher, merging conduct with actionability (`unknown` already proves the island pushed); no retirement condition; the `(channel, call)` matching invariant is unstated |
| Carnot (GPT) | RECAST | The island should **withhold** unauthorized invitations on every path, and then the app's lookup, timeout and native fallback are unnecessary; `Woke` from an old island isn't conduct; budget versus join deadline is undefined; re-entry checks are unstated |
| Tesla (Grok) | DISSOLVE | The ladder is a third mode of the same vibrating check. Stamp the verdict on the frame and admission stays synchronous. Two clocks are assigned to one re-entry; `Woke` is overloaded and its next writer becomes a bypass |
| Noether (DeepSeek) | RECAST | The island can withhold or stamp, so the app check guards a removable producer; old-island `Woke`; budget undefined. Its "`unknown` forever on a connected phone" flaw is **false**: see below |

## Fatal flaws (deduped, most severe first)
- **The fix is at the wrong layer.** Harm 1's producer is the island delivering a ringable call frame to a recipient its own `_spoken_here` has judged a stranger. The island already holds the verdict. Raised by all four.
  - DISPOSITION: **move the fix to the island**, and do not build design 25. The deciding fact, which no single seat stated: **withholding** the invitation protects every installed app at once, store 0.0.8 included, the moment the island deploys. Stamping it does not, because old apps ignore unknown fields. Any app-side fix (#443, design 25) reaches users only with a new app release, and aiko has no release route yet. The signed body cannot be rewritten in transit (signed at birth), so the island can only deliver or withhold.
  - The product question is Nick's: withholding means the recipient never sees a stranger's call attempt; they see the stranger's messages, and replying is the accept step.
- **Two clocks in one re-entry** (Tesla). Wake-instant freshness and arrival-instant freshness were both specified, and on a locked phone (push at +0.4 s, Dart at +13.7 s after Face ID) arrival would refuse what design 23 rescued.
  - DISPOSITION: moot if the frame moves. If the app path is ever built: the wake instant when one was recorded, otherwise arrival.
- **`Woke` merges conduct with actionability** (Maxwell, Tesla). `unknown` already proves a recorded wake, and the next writer of the wake record becomes a conduct bypass.
  - DISPOSITION: moot if the frame moves; it is the strongest argument against teaching `wakeAge` to vouch for conduct at all.
- **`Woke` from an island older than v0.11.1 is not conduct** (Carnot, Noether, Tesla).
  - DISPOSITION: moot if the frame moves. An island-side withhold protects exactly as far as islands deploy it.
- **Budget versus join deadline is undefined; re-entry checks are unstated** (Carnot, Noether).
  - DISPOSITION: moot if the frame moves. Design 23's existing contract (budget is the ring window from arrival; the navigator waits on an in-flight admission) would have been the answer.
- **Rejected (false premise):** Noether's "on a connected phone `wakeAge` returns `unknown` forever and starves the cache". The code shows otherwise. iOS `wakeAgeAnswer` returns `unknown` only when an entry for this exact `(channel, call)` exists with a recorded wake inside `liveCallTrustWindow`, and `notActionable` otherwise. Android `CallRing.wakeAge` never answers `unknown`.

## What holds
- The producer analysis of harm 2 was right: the cache-before-native ORDER produced both cage-match halves, and one admission future registered before any await is the true deletion of the expose/hide pair. That is the lesson to keep if the app ever needs this path.
- Consent remains the question for non-persons and conduct for persons. Design 23 requirement 2 and its two pinned tests need no amendment once the fix moves.
- Failing closed on absent evidence was the right direction throughout.

## Disposition
- **Do not build design 25. Do not merge app #443 as-is.** Recommend the island withholds a stranger's call invitation from fanout and history: a call sentinel in a DM is visible to recipient R only if R had posted there first. That closes harm 1 for every installed app on deploy.
- App #443 is then superseded. Its harm-2 lessons are recorded here. Its stranger tests would be the island's to write.
- ~~**Open question for Nick:** withhold the attempt entirely (recommended), or deliver it stamped as a non-ringing missed call.~~ **DECIDED (Nick, 2026-10-29 14:16): withhold, and keep the missed call.** The island holds a stranger's call invitation until it is too old to ring, judged on the caller's signed timestamp, then delivers it. Every app version already renders a call invitation as a centred "X started a call · 14:05" line (`chat_screen.dart`) and refuses to ring one past the freshness window. So it lands as a missed call everywhere, with no app release and no stamp.

<!-- Each section below was written when that family returned, before the others
     finished. Arrival order, NOT a ranking. Round 6 replaces this header with the
     synthesized verdict; if it never runs, what is here is still real. -->

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** Native-first with one budgeted admission future does dissolve both halves of the cage-match class, but the design still merges two facts the native answer carries separately, and it never states when it should retire.

**Producer first:** The recast's own check is `noPriorConduct`. Its harm is a stranger's call ringing an open app. Its producer, in this repo, is the admission path admitting a person on a frame the island delivers regardless of conduct. That cannot be removed here without the island's verdict. The doc names the cross-repo removal (the island stamps the verdict on the frame) and keeps the check, which is the right disposition. Harm 2 (a real call lost to the gate) is produced by the cache-before-native ORDER, and the recast removes that producer instead of guarding it: once native is asked first inside one budgeted future, neither the hold nor the early release is representable. Correct use of the lens.

**Fatal flaws:**
- **Conduct and actionability are conflated in one answer (unstated assumption).** The recast treats only `Woke` as the island's word. But iOS answers `unknown` exactly when "a wake for this call is recorded, but CallKit doesn't list it yet" (`AppDelegate.swift` `wakeAgeAnswer`: the entry for `(channel, call)` exists, and its `woke` instant is inside `liveCallTrustWindow`). A recorded wake means the island pushed this call, and the island pushes only after `_spoken_here` passes, so `unknown` already settles **conduct**. What it leaves open is **actionability**, which is design 23's question. As written, an `unknown` that persists to the end of the budget falls through to a cache read with roughly no budget left: it times out, logs `conduct_unreadable`, and refuses as `noPriorConduct`. A call the island vouched for is then reported as a stranger, and the log says the disk failed. Fold: any answer meaning "a wake for this call was recorded" (`Woke`, or `unknown` at any point in the loop) vouches conduct, and the cache is read only when native never recorded a wake.
- **No retirement condition (wrong frame for the long term).** The doc names the island stamp as the real removal of harm 1's app-side producer, then specifies machinery that will outlive it. Without a stated end state, the cache-plus-wake approximation becomes permanent by default, and its two failing-safe edges (retracted posts, still paging) become permanent too. Fold one line: when the island stamps its verdict on the frame, the app reads it first and the cache path survives only as the fallback for islands that don't stamp.
- **The matching invariant is load-bearing but unstated.** "A `Woke` is the island's word for this recipient here" holds only because native matches on BOTH channel and call. iOS keys `stored()[channel]` and checks `entry.call == call`; Android `CallRing.wakeAge` checks `callId == callId && channel == channel`. A future refactor that matched on the call id alone would let a wake for one DM vouch for a stranger's invite in another that reuses the id. Name it as an invariant, with both code references, so the next reader cannot loosen it unknowingly.

**What holds:**
- The producer analysis for harm 2 is right, and so is the fix's altitude. One future, registered synchronously, bounded by the one budget that already exists, asking native first. That removes the hold forever and the early release by construction, not by a timeout. And because a held answer implies native rang, a vouched call never touches the cache.
- The amendment to design 23 requirement 2 is honest. It keeps the requirement's reasoning ("a wake can only rescue what `now` refuses") and adds the second refusal that reasoning covers. Moving the "fresh invite never asks" tests to a consented agent keeps the property on the population it was actually about.
- Judging freshness from arrival applies design 23's principle (freshness bounds transit; what follows is the app's latency) to the open-app path. Checked: Android never answers `unknown` (only `woke` or `notActionable`), so native-first cannot spin the budget there.

**If RECAST, what to fold back:**
- Step 2: "a wake for this call was recorded (`Woke`, or `unknown` at any point in the loop) vouches conduct; the cache is read only if native never recorded one."
- A "Retirement" section: once the island stamps its per-recipient verdict on the call frame, the app trusts the stamp, and this cache-plus-wake path is the fallback for unstamped islands only.
- An "Invariant" line: native's wake match is on `(channel, call)`, with the iOS and Android references; loosening it to the call alone reopens the stranger hole.


## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** The ordering repair holds, but the design leaves the stranger-ring producer running and treats native lifecycle evidence as conduct authority. Dijkstra: "Simplicity is prerequisite for reliability." No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are.

**Producer first:** The harms are unwanted ringing and legitimate answered calls being lost. Public sign-up and incoming invitations are triggers. Our producers are the island forwarding invitations despite its conduct verdict, the app admitting those invitations, and asynchronous admission competing with answer teardown. The island already has the evidence needed to remove unauthorized delivery; a cross-repo boundary is an implementation cost, not a structural obstacle. Native-first ordering removes one unnecessary dependency, but completion and teardown still need one owner.

**Fatal flaws:**
- Make stranger ringing impossible: have the island withhold unauthorized call invitations on every delivery and retrieval path, using the recipient verdict it already computes; then the app's conduct lookup, its timeout, and its wake-as-conduct fallback become unnecessary. Merely stamping the verdict preserves machinery that authoritative routing can delete. Explain any path that actually requires delivering a refused invitation.
- Woke does not establish the asserted conduct invariant across supported deployments. The bundle explicitly permits older islands that wake anyone, yet admits their Woke without reading conduct. 'No worse than before' describes compatibility, not satisfaction of harm 1. Native actionability and recipient conduct are different facts; their accidental correlation cannot serve as an unqualified authorization contract.
- A bounded future does not establish compatibility with the navigator's existing join deadline. The bundle does not define the admission budget, its start, or its relationship to the answer deadline. A decision can finish within its own budget after the navigator has released the answer. The claim that native always returns Woke for an answered call also assumes away the documented unknown state and bridge failures.
- Re-entry is described only as carrying evidence, without explicitly preserving design 23's later checks of block, mute, consent, END, and arrival ordering. During the new native/cache wait, those facts can change. A valid conduct result cannot authorize publication after cancellation, disposal, or a newer competing invitation.

**What holds:**
- Asking native before cache removes cache availability from the successful Woke path. The held-forever cache test directly demonstrates that dependency removal.
- Registering one future before awaiting addresses the exposed-versus-hidden split. It reduces state entropy, provided all completion paths settle it.
- Measuring transit at arrival avoids charging lookup latency to the invitation. Preserve a separate current time for current policy and clock-skew checks.

**If RECAST, what to fold back:**
- Make island admission authoritative across websocket delivery, wake delivery, and subsequent fetch. Identify any indispensable client-side checks separately. If rollout requires this local mechanism temporarily, specify its supported server versions and retirement condition.
- If Woke remains conduct evidence during rollout, give that assertion explicit provenance tied to the verified call and recipient. Older unqualified wakes cannot satisfy the new conduct rule.
- Define one terminal admission lifecycle shared with answer teardown: an absolute deadline, typed completion outcome, and cancellation that prevents late publication. Bound the whole operation, including bridge faults and unknown retries.
- Pin re-entry semantics with tests: END/block changes during either await win; answer expiry prevents a late join; exhausted native retry leaves a defined cache outcome; duplicate invitations cannot replace an active decision or renew its deadline.


## Tesla, the Arc-Prophet's Design Strike

**Verdict:** DISSOLVE

**Summary:** The stranger-ring is produced by an invite that already left an island which already knows the verdict, and this native-then-cache ladder will shake apart on the same locked, just-answered handset design 23 measured — three clocks, one overloaded `Woke`, the budget eating the call it was meant to save.

**Producer first:** Harm 1 (a stranger's call rings an open app) is produced by the island, which gates only the wake and still fans the invite out to every connected recipient, and by `admitRing`, which admits any person once that frame is in hand. The island already computes the per-recipient verdict and can stamp it on the frame it fans out; that stamp makes the harm structurally impossible, after which `noPriorConduct`, the `hasPostedIn` read, and treating `Woke` as conduct are unnecessary. "Cross-repo, filed as a follow-up" is a schedule, and a schedule does not keep a producer alive. Harm 2 (an answered call held forever, released while still undecided, or refused `stale` because a lookup ran long) is produced by a second evidence read whose lifetime is outside the future `wakeAdmissionFor` waits on, and by charging that read to the invite's age. One future registered before any await, plus a timestamp taken at arrival or at the wake, removes those producers. The ladder puts a producer back: `wakeAge`'s retry-on-`unknown` and the cache share one budget and one "anything but `Woke`" fallback, so a call the system is already ringing can be refused when the observer is late and the cache is cold. The flood cost is produced here too: every fresh person invite on a phone is turned into a `wakeAge` round trip, including the open-app invites the island never woke.

**Fatal flaws:**
- Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration." The vibrating element is the check. Ledger round 1 exposed the lookup and held the answer forever; round 2 hid it and released the answer mid-decision; the stop signal fired because the fix was the next defect. Design 25 ("The recast", steps 2–3) builds a third mode of the same element — a client reconstructing a bit the island already computed ("The producer question, first"; "Residuals, named"). Stamp that verdict on the frame and admission stays the synchronous gate design 23 already runs. The ladder, the cache, and `Woke`-as-conduct drop out together.
- Steps 2 and 4 assign two clocks to one re-entry. Step 2: on `Woke`, judge freshness from the wake, as design 23 does. Step 4: the re-entry passes `receivedAt` as the instant Dart first judged the invitation. The locked-phone runs in design 23 are the collision — push at +0.35–0.98 s, Dart at +13.7 s after Face ID, `kCallInviteFreshness` at 10 s. If arrival wins, those answers are `stale` again and the session dies after the user has already answered. If the wake wins, step 4's desktop test is a different variable wearing the same name. One assignment will ship; one population rings itself to glass at 3am.
- `unknown` is a live answer, not a soft miss. Design 23's own residual: a fresh `CXCallObserver` may not list the ringing call at once, and every `wakeAge` is logged, `unknown` included. Design 25 spends "the existing retry-on-`unknown` loop and its existing budget," then treats anything other than `Woke` as a cache read ("The recast", step 3), and a timeout as `conduct_unreadable` / not found. The killed-app answer is exactly where the cache is cold and the observer is late. The budget then either refuses the vouched call, or it is still running when design 23's 30 s join deadline (`kInAppRingDuration`, armed at Answer) releases it `neverAdmitted`. "The cache is never read" holds only for the happy `Woke` the hardware has not promised.
- The open app is the common path and the empty oracle. The island does not wake a connected recipient, yet a phone with a bridge asks `wakeAge` for every fresh person invite ("Visible consequence"). The answer is defined to be other than `Woke`, and only then is the cache read. A wedged or busy channel — the same channel a stranger flood now occupies, one budget-bounded call per distinct call id ("Residuals, named", Load) — fail-closes the friend who is already on screen. The 30 s join deadline is how that queue arcs to ground: the real ring waits behind N trips that exist because this design called native for invites native never rang.
- `Woke` is overloaded, and the name will be reused. In design 23 it is an actionable age on a monotonic clock, trusted only while CallKit or `CallRing` still holds that call, written once by the wake handler. In the amended requirement 2 it is also the island's conduct voucher. Design 23 already had to forbid Dart-initiated reports from stamping `wokeUptime`. The next writer of that field — an in-app report, a second push type, the hardware ringer — becomes a conduct bypass with no new check. An island older than v0.11.1 is that bypass today; "no worse than before #443" keeps harm 1 for every handset that island still wakes. [app #443](https://github.com/nickmeinhold/aiko_chat_app/pull/443).

**What holds:**
- One admission future, placed in the map `wakeAdmissionFor` already reads, before any await, is the real deletion of the expose/hide pair. Ledger rounds 1 and 2 are the two halves of a future that was half-registered. That shape survives.
- Freshness bounds transit. Design 23's principle — Face ID, restore, and a lookup are the app's time — is sound, and design 23's later correction (skew judged at `now`, tolerance 5 s; transit from the receipt) must stay untouched.
- A consented agent's fresh invite never asks native. Consent is the question for that population; conduct is the question for a person. The two design-23 tests belong on the agent.
- Absent evidence refusing the ring is the safe direction when the alternative is a stranger's call. A missing repository reported as unreadable, in the round-1 ledger, is the same instinct.
- Design 23's query-at-admission, the per-call `CallRef` from the verified body, END-before-age, and "a locked keychain read is never flattened to absent" are carrying real load and are independent of this ladder.

**If RECAST, what to fold back:**
- Replace design 25 rather than tuning it. The frame carries the island's per-recipient conduct verdict; `admitRing` reads that bit synchronously; `wakeAge` remains design 23's clock and is asked only to rescue `stale`. `noPriorConduct`, the native-then-cache ladder, and the amendment that teaches `wakeAge` to vouch for conduct come out of `DESIGN.md`. Until the stamp is on the wire, a person invite with no verdict fails closed in the client that knows the field, and an old frame keeps today's behavior under an explicit version rule — a wake record from an older island is an age, and it is never a witness.


## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The design assumes a native wake exists for every person's DM invitation on a phone; on the connected path the island gates the wake but delivers the invite, so the native-first retry consumes the shared budget and refuses real calls.

**Producer first:** The `noPriorConduct` check guards harm 1: a stranger's call rings a person's open app. The producer is the island's delivery rule: it delivers the call frame to a connected recipient regardless of the recipient's conduct ("IT GATES THE WAKE, NEVER THE INVITE"). That producer can be removed: the island already computes the per-recipient verdict, so it can withhold the call frame from a connected recipient who has no prior conduct, or stamp the verdict on the frame. Then the app-side `noPriorConduct` check and this entire recast become unnecessary. For harm 2, the producer is the app's order of evidence gathering; the recast changes the order, but native-first when no native wake exists creates a new producer: the retry-on-unknown loop starves the cache and refuses the call.

**Fatal flaws:**
- **Wrong layer / guard for a removable producer:** The design builds a complex app-side recast for `noPriorConduct`, but the producer of harm 1 is the island's delivery to connected recipients. The island can be made unable to produce the harm by not delivering the frame (or stamping the verdict). The design acknowledges this as a follow-up, but the app-side check is then a guard for a producer that should be deleted. This is the first defect: make harm 1 impossible at the island; then the check is unnecessary.
- **Broken invariant: every phone invitation has a native wake.** The recast's "Native first" assumes that if a bridge exists, `wakeAge` will eventually answer for this call. But when the recipient is connected, the island does not wake the handset; it only delivers the call frame over the live socket. `wakeAge` returns `unknown` forever. The retry-on-unknown loop consumes the shared budget, leaving zero for `hasPostedIn`; the cache read times out, logs `conduct_unreadable`, and the call is refused. This loses real calls from people who have posted—the exact harm 2 the recast claims to remove. (Class: missing failure mode / wrong invariant.)
- **Unverified trust in `Woke` from old islands.** The residual admits a `Woke` from an island older than v0.11.1 "vouches for nobody," yet the design still admits on it. On any un-upgraded island, a stranger's call rings the open app. The fix is ineffective exactly where the island gate is absent. (Class: trust boundary / broken invariant.)
- **Undefined shared budget.** The design asserts "one budget bounds the whole decision" but never pins its value or the allocation between the native retry loop and the cache read. Without that, the tests cannot be guaranteed, and the retry loop can starve the cache. (Class: missing parameter / unstated assumption.)

**What holds:**
- The single admission future registered synchronously before any await removes the early-release and hold-forever races for the native path.
- Native-first for a sleeping handset with a valid `Woke` correctly avoids the cache and judges freshness from the wake, as design 23 does.
- Bounding the whole decision and judging freshness from arrival for the cache path removes the aging problem for that path.
- Amending design 23's requirement 2 to let a wake rescue `noPriorConduct` as well as `stale` is logically consistent.

**If RECAST, what to fold back:**
- **Delete the app-side check if possible:** Make the island withhold the call frame from a connected recipient who has no prior conduct, or stamp the per-recipient verdict on the frame. Then remove `noPriorConduct` and this recast entirely.
- **If the app-side guard must remain temporarily:** Condition the native-first step on the invitation having arrived via a native wake (e.g., the app was woken by push). For invitations received over the live websocket while connected, skip native and go straight to `hasPostedIn` with the full budget.
- **Define the budget:** Pin a total budget and a short native `wakeAge` timeout. If native returns `unknown` after the timeout, fall back to the cache with the remaining budget. Never let the native retry consume the cache's entire budget.
- **Version-gate `Woke`:** Only trust `Woke` if the island is known to be v0.11.1 or later; otherwise ignore it and fall back to the cache.
- **Add the missing test:** A connected phone (app open, no native wake) with a person's invitation whose recipient has posted must ring. The current tests do not cover this path.
