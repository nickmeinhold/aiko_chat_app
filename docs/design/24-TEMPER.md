# TEMPER.md — design 24, "the answer fetches its own invite"

**Overall verdict: RECAST** (4/4 families seated, **4/4 RECAST, zero DISSOLVE**)
**Struck:** dt-1792454135, 2026-10-20, families seated: Maxwell + Noether + Carnot + Tesla (Wu disabled)
**Bundle:** design 24 + a code excerpt of `chat_repository.dart` (persist door, `_runReconnect`, delta loop) + app designs 23 and 20 + island `19-TEMPER.md` and `19-RECAST.md` (88KB).

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | Takes the socket off admission, then assumes admission was the only thing a call needed the socket for. |
| Noether (DeepSeek) | RECAST | Conserves the door's per-message contract and drops the per-caller disciplines (epoch fencing, the two-pass page order) that make the door safe to call. |
| Carnot (GPT) | RECAST | "Making another transport delivery impersonate an answer lookup": persistence is not delivery, and one fetch is not a recovery protocol. |
| Tesla (Grok) | RECAST | The newest page is not the invite; a page is a burst into `admitRing`; order is a second object; the trilemma horn was declined, not held. |

## Fatal flaws (deduped, most severe first)

**The convergence, stated first because three families reached it independently:** design 24 makes a REST page *impersonate a transport delivery* (persist each row and let `_announceInbound` tell `RingController`). The answer does not need a delivery. **It needs a lookup of ONE call** (`CallRef` = the answered `m`). Flaws 1-4 are that single wrong shape seen from four sides.

1. **Persistence is not delivery.** (Carnot) `_announceInbound` fires only on FIRST insert. If the invite is already cached (live fanout before the controller subscribed, an earlier fetch, a controller rebuilt over a surviving cache), the fetch inserts nothing and announces nothing, so a successful read still ends `neverAdmitted`. — **DISPOSITION: fold.** The answer path must look the invite up by `CallRef` in the cache, fetching only on a miss, and hand that one verified message to admission explicitly, not as an announce side effect.
2. **The newest page is not the invite.** (Tesla, Carnot, Noether) Fifty newer items, retractions or unknown events can push `m` off the page. `after` is exclusive, so `after: m` skips it, and the call ULID is not established as the row's server cursor. The client id and server ULID are different keys (`reference_reply_to_is_server_ulid_fk`). Calling a miss "safe" re-keys the defect. — **DISPOSITION: fold.** A bounded retrieval contract: page backward from the newest page until the `CallRef` is found, or the page's oldest item predates the wake by more than the freshness window, or the answer deadline passes.
3. **The history page contract is dropped.** (Noether, Carnot, Tesla) `_fetchDeltaHistory` applies all of a page's retractions BEFORE any message, in ascending order, so a crash between insert and retract cannot leave a ghost. A newest-page fetch persisted message by message re-opens that race, and newest-first order can announce an END before its invite. — **DISPOSITION: fold.** Any page applied must go through the existing page applicator (two-pass, ascending), never `_persistInbound` alone.
4. **A page is a burst into `admitRing`.** (Tesla) Other fresh invites on the fetched page get admitted with no `wakeAge` (`receivedAt = now`), so admission can pick a call the user did not answer. — **DISPOSITION: fold.** Admission on this path is filtered to the answered `CallRef` only; other rows persist as history and never reach the ring.
5. **No lifecycle owner.** (Noether, Carnot) The fetch has no epoch, no cancellation, and `_persistInbound` has no `_disposed` guard. A late response can write and announce after logout, a repo rebuild, an END, or the answer deadline. Borrowing the reconnect epoch defeats the purpose, because it cancels on socket loss. — **DISPOSITION: fold.** The answer hold owns the fetch: it is cancelled when the hold resolves or is released, on identity change and on dispose, and every write re-checks ownership after each await.
6. **One fetch is not recovery.** (Carnot, Tesla) The answer can precede session readiness or network return. A target-free response is not a terminal absence, and REST-down/socket-up becomes a new failure if the fetch is terminal. — **DISPOSITION: fold.** The fetch RACES live fanout (first verified arrival wins), retries until the answer deadline, and records `fetchFailed` as telemetry distinct from `neverAdmitted`, never as a terminal state.
7. **The 401/403 premise is unverified.** (Noether) The socket's wall was a 403 at the upgrade. §3 says REST renews on a 401. If the island's REST answers an expired token with 403, `AuthInterceptor` never renews and REST hits the same wall. — **VERIFIED 2026-10-20, resolved in the design's favour.** Both doors share one resolver (`auth_session.resolve_session_user`) and render it differently by design: REST (`aiko-chat-island/src/aiko_gateway/rest/deps.py:40-43`) gives an opaque **401** for any invalid or expired session and a structured 403 only for a ban, so `AuthInterceptor` renews. The WS handshake (`realtime/ws.py:32`) closes **403 for every** rejection, expired and banned alike, which is exactly why the socket could not tell "renew" from "stop". The REST premise holds. Keep a test that pins 401-on-expiry so a future island change cannot silently move it.
8. **The rest of the call is unpriced.** (Maxwell, Carnot) END, displacement, retraction, the media-token mint and cancellation may still ride the socket after a REST join. — **DISPOSITION: fold.** Add a table of every socket-borne call signal with its non-socket path, or keep the transport kick as a co-requirement and say the join is "fast but blind" until the socket returns.
9. **The scope claims exceed the evidence.** (Tesla, Carnot, Maxwell) The trilemma is NOT held: locked join still needs a sessioned round trip after Face ID. That is design 23's accepted product, a declined horn, not a held one, and design 20's urgency must not be laundered by it. iOS is unchanged. The urgency is borrowed from #395's review churn while #395 round 1 joined on hardware. — **DISPOSITION: fold.** Retract the trilemma claim; scope to Android warm sleep; state iOS is unchanged; state what measured failure survives #395 r1 plus "a fresh token retries now", or present this as defence in depth.

## What holds (4/4)

