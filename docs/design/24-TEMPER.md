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