- The diagnosis: every path to admission passes through a socket connect (`_fetchDeltaHistory`'s only caller is `_runReconnect`), checked against the excerpt.
- The bookmark claim: `advanceHistoryContiguous` is called only by the delta loop, so an out-of-band read cannot paper over a gap.
- No wire change, the invite stays in-band (island 19-TEMPER flaw 2), and no participant set reaches a push payload.
- The direction: the answer should not depend on socket recovery.

## Disposition

**RECAST, round 1 of ≤3.** The recast is a change of object, not a patch list: **"the answer LOOKS UP its own invite"** — cache first, bounded backward fetch through the existing page applicator on a miss, admission filtered to the answered `CallRef`, owned by the answer hold, racing live fanout until the deadline. Verify flaw 7 against the island before writing it. Nothing built.

---

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The design takes the socket off the ADMISSION path and then quietly assumes that admission was the only thing a call needed the socket for.

**Fatal flaws:**
- **Unstated assumption — "admission is the socket's only job in a call" (§3).** Design 22 says the native answer door stays open "until the signed end arrives over the websocket", and the caller's hang-up, a second device's answer, and any in-call signalling all ride live fanout too. Design 24 joins a call over REST and leaves the socket dead: the user is now IN a call whose end, displacement and retraction signals cannot reach them. The design prices the join and never the 30 seconds or 30 minutes after it. Either enumerate every socket-borne call signal and show each one has a non-socket path, or state that REST-on-Answer must ALSO kick the transport and that the join is "fast but blind" until it connects.
- **Wrong option-frame — the urgency is borrowed from the review process, not from a measurement (§0).** The motivating evidence is that #395 hit the cage-match cap with a growing diff. But #395 round 1 JOINED on hardware 1.35 s after Answer, and round 3's one regression (a fresh token waits out the 30 s backoff) is a one-line policy: a new token is new information, so retry now. "Review churn" is evidence about the review's convergence, not that the transport cannot be the call path. The design must say what measured failure survives #395-round-1-plus-that-line, or present itself honestly as defence in depth with a lower priority.
- **Missing failure mode — the double fetch is not the only concurrency (§4.6 understates it).** On an answer that lands while `_runReconnect` is mid-run, the targeted fetch and the delta loop persist the same messages through the same door. The dedup transaction makes the WRITE idempotent, but `_announceInbound` fires on whichever insert wins — so `RingController` may admit from the targeted fetch while the reconnect's `_runEpoch` is about to abort and re-run. Fine for admission (idempotent), but the design asserts rather than shows that nothing else keys on "announced during reconnect".
- **Under-counted blast radius — iOS gains nothing and the design does not say so plainly (§2, design 23).** On a locked iPhone the fetch waits for Face ID exactly as today, and design 23 already admits by wake age. The #392 failure is Android-measured; the design should scope itself to "Android warm-sleep" and say iOS is unchanged, rather than leaving a reader to infer a cross-platform fix.

**What holds:**
- The core read: every path to admission today passes through a socket connect (`_runReconnect` is `_fetchDeltaHistory`'s only caller), and the code excerpt shows it.
- Reusing `_persistInbound` keeps verification, dedup and Door-A suppression in one door — no second admission path to drift.
- The bookmark claim is verified by the excerpt: `advanceHistoryContiguous` is called only by the delta loop.
- It reconciles with island design 19's temper (invite stays in-band) and does not pull the participant set into a push payload.

**If RECAST, what to fold back:**
- Add a section "what else a call needs the socket for": end, displacement, retraction, in-call frames. Each one needs a non-socket path, or the design keeps the transport kick as a co-requirement.
- Rewrite §0's motivation around a measured failure that survives #395 r1 + "fresh token retries now", or retitle as defence in depth and say so.
- Scope §3 to Android explicitly; state iOS is unchanged.
- Expand §4.6 into a short interleaving table (answer during reconnect / before / after).

John McClane: "Now I have a machine gun. Ho-ho-ho."


---

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The invariant at stake is *"every history write is fenced to a live epoch and applied as one causal batch"* — design 24 adds a third feeder into `_persistInbound` and conserves the door's *per-message* contract (announce-once, origin-once, suppression) while silently dropping the *per-caller* disciplines (epoch fencing, two-pass page ordering) that make the door safe to call.

**Fatal flaws:**

- **The tail read re-derives the same-page retraction race the two-pass was built to close (§3 Write; code excerpt `_fetchDeltaHistory`).** The design argues "every message goes through `_persistInbound`, the same door… keeps… Door-A retraction suppression." But Door-A suppression only knows about retractions **already persisted**. The excerpt is explicit: applying a message and its *same-page* retraction in item order "would durably insert the message, THEN delete it — a crash/error between those two commits leaves the retracted message durably visible," which is why `_fetchDeltaHistory` applies retractions in a first pass before any message upsert. The design's newest-page read is a **new page-application path**; `_persistInbound` is a one-message door and carries none of that ordering. A retracted call invite in the same page can be durably inserted and announced. Flaw class: **re-derived race / dropped causal-batch invariant.**

- **The tail read writes outside any epoch, and its write is not `_disposed`-guarded (§3 Trigger, §4 hazard 6).** Every other history writer is fenced: `_onMessage` returns on `_disposed` ("a torn-down repo must not write (rebuild overlap)"); `_fetchDeltaHistory` re-checks `_aborted(epoch)` "AFTER await, BEFORE write" and the whole `_runEpoch`/`_rerunRequested` machinery exists so a dead run cannot resurrect against a disconnected transport. The `answered`-triggered fetch has no epoch, no cancellation token, and no teardown guard on `upsertInbound` (only `_announceInbound` checks `_disposed`). Hazard 6 *names* this and then defers it to "needs reading, not assuming." A named-but-unresolved load-bearing hazard is a design defect, not a note. Flaw class: **broken fencing invariant / missing failure mode.**

- **The auth claim contradicts the measured defect (§0 vs §3).** §0 records the socket failure as "an expired token, **and 403s until restart**." §3 justifies the REST path as "renews an expired token on a **401**… the step the socket kept getting wrong." If the server's rejection for this condition is a 403, `AuthInterceptor`'s 401-renewal never fires and the REST fetch hits the *same wall* the socket did. The design's central premise — "REST is the path the socket got wrong" — is asserted for a status code the design never shows the REST client handling. Flaw class: **unstated assumption / missing failure mode.**

- **The read strategy is unpinned, and the fallback conflates three outcomes (§4 hazards 2–3, §5 question 3).** "No `after` cursor → newest page" is the *backward* default (the excerpt warns `after=null` is backward; `_fetchDeltaHistory` deliberately passes `''` to page forward). A 50-message page miss resolves `neverAdmitted` — but under design 23 a *present-but-stale* invite is rescued by `wakeAge`, so a fetch miss and a genuinely stale invite now produce the same terminal state for two different causes. The design flags this (hazard 3 wants `fetchFailed`) and leaves it open. Flaw class: **under-specified failure mode / telemetry conflation.**

**What holds:**

- **The reframe is the ore.** "Every round asked how to make the socket recover better; none asked why the answer needs the socket" is correct: both feeds (`_persistInbound` from live fanout and from `_fetchDeltaHistory`) are gated on `_transport.subscribe`/`suback`. The self-correction of the earlier "the wake carries no invite" inference is exactly the discipline this class rewards.
- **Announce-once survives double arrival (hazard 1).** `inserted` is computed *inside* the cache transaction, so a socket/REST/retry collision on one ULID yields exactly one `_announceInbound`. This holds *provided* the transaction is the sole serialization point — which is the one thing hazard 6 leaves unverified, so it is a claim, not yet a proof.
- **The gap-fill bookmark is genuinely untouched.** `historyContiguousThrough` moves only via `advanceHistoryContiguous(channelId, fence)`; a non-advancing tail read cannot paper over a gap. Verified by reading, and correct.
- **Two-path agreement holds.** There is no second object; the REST response *is* the channel message, and the one door reconciles the feeds.
- **Sequencing is right.** Design 24 (no wire change, no crypto) can ship before design 20, and design 20's urgency does drop for the *socket-dependency* half while its *hostile-island* half remains untouched.

**If RECAST, what to fold back:**

- **Make the tail read a page application, not a loop of door calls.** Either extract a shared `_applyHistoryPage(items)` that runs the retraction-first two-pass and have *both* `_fetchDeltaHistory` and the tail read call it, or state explicitly that the tail read applies all retractions in the page before any message upsert. The door does not carry this; the caller must.
- **Fence the new writer.** Give the tail read an epoch/cancellation token and a `_disposed` (and teardown) guard before each `_persistInbound`/`upsertInbound`, and write the interleaving table against `_runReconnect` (does a disconnect abort the REST read? it must not write from a torn-down repo, even though REST is not the socket). Resolve hazard 6 in the design, do not defer it.
- **Establish the auth claim before relying on it.** State what status the server returns for an expired session on the REST path and that `AuthInterceptor` renews on *that* status — or name the 403 handling explicitly. §0's measured 403 and §3's assumed 401 must be reconciled.
- **Pin the read and split the telemetry.** Answer question 3 (the `after:` cursor strategy for "get exactly this call's invite") and make `fetchFailed`, `stale`, and `neverAdmitted` three distinguishable terminals, so a fetch miss is never reported as a dead invite.
- **Name the concurrency explicitly.** `_persistInbound` now has three concurrent feeders; state that announce-once rests on the transaction being the sole serialization point and promote hazard 1's "needs a test, not a belief" to a merge gate alongside the cage-match hazard 5 already demands.

---

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** The useful move is removing socket recovery from invite acquisition. Keep it. But a newest-page fetch through an insert-only announcement door is not yet a reliable answer protocol: finding the invite, delivering an already-cached invite, applying retractions, and owning work across session changes remain unspecified. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here the wasted work is making another transport delivery impersonate an answer lookup.

**Fatal flaws:**
- Persistence is not delivery to the answering consumer. `_announceInbound` fires only on first insertion. If reconnect or an earlier fetch inserts the invite before the current RingController subscribes, or a controller is rebuilt while the cache survives, the answer fetch finds an existing row and emits nothing. The bundle establishes transactional deduplication, not durable admission delivery. A successful REST read can therefore still end as `neverAdmitted`.
- The proposed write path omits history's causal batch contract. The excerpt deliberately applies every page retraction before inserting any message; `_persistInbound` alone does not provide that protection. A tail page containing an invite and its retraction can announce the invite before suppression is recorded. Cached END records also need reconciliation with the answering controller; 'admitRing runs unchanged' does not establish that they have reached it. Reading history requires applying history events, not merely persisting its messages.
- The lookup does not guarantee finding the requested call. Fifty newer history items can exclude the invite; retractions and unknown events consume slots too. Calling the resulting failure 'safe' confuses refusal safety with the availability defect this design exists to fix. The proposed `after: m` alternative is also unproven: the call ULID is not established as the history row's server cursor, and an exclusive cursor can omit the target. A bounded retrieval contract is missing.
- One fetch is not a recovery protocol. Answer can precede authenticated session readiness, network recovery, or visibility of the invite on the serving island. A successful empty or target-free response is distinct from a terminal absence. AuthInterceptor's renewal on HTTP 401 does not establish recovery from a locked keychain, missing restored credentials, or concurrent refresh ownership. Without a deadline-bounded retry and wake-up policy, the design recreates 'tried once and never retried' over REST.
- The new asynchronous work has no named lifecycle owner. Reconnect epochs deliberately cancel on socket disconnection, so borrowing that epoch defeats this proposal. Ignoring ownership permits a response from an old account or repository generation to persist or announce after logout, replacement, or teardown: `_persistInbound` itself has no disposal guard in the excerpt. Transactional deduplication resolves duplicate rows; it does not establish session authority or stop a late join after END or the answer deadline.
- The scope claims exceed the evidence. Design 23 explicitly accepts joining after Face ID, so this does not satisfy the original locked-phone-join trilemma; it changes that requirement. Likewise, invite retrieval independence does not prove that media-token acquisition, joining, or cancellation delivery are socket-independent. Downgrading all transport failures to chat latency requires tracing the remaining answer-to-join path.

**What holds:**
- The socket dependency is demonstrated: the existing REST history feed waits behind subscribe and its fences. Removing that dependency addresses a real failure boundary.
- Keeping the signed invite on the existing channel history bus preserves the federation route and avoids introducing another authoritative invite object.
- Leaving `historyContiguousThrough` exclusively owned by contiguous delta sync is correct. A tail observation proves no coverage of earlier history.
- Reusing origin verification and transactional retraction suppression is sound, provided complete history pages retain their existing application semantics.
- Design 20 addresses native verification against a hostile island. This fetch does not acquire that property or remove its justification.

**If RECAST, what to fold back:**
- Define one call-scoped `ensureInviteAvailable` operation owned by the pending answer. Read the verified cache first; fetch only when necessary. Give the answering consumer an explicit way to obtain an existing invite instead of requiring another insert announcement. Dijkstra: "Simplicity is prerequisite for reliability."
- Extract a shared history-page application operation: apply all retractions first, then verified messages; tolerate unknown items; advance no contiguous bookmark from this operation. Reconcile known END state before completing admission.
- Specify how retrieval reaches the exact signed CallRef: use documented existing pagination until found or a justified boundary is reached, within the answer deadline. If the existing API cannot provide sufficient retrieval, price that limitation explicitly rather than declaring the newest-page miss acceptable. Do not use a call ULID as a history cursor without a server contract.
- Coalesce duplicate triggers for the same account and call. Gate requests on usable authentication; retry transient failures and visibility misses within the existing join budget. Socket disconnection must not cancel this work. END, deadline, account change, and teardown must prevent its late completion from joining.
- Treat fetch failure as an attempt result until the answer terminates; another path may still succeed. Record the final reason separately from intermediate errors.
- Verify the decisive interleavings: cached invite with a rebuilt consumer; simultaneous socket and REST delivery; invite plus same-page retraction; target beyond the first page; answer before authentication or visibility; END during verification; logout during fetch. Trace token mint and media join before declaring the socket absent from the call's critical path. These are the entropy-producing boundaries; adding timers without ownership only increases it.


---

I'll load the design-temper skill, then strike the design from the bundle you gave.## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The decision hums true — the answer must fetch its own invite — but the Read is a 50-string harp tuned to the wrong note, and at one future input the whole plate goes to glass.

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Fatal flaws:**
- **The newest page is not the invite (Design 24 §3 Read, hazard 2, Q3).** You measured a 30 s hold that resolved `neverAdmitted` with the invite already in the world, then defined the miss of a 50-row tail as “safe” because it is the same `neverAdmitted`. That is not a bound. That is the defect, re-keyed. Three seconds to unlock, thirty to wait, fifty messages to bury `m` — 3, 30, 50. The third number is not of the triad; it is the overtone that shatters the glass. A busy DM, a gathering you have not shipped, a bot, a federation burst inside the ring window, and the page is a window that does not contain the object you rang for. Q3 already hears this and leaves it as a question. A critical path is not a question. `after` is exclusive in the excerpt you cited (`_fetchDeltaHistory` progress guard). `after: m` skips the invite. “No after cursor” is not a retrieval of `m`; it is a hope that `m` is still famous.
- **A page is a burst, and the burst feeds `admitRing` (Design 24 §3 Write; Design 23 wakeAge; Design 20 §0).** Write says every row goes through `_persistInbound` and is announced “exactly as live fanout does.” Live fanout is one object. A newest page is fifty, origin-verified, announced, offered to the ring. `wakeAge` is queried from the *verified body’s* `CallRef`. A different fresh invite on that page — same channel, spoofed wake `c`, group, previous ringing ULID — admits with `receivedAt = now` because native has no wake for *that* id. You did not price joining the wrong room from the channel you fetched because you answered a ring. Hostile-island / hostile-wake was Design 20’s remaining job; this path hands it a new wire into the cache without the seal. Blast radius: cache, ring, media mint, every other `_inboundMessages` consumer, fifty crypto verifies on the 30 s join clock.
- **Order is a second object (Design 24 §3; island 19-TEMPER flaw 2 silent-desync; excerpt two-pass).** You closed “two paths, one object” and left *order* unnamed. Reconnect persists ASC, retractions first, because a crash between insert and retract leaves a ghost (Carnot HIGH, already in the excerpt). A “newest page” is born backward. Persist newest-first and an END that landed during the fetch is announced before the invite; Design 23 then refuses an owed end *before age*, and the user who just answered joins nothing. Caller hangs up while REST is in flight — 3am, one channel, two items, one wrong sequence. The third writer (this fetch) has no epoch, no two-pass, no `HistoryItem` union. Hazard 6 asked about `_runReconnect`’s abort. It did not ask whether you are a second history applicator wearing a one-line GET.
- **“Does not wait for the socket” is specified as a read, not as a race (Design 24 §3, hazard 3, §3 “What it does to PR #395”).** Today the socket *is* the fallback. After this, REST-down / socket-up is a new call failure unless live fanout may still win inside the 30 s latch. Hazard 3 collapses that into “network genuinely dead.” A 500, a timeout equal to the join deadline, a page of fifty verifies that finishes after `kInAppRingDuration` — those are not a dead radio. If `fetchFailed` is terminal, you cut the live path you left running. If it is telemetry, say so, and make the fetch *race* the socket, first `inserted` wins. Unstated, this is a coupling you will re-discover as “the answer fetches, therefore the answer waits.”
- **The trilemma is not held; a horn was declined (Design 24 §3 “Why this sits well”; 19-TEMPER flaw 2; Design 20).** Stateless island, sealed `{c,k,m}`, locked join after Face ID + REST is Design 23’s already-accepted product, and it is a good product. It is not “all three.” The trilemma’s locked-phone horn was *join with the bytes already on the device*. You still need a sessioned round-trip after the user’s own auth. Say that. Otherwise Design 20’s urgency is laundered (“ship this first”) while the hostile-island wake remains untouched, and Q4 answers itself in the wrong direction.

**What holds:**
- The question is the ore. Three cage-match rounds grew a transport diff because they could not see a door in another file. *Why does a dead socket mean a failed answer?* It must not.
- One persist door, origin verify once, `inserted`-once announce, watermark untouched — the excerpt backs that `_persistInbound` does not advance `historyContiguousThrough`. A targeted read cannot paper a gap. Keep that.
- No wire change *is available* if you retrieve with APIs the island already serves; federation stays on the history bus; Design 20 remains the seal, this remains the fetch-after-auth. Complementary is the right geometry.
- Trigger on native `answered` matches the measured Pixel: user did answer, unlock was 3 s, the wait was 30 s for a socket that never came. Fetch-on-answer is enough for that frequency. Wake-fetch is a different product (pre-answer admission, token mint for a ring that may be declined) and must not hide under “optionally.”

**If RECAST, what to fold back:**
- **Change the Read from “newest page, no cursor” to “retrieve the wake’s `m`, inclusive.”** Persist that history item (and any same-response retraction) through `_persistInbound`. If the island has no get-by-id, page *backward* until `m` or a stated bound, exclusive-`after` named as a foot-gun. Hazard 2 becomes a hard miss with telemetry, not a shrug that rhymes with the bug.
- **Name the race:** answer-fetch ∥ live fanout ∥ reconnect delta; first `inserted` wins; `fetchFailed` is non-terminal telemetry; the 30 s latch still releases `neverAdmitted` only if no path admitted. Do not await the page on the join clock without a timeout *inside* the latch.
- **If the response is a page, it is `_fetchDeltaHistory`’s page: two-pass, retractions first, apply ASC.** No third history applicator. Name the owner (`ChatRepository`, not the navigator stuffing REST bytes).
- **Q1 decide:** fetch-on-answer only, for this design. Wake-fetch is a later design; it touches admission-before-consent and the media plane.
- **Q4 decide:** Design 20 still exists for a hostile island ringing CallKit. This design does not drop that urgency; it drops the socket from join.
- **State the independence invariant and test it:** REST 401 → `AuthInterceptor` refresh succeeds when the socket’s refresh is the #395 corpse. If they share a try-once `TokenProvider`, this design does not move the call off the corpse.
- **Correct the trilemma sentence:** we declined “bytes on device at wake”; we kept island stateless and the envelope sealed; locked join waits on the user’s session, as Design 23.


---
---

# ROUND 2 — design 24 v2, "the answer looks up its own invite"

**Overall verdict: RECAST** (4/4 seated, **4/4 RECAST, zero DISSOLVE**), round 2 of ≤3
**Struck:** dt-1792455092, 2026-10-20 · Bundle: v2 + this TEMPER (round 1) + code excerpt (`chat_repository.dart`, `ring_controller.dart`) + app designs 23 and 20 + island `19-TEMPER.md` (106KB).

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | An unexamined simpler alternative (forward sync with a REST bound); double consideration; the cache-hit verification field unnamed. |
| Noether (DeepSeek) | RECAST | "A fetched page is inert" is false: the filter sits on the wrong side of the announce door; one answer becomes two admissions. |
| Carnot (GPT) | RECAST | A cache hit proves presence, not completeness; the applicator still announces unrelated invites; ownership never reaches the write. |
| Tesla (Grok) | RECAST | "The siren is still wired": a redial's older invite announces first and takes the chair; the age cutoff fuses the clocks design 23 split. |

## Fatal flaws (deduped, most severe first)

**The convergence (4/4).** v2 changed the *admission* object to a lookup but kept *writing* through `_persistInbound`, whose contract is to announce every first insert to `RingController`, which admits any admissible invite. So:

1. **Fetched pages still ring** (Noether, Carnot, Tesla, Maxwell). Another fresh invite on a page (a redial, a second call) is announced and can be admitted, or displace the answered call; ascending application announces the older invite first. Round 1's flaw 4 was folded as a sentence, not a mechanism.
2. **One answer, two admissions** (Noether, Maxwell). The miss path admits through the announce AND through `considerAnswered`; dedup is on the write, not on admission.
3. **Write ownership never reaches the write** (Noether, Carnot, Tesla). `_persistInbound` awaits `verifyOrigin` and writes with no hold predicate. Two applicators share no fence, so the per-page retraction-first guarantee breaks across writers. Extracting "the applicator" is not one object either: its progress guard requires a strictly increasing `after`, which a `before` walk violates.

**→ The structural fold, which dissolves 1-3 rather than guarding them: THE LOOKUP READS; IT NEVER WRITES.** Fetched pages are examined in memory: apply that page's retractions in memory, find the message whose *verified* body names the answered `CallRef`, verify its origin with the same verifier, and hand exactly that one result to admission. Nothing is persisted, so nothing is announced, there is no second applicator, no ghost, and no write to fence. History gets the rows later through the ordinary reconnect sync, which already dedups them. (This also answers Maxwell's forward-sync alternative: that one must write, and writing is what keeps failing.)

4. **A cache hit is presence, not completeness** (Carnot, Tesla). The object is a PAIR (invite, END). A cached invite with no cached END may be a call the caller already ended while the socket was dead. **Fold:** the cache can short-circuit only the *invite*; the terminal state is always asked of the island (one newest-page read is enough for an END sent after the invite). A cache hit must check the row's stored verification verdict (`drift_cache.dart:695`), by name.
5. **Terminal state before admission** (Carnot). Returning both messages is not an ordering. **Fold:** the lookup resolves a call-level result (`ended` beats `invited`) and only then offers admission.
6. **`notFound` re-keys the defect, and the age cutoff fuses clock domains** (Noether, Carnot, Tesla). A 200 with no `m` (read-your-writes or federation lag) is not an absence. Stopping on "oldest item older than wake − window" compares a server ULID wall clock with a monotonic wake duration, before the page is scanned. **Fold:** scan each page fully before any stop test; stop on the SIGNED timestamp of scanned invites, not on cursor time; treat `notFound` as "hunt again" until the answer deadline; report `outOfBound` distinct from `absent`.
7. **The second-device gap is not bounded by this design** (Noether, Carnot, Tesla). "LiveKit occupancy shows it" has no reader; `displaced` waits for the socket. Blast radius: two open mics in one room. **Fold, choose one:** a named reader (on join, a REST occupancy/answered check that resolves `displaced`), or state it as a known gap gated on #395's kick, with a product owner, not the word "bounded".
8. **The owner dies with the repository** (Tesla). Design 23's pinned survival: a rebuild disposes the repository and the ring lives on. A lookup owned by a repository-scoped hold dies with it and nobody re-homes it. **Fold:** the lookup lives at the ring/answer layer (with `RingController` / the navigator's hold), not inside `ChatRepository`, which follows directly from "reads, never writes".
9. **The cache-hit verification field was unnamed** (Maxwell). Covered in 4.

## Disposition

**RECAST, round 2 of ≤3.** The two rounds converged on the same lesson from opposite ends: round 1 said *don't deliver, look up*; round 2 says *a lookup that writes is still a delivery*. v3's object: **a read-only, call-scoped lookup owned at the ring layer, returning one resolved call state (ended | invited(verified) | unknown) to admission.** One round remains under the cap.

---

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** v2 fixes v1's wrong object (lookup, not delivery), but builds a bespoke backward search without examining the alternative already sitting in the code: run the existing forward delta sync without waiting for the socket.

**Fatal flaws:**
- **Wrong option-frame: an unexamined simpler alternative (§3.3).** `_fetchDeltaHistory` already pages forward from the bookmark, in order, two-pass, and advances the bookmark correctly. It is gated on the socket only because its *upper bound* is the `suback` fence. Give it a REST-derived bound (the newest page's `next_after`) and history sync runs without a socket at all — for chat as well as calls. That dissolves the page budget, the clock-skew stop rule and the "bookmark must not move" carve-out, and gives one history applicator instead of a second caller of an extracted one. Its cost is real (a device offline for days pages forward through everything before reaching the invite, on the answer clock), and that may be why backward search wins. But v2 must weigh it, not omit it.
- **Missing failure mode: double consideration (§3.4).** Pages the lookup applies go through `_persistInbound`, so a first-time insert of the invite is ALSO announced through `inboundMessages` → `_consider`. Then `considerAnswered` runs `_consider` again on the same message. `CallInvite ==` compares `inviteId`, so the ring state may not churn, but `_arrivals` advances twice and refusal telemetry is emitted twice. That corrupts exactly the evidence #223 made readable. Either the lookup's writes must not announce, or `considerAnswered` must be a no-op for a `CallRef` already considered.
- **Unstated assumption: cached rows are as trustworthy as fresh ones (§3.2).** "Scanning recent rows for a verified invite" assumes the cache records the verification outcome per row. `upsertInbound` returns `newlyInvalid`, which suggests invalid rows are stored with a flag, but the design never names the column or shows a cache hit re-checks it. A cache hit must carry the same verified-origin guarantee `_persistInbound` enforced at insert, by a named field.

**What holds:**
- The change of object, from delivery to a lookup of one `CallRef`, answers temper flaws 1, 2 and 4 at the root rather than patching them.
- The race-not-fallback framing, the `answer.lookup` outcomes distinct from `neverAdmitted`, and the hold owning the lookup are the right shapes.
- §4's signals table is honest, including the second-device gap it does not fix, and it keeps the #395 kick as a co-requirement for a stated reason.
- §0 now states the urgency truthfully: defence in depth, after #395.

**If RECAST, what to fold back:**
- Add §3.3a: forward sync with a REST-derived upper bound vs targeted backward search. Price both on the answer clock (worst case: days offline). Choose with reasons.
- §3.4: name the dedup — the lookup's applied pages do not announce, or `considerAnswered` keys on `CallRef` and ignores a repeat.
- §3.2: name the cache field that records verification, and require a cache hit to check it.

T-800: "I'll be back."


---

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The invariant at stake is *"a fetched history page is inert — it is persisted, never rung"* (equivalently, *"exactly one admission per answered `CallRef`"*); design 24 routes the lookup's pages through `_persistInbound` — the door whose contract is *announce on every first insert* — so the fetched page is not inert, and the filter meant to keep it so (`considerAnswered`, §3.4) sits on the wrong side of the announce door.

**Fatal flaws:**

- **The fetched page rings, and §3.4's filter never reaches the path that rings it.** *Class: filter on the wrong side of the door / broken inertness invariant.* §3.3 applies each page "through `_persistInbound`." The code excerpt is explicit: `_persistInbound` calls `_announceInbound` on `inserted`, and `_announceInbound` → `_inboundMessages` → `RingController._consider` → `admitRing`. So the answered invite rings through the announce path, **and so does any other admissible fresh invite on the fetched page** — another call in the same channel, a DM, a group invite — because `_consider` admits *any* admissible invite and knows nothing of the answered `CallRef`. §3.4 and §5 assert "other rows on fetched pages persist as history and never ring" and "a page that contains other fresh invites | persisted as history only; never admitted." That is false by the mechanism the design chose. This is temper round 1's flaw 4 (*"a page is a burst into admitRing"*) re-derived one door deeper, not folded — the fold added `considerAnswered` without closing the announce path, which the design keeps live because the lookup *races* live fanout.

- **The answered `CallRef` is admitted twice on the miss path.** *Class: broken conservation (one answer → one admission).* On a miss the page applicator inserts the invite → `_announceInbound` → `_consider` → admitted. Then §3.4 hands the same found invite to `considerAnswered` → admitted again. §3.6's "the first arrival … wins; the other is a no-op through dedup" does not hold: dedup is on the *write* (`inserted`, computed inside the cache transaction), not on *admission*. Nothing in `_consider`/`_admit` dedups by `CallRef`. The symmetry "an answer is a single act" has a conserved quantity — exactly one admission — and the design has added a second feeder into admission without conserving it.

- **The hold's fence does not reach the writer.** *Class: broken fencing invariant / named-but-unmechanized.* §3.5 promises writes from a stood-down lookup are "dropped before they reach the cache" and "every await is followed by an ownership check." But the page applicator writes through `_persistInbound` → `_cache.upsertInbound`, which carries no ownership predicate, and the shared applicator is fenced by `_runEpoch` (delta loop), not by the hold. Either the extraction parameterizes the fence — the delta loop passes `_aborted(epoch)`, the lookup passes the hold predicate — which the design never says, or the lookup re-implements page application without the shared door and re-opens the same-page retraction ghost §3.3 exists to close. This is round 1's Noether flaw 2, claimed folded but left as an assertion.

- **The second-device gap is bounded by #395, not by this design.** *Class: over-claimed bound / missing failure mode.* §4 and §7 Q4 punt displacement to "the existing `displaced` outcome handles it when the socket returns" and "LiveKit occupancy shows it." Both rest on the socket returning — i.e. on #395, a *co-requirement*. In the exact case this design exists for (dead socket that does not recover), two devices sit in the call and nothing here resolves it: "shows it" is not "acts on it," and no LiveKit-occupancy handler is specified. Calling it "bounded" launders a co-requirement into a property of this document.

- **`notFound` re-keys the defect it was built to fix.** *Class: telemetry conflation / under-specified terminal.* §3.3's stop conditions (page budget 4×50, or "oldest item older than wake − (freshness window + skew)") can fire before the invite on a same-channel burst inside the window. The outcome is `notFound` → `neverAdmitted` — the *same terminal* as "the invite was never there." The user answered; the invite exists; the bounded search missed it. The bound is a judgment call, and §3.6's five-valued telemetry still cannot distinguish "out of bound" from "absent."

**What holds:**

- **The diagnosis is the ore.** Every path to admission waits on a socket connect (`_fetchDeltaHistory`'s only caller is `_runReconnect`, which runs on `connected` and needs the subacks) — verified against the excerpt. *Why does a dead socket mean a failed answer?* It must not.
- **The reframe is correct.** "One call, not a page" (`CallRef` = `c`+`m`) dissolves v1's *"persistence is not delivery"* hole: cache-first, then fetch, then hand *one* verified object to admission. The direction survives.
- **Cache-first is right** for the announce-once rule (§3.2): an already-cached invite fires no announce, so a cache read is the only way to reach it.
- **The bookmark is genuinely untouched.** `advanceHistoryContiguous` is called only by the delta loop; a non-advancing read cannot paper over a gap. Verified by the excerpt.
- **The auth split is verified** (REST 401-on-expiry vs WS 403-for-everything) and the design keeps the pin test.
- **The scope is honest now** — iOS unchanged, trilemma declined not held, defence-in-depth labelled. That is the correct posture.

**If RECAST, what to fold back:**

- **Make the fetched page inert by construction.** Give the extracted page applicator a suppression parameter: the delta loop keeps announce (history-via-stream must ring); the lookup's page application persists *without* announce, and `considerAnswered` is the *sole* admission for the answered `CallRef`. This closes both the burst and the double-admission in one move — the filter must live at the door, not beside it.
- **Conserve "exactly one admission."** If any announce can still fire for the answered `CallRef`, make `_admit` idempotent by `CallRef` (a `_live`/`_admitted` guard), and state it as the invariant, not as a dedup side effect.
- **Fence the writer explicitly.** The shared applicator takes a cancellation predicate; the delta loop passes `_aborted(epoch)`, the lookup passes the hold predicate; checked before every `_persistInbound`/`upsertInbound`. Resolve §3.5 in the design; do not defer it to code.
- **Name the second-device resolution or drop the word "bounded."** Specify the LiveKit-occupancy action (leave / notify) for the socket-dead window, or state plainly that a REST-joined call is blind to displacement until the socket returns and accept it as a named residual that does *not* stand without #395.
- **Split the telemetry terminal.** `notFound` (budget/window miss) must be distinguishable from "no such invite ever," so an out-of-bound search is never reported as a dead invite.

---

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** The change of object is right; the retrieval and side-effect contracts still contradict it. A cached invite is not complete call state, and the proposed history applicator still announces unrelated invites. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. The remaining entropy comes from coupling an answer lookup to general history ingestion.

**Fatal flaws:**
- §3.2: A cache hit proves presence, not completeness. Cache the invite, miss the caller's later END while the socket is dead, then Answer: the lookup skips history and admits from an incomplete snapshot. Native call_end is another delivery path, not proof that cancellation arrived. Define whether this is deliberately best-effort admission or require a current terminal-state check; 'cacheHit' cannot imply the call remains actionable.
- §3.3–3.4 contradict the supplied persist-door contract. Applying every page through _persistInbound calls _announceInbound for every first insertion; RingController subscribes directly to that stream. Filtering considerAnswered does not filter those announcements. An unrelated fresh invite on the page can still ring or displace the answered call. The claimed isolation requires an explicit change to publication semantics, not merely a new admission entry.
- §3.3 still has no complete retrieval contract. Put 201 newer visible events ahead of an admissible invite: four pages of fifty miss it. No traffic bound justifies the cap. The age cutoff also needs proof: history orders server cursor IDs, whereas admission judges the signed timestamp against native wake time. An old signed message arriving late can cross the proposed cutoff while the wanted invite remains on an older page. Neither ordering equivalence nor a conservative cutoff is established.
- §3.1 and §3.4 leave terminal-state reconciliation ambiguous. 'The CallRef is found' could mean an END is found before its invite; returning both messages does not specify processing all accepted ENDs before offering the invite. Running the existing _consider once per message in ascending order can publish an admission for the invite before processing its later END. A call-level result must resolve terminal evidence before emitting an admission, including on cache reads.
- §3.5 names the owner but does not establish write fencing through the shared applicator. The supplied _persistInbound awaits verifyOrigin and then writes without consulting the hold. Checking ownership after awaiting _persistInbound is too late: logout or displacement during verification can already have produced a cache write. The proposed guarantee requires ownership to reach the actual write boundary, with account-scoped cache authority; an outer-loop check is insufficient.
- §3.6 specifies retries for failed requests but leaves successful visibility misses unresolved. A target-free 200 response can precede federation visibility; exhausting a page budget can also leave the call unfound. If either stops REST acquisition while the socket remains dead, the original 'tried once' defect survives. Separately, §4 calls second-device arbitration 'bounded' without a time bound or an authoritative winner: observing LiveKit occupancy does not itself prevent or resolve concurrent answers.

**What holds:**
- Removing socket recovery from invite acquisition addresses a demonstrated dependency.
- Explicit delivery of an already-cached verified invite fixes the announce-once hole.
- Keeping the signed invite in-band preserves one authoritative artifact and the federation route.
- Leaving the contiguous history bookmark under delta-sync ownership avoids claiming coverage from a partial read.
- The revised Android scope, defence-in-depth priority, and separation from design 20 are honest and supported by the bundle.

**If RECAST, what to fold back:**
- Define a call-scoped lookup result containing verified invite evidence, terminal evidence, and explicit coverage limits. State what cache presence can establish and what requires a fresh read.
- Remove the accidental publication coupling. Prefer a lookup that returns verified call evidence without ingesting and announcing an entire page. If history persistence is retained, specify how lookup-origin ingestion avoids unrelated ring announcements while preserving later legitimate delivery.
- Replace the arbitrary page cap's implied completeness with an honest deadline-bounded search contract. Prove any age cutoff against actual ordering semantics. If exact retrieval requires an endpoint change, price that option against repeated general-history work; 'no wire change' is a constraint to evaluate, not an efficiency law.
- Reconcile accepted ENDs and retraction suppression before publishing the call-level admission. Specify behavior for END-only results and terminal evidence arriving during asynchronous admission.
- Carry cancellation and identity authority through verification to each cache mutation and admission publication. Describe the commit boundary explicitly.
- Retry successful visibility misses within the answer deadline, coalesce duplicate answer triggers, and distinguish search-budget exhaustion from authoritative absence in telemetry.
- Specify second-device winner enforcement, or explicitly accept concurrent answers as a residual product behavior without calling it bounded.
- Dijkstra: "Simplicity is prerequisite for reliability." Delete the page-to-ring coupling before adding more guards around it.


---

The brief is truncated. I'll read the offloaded remainder, then strike only that bundle.## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The lookup is the true note, and then you welded it to a persist door that sings — the future input that powders the plate is a second fresh invite on the same page, applied ascending, announced first.

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Fatal flaws:**
- **The siren is still wired (§3.3–§3.4, excerpt `_announceInbound` / `_persistInbound`).** `considerAnswered` is a filtered hand of one pair. The page applicator you extracted calls `_persistInbound`, and that door announces on every first insert — the #139 fix that made history ring on purpose. "Other rows persist as history and never ring" has no mechanism. At 3am the DM holds two fresh invites (double-tap, two ULIDs, user answered the second). Ascending application announces the older one first. `admitRing` seats the call that was not answered. The explicit hand arrives second and finds the chair taken. Hostile-island replay inside the 10 s freshness window rides the same wire. Flaw 4 of round 1 was folded as a sentence and left live in the door.
- **`notFound` is a terminal on a success, and the age stop fuses the clocks Design 23 split (§3.3 stop conditions, §3.6 outcomes).** Retries cover a failed request. A 200 whose page does not yet contain `m` — push ahead of read-your-writes, federation lag onto the island that actually serves history — is `notFound`, and nothing in §3.6 says that outcome hunts again. The socket is the corpse this design exists for, so the race cannot save you. The same paragraph stops the walk when the page's oldest item is "older than wake − (freshness + skew)". Wake is a monotonic duration (`wokeUptime`); the page item is a server ULID wall clock; admissibility is `receivedAt − signedAt`, computed later, at admit time. A quiet DM's newest page always has an old neighbour sitting under a brand-new invite. Evaluate the bound on the page before the scan, and you throw away the page that holds `m`. Client clock a few seconds ahead of the island, and you stop one page early on an invite Design 23 would still admit. This is the original `neverAdmitted`, re-keyed and retimed.
- **The object is a pair; the cache hit is a single bit (§3.1 vs §3.2).** The lookup owes the invite and any END naming `m`. A cache hit "costs no network", so an invite already cached (fanout before the controller subscribed — the round-1 case you correctly refused to trust to announce) never goes to the server to look for the END that landed after the row. You hand `admitRing` a live invite for a caller who already hung up. §4's FCM `call_end` is a second radio with its own delay, and Design 20 still has the end-sentinel as the island's unpaid first piece. The short-circuit is tuned to presence of the start. The call is the pair.
- **Two applicators, zero shared fence (§3.3, §3.5, §5 row 1, excerpt two-pass).** The two-pass is a caller convention over N transactions. It is safe when one epoch owns the page. Answer-during-`_runReconnect` is the row your table calls idempotent. Dedup is per message. The retraction race is per page, across writers: the delta loop's pass 2 can insert and announce before the lookup's pass 1 has recorded the same-page retraction. You also cannot extract "the applicator" as one object — its progress guard demands a strictly increasing exclusive `after`. A backward `before` walk that inherits that guard asserts and returns on the first page. And the hold stands down on repository dispose. Design 23's pinned survival is that a rebuild disposes the repo and the ring lives. The lookup dies with the old writer and nobody re-homes it onto the new one. Question 3 is that defect, left open. A named open question on the owner is an owner that does not exist yet.
- **§0's promise and §4's second device are out of phase (§0 "stops depending on the socket's lifecycle at all", §4, question 4).** After a REST mint the handset publishes media. The other device's answer is "socket only", with LiveKit occupancy said to "show" it. Showing is not a reader. `displaced` fires when the socket returns — the event this whole design treats as the one that may never come. The blast radius is two open mics in one room until morning. "Bounded" is the word that hides an unbound interval. Question 4 asks the temper to close a product decision the design already spent.

**What holds:**
- The change of object holds under load. One `CallRef`, cache before network, explicit admission, a race against live fanout, `fetchFailed` kept off the terminal enum. That is the ore round 1 heard, and v2 actually moved it.
- The bookmark stays the delta loop's. An out-of-band read must not advance `historyContiguousThrough`. Keep that sentence where it is.
- No wire change, invite stays on the history bus, 401-on-expiry is verified and pinned, scope is Android warm-sleep, iOS is honestly unchanged, the trilemma horn stays declined, Design 20 stays urgent, #395 stays first. The frame is finally the same size as the evidence.
- Trigger on native `answered` matches the measured Pixel: 3 s to unlock, 30 s of hold, a socket that never became the call.

**If RECAST, what to fold back:**
- **Split the lookup from the writer in §3.3.** The answer path reads pages in memory, verifies, applies the two-pass to the pair in memory, and calls `considerAnswered` with only that pair — END first, synchronously, before any media mint. It does not call `_persistInbound`. The delta loop remains the only applicator, the only announcer, the only bookmark writer. Round 1's "reuse the door" coupling is the coupling to remove.
- **Close the retrieval contract in §3.3 and §3.6.** `notFound` and a target-free 200 retry until the answer deadline, same as `fetchFailed`. Scan the page for the verified `CallRef` before any age stop. Drop the fused "wake minus window" cutoff; the deadline and the page budget are the bounds. A neighbour's age is not evidence about `m`.
- **Define a cache hit as the pair, in §3.2.** Invite present and end-state known (a cached END, or a server read that confirms none). A bare invite is a miss and still fetches, until the deadline.
- **Answer question 3 in §3.5.** Same-identity repository rebuild re-homes the lookup onto the new repo. Dispose of the old one drops its writes. Logout and identity change stand down for good. If any write remains, the ownership check happens before the call that announces.
- **Answer question 4 in §4 by naming a consumer.** An occupancy read that maps "someone else already answered" onto `displaced` without a socket, or media publish held until that check returns singleton. Delete "bounded" until that consumer exists. The transport kick stays a co-requirement for everything else that still rides it.
