# TEMPER.md — design 20 §10 (the key is announced; consent stays on the device)

**Overall verdict:** RECAST (4/4 families, none DISSOLVE)
**Struck:** dt-1792883913, 2026-10-25. Families seated: Maxwell + Noether + Carnot + Tesla (Wu disabled). All four seated; no dark seat.
**Also read:** the island tab's answer on gate 7 (PR #403 issuecomment-6390837964), which arrived during the strike and agrees with the panel.

## Per-family verdicts
| Family | Verdict | One line |
|--------|---------|----------|
| Maxwell (Claude) | RECAST | The carrier is the wrong frame; "refuse after wake, as today" ignores iOS must-report. |
| Noether (DeepSeek) | RECAST | §10 hands itself gate 7; rotation has no ordering rule; native can't read the Dart stores it says it consults. |
| Carnot (GPT) | RECAST | Write the admission outcomes before the transport; tier 3 is an attacker-controlled downgrade. |
| Tesla (Grok) | RECAST | The sleep check sits on the far side of the wake: a trilemma §10 must pick a branch of. |

## Fatal flaws (deduped, most severe first)

1. **The allowlist is consulted after the wake, and iOS forbids a silent refusal.** Raised by all four, plus the island. A VoIP push must be reported to CallKit (measured, #4278: four consecutive unreported pushes terminate the app). So refusing on the device costs either a CallKit flash or the app's VoIP delivery. Tesla's trilemma: (a) the island learns who may ring (§9's corpse), (b) the device may discard a push unreported (only under an entitlement; the NSE path was measured closed), or (c) every peer who passes the island's gates can wake the handset, and the allowlist only chooses what the ring says. §10 builds (c) while describing (a)'s promise. This hazard is not new: consent is already device-local. But §10 said "as today" without checking. **DISPOSITION: blocking product decision for Nick** (which branch), then fold into §10.
2. **The per-DM post self-satisfies gate 7, the only filter that stops the wake.** Raised by all four, plus the island. **DISPOSITION: fold.** The statement leaves the DM (see 3), and the pin rule ties key use to real speech, so "has spoken" and "can be sealed to" coincide, as the island asked, with no island change.
3. **The carrier is the wrong socket.** Raised by Noether, Carnot and Tesla (IdentityDoc); Maxwell and the island suggested piggybacking on the first real message. **DISPOSITION: fold, synthesising both.** K lives in one account-level statement in ADR-0009's IdentityDoc socket (`verificationMethod[]`), signed by the signing key under its own tag. A caller uses K **only for a peer whose signing key it already pinned from a real, human-sent message**. That rule gives the island's alignment (key use requires speech, and so does gate 7) and Tesla's "human on the pin", and needs no posts, no notifications and no gate change. The fetch happens when a DM opens, never at ring time, so its timing reveals nothing the island doesn't already see from message reads.
4. **Rotation doesn't converge, and a stale statement can be replayed.** Raised by Noether, Carnot and Tesla. **DISPOSITION: fold.** One document per account, with a monotone epoch, a successor signed by the current key, and the pin surfacing the change (#236). A superseded statement is rejected. The bytes go to the specialist (queue item 1).
5. **Native has no readable source of truth.** Raised by Noether, Carnot and Tesla. The pin, the device's private K and consent live in Dart stores (SharedPreferences, flutter_secure_storage), but the decision has to happen before Dart runs. **DISPOSITION: fold.** §10 names one native-readable admission view (active account, per-conversation consent, pins, private K), with defined update ordering for revocation, sign-out and account switching. It withdraws "`ring_allowlist_store.dart`, unchanged".
6. **The tier-3 fallback is a downgrade a hostile island controls.** Raised by Carnot and Tesla. Dropping the statement steers the caller onto an unverified ring the island fully controls. **DISPOSITION: tied to 1 (Nick).** Whether "no pin" still rings at tier 3 is the same product decision.
7. **Groups are the store's motivating case and they're left out.** Raised by Noether and Tesla. **DISPOSITION: fold.** An account-level K covers channels for free (the pin is per account). Whether channel rings seal is then a question about the wake gate, not about key distribution.

## What holds
- Separating the key from consent: no grant or withdrawal record reaches the island. All four families and the island agree.
- Refusing to seal the certificate (it's circular).
- Two keys, a certificate of use, and the specialist's ownership of formats (#316). §10.2's inner tag, with the signer structure in the tag.
- The allowlist's doctrine (device-local, per conversation, keyed on the multikey). The break is *when* it runs, not how it is stored.

## Disposition
RECAST round 1 of ≤3. Folded 2, 3, 4, 5 and 7 into §10 v3.1. **1 and 6 decided by Nick, 2026-10-25:** (c) chosen by name; no key, no system ring (caller requests no wake without K; an unsealed push is always report-then-end). Re-strike (round 2) before any build.

---

<!-- Per-family strikes below, in ARRIVAL order (Maxwell, Noether, Carnot, Tesla), as each landed. -->


## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** §10 correctly cuts the consent-carries-key tie, but it then smuggles in two unexamined premises: that the statement must travel as its own DM post, and that a device-local refusal after an iOS VoIP wake is free ("as today").

`John McClane: "Welcome to the party, pal."` The author wrote this section ninety minutes ago, and it reads like it.

**Fatal flaws:**
- **The carrier is the wrong option-frame (wrong frame / simpler alternative).** §10.0 step 1 posts a separate key statement into *every* DM. But the statement is **self-certifying**: its Ed25519 signature over K is the binding, and the peer already TOFU-pins that signing key in the DM. So the carrier adds no trust. It only adds cost: N posts per account, each one a new-message push to the peer, an unread bump and a reordered DM list, a re-post in every DM on every rotation, and dormant DMs revived by a message nobody wrote. **Piggybacking** the statement on the account's next ordinary signed message in that DM, as a field inside the signed envelope under its own inner tag, delivers the same pin with zero extra posts and zero notifications.
- **Wake gate 7 is a symptom of that frame, not a separate open question (coupling to remove, not guard).** §10.4.2 asks the island to *exclude* key statements from "has spoken". That's a guard bolted on to undo the frame's side effect, and it would force the island to recognise key statements, which its own Q2 answer forbade. With piggybacking, only accounts that actually spoke carry a statement, so gate 7 keeps its meaning and the island learns nothing new. The coupling dissolves.
- **"Not allowed: no ring, as today" ignores iOS must-report (unstated assumption, missing failure mode).** Step 4 refuses *after* the handset has been woken by a PushKit VoIP push. Measured (#4178, #4278): four consecutive unreported VoIP pushes get the app terminated, and only a report (including report-then-end) resets the counter. So a DM peer the callee has NOT allowed can repeatedly force either a CallKit flash (report-then-end) or termination. §10.3 prices refusal as "the same refusal as today, one layer later", but "one layer later" is exactly the layer where refusal isn't free. The hazard may well pre-exist §10 (consent is already device-local, and the island can't gate on it), but §10 asserts it as solved without checking.
- **The first-arrival window is unpriced (degenerate state).** An account on 0.0.8 or older never announces. A peer who hasn't spoken since updating has no pinned K, and the caller falls back to tier 3. Failing safe is right, but §10 should say that **tier 3 remains the steady state for a long tail**: pinning only happens when someone speaks, so adoption is gated by conversation activity, not by updates.

**What holds:**
- Separating key distribution from consent is the right move. It removes the consent signal instead of hiding it, and a withdrawal sends nothing.
- Refusing to seal the certificate (it's circular: sealing needs the very key being delivered) is correct.
- The island's Q2/Q3 answers are folded in correctly (inner tag; signer structure in the tag).
- The design fails safe on every drop: no K means tier 3.

**If RECAST, what to fold back:**
- §10.0 step 1: change "a key statement into every DM" to "the key statement **rides inside the account's next signed message in each DM** (and after a rotation), under its own inner tag". Delete the standalone post.
- §10.4.2: replace the gate-7 question with "dissolved by piggybacking: only accounts that spoke carry the statement".
- Add §10.4.5, **must-report**: a refused ring arrives as a VoIP push that iOS requires to be reported. Choose and name the cost: report-then-end (a brief CallKit flash) or an island-side ceiling. Cite #4278. And check whether today's path already has this problem, because "as today" must be verified, not assumed.
- §10.3: name the long tail of tier 3 explicitly.


## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The invariant at stake is *wake eligibility is earned by speaking* — §4's "the conduct gate keeps its job, no property traded" — and §10 spends it, because §10's own announcement traffic is the thing gate 7 reads.

**Fatal flaws:**

- **§10 self-satisfies the gate it claims not to touch (broken invariant: "has spoken" holds on every path — §10 makes it hold on every path *by construction*).** §4 and §8.4 preserve gate 7 as the one pre-device filter only the island can produce. §10.0.1 requires every account to post a key statement into **every** DM. The island read states the consequence plainly: posting into a DM makes the poster "have spoken" (`push_service.py:41-44`). So after §10, gate 7 is true for every DM pair, and the filter degrades to "is in a DM with you" — which is exactly what the island already routes. §10.1 then says "the ring's wake path is unchanged, and that is §8's business, not this section's" — **false: §10 changes §8's input.** §10.4.2 files this as a coupling question ("does that coupling not matter?"). Wrong frame. It is not a coupling; it is the design handing itself the gate. And §10.1 counts the cost on the *island* ("it learns only B's key is K") when the cost lands on the *handset*: every DM peer can now wake every handset at will, with refusal happening device-local, post-wake. That is an unbounded attention/battery surface and the design does not name a rate limit.

- **Rotation vs. TOFU pin has no ordering rule (broken invariant: "one statement per DM per key" assumes first-write-wins on a channel the island orders).** §10.0.1 says the statement is "re-sent when the key rotates"; §10.0.2 pins TOFU; ADR-0009 ref. 4 makes rotation the *only* recovery from a lost device (one key, copied, no per-device revocation). §10 never says what a receiver does with a *second* statement for a signer it already pinned. Both branches are broken and neither is specified: **accept** → the island stores DM bodies in plaintext and controls delivery, so it can replay any superseded statement — still validly signed, indistinguishable from a legitimate re-send — and roll a peer back to a dead K; **reject** → rotation silently breaks the seal for every peer, and the ring falls to tier 3 for everyone with no signal. The design's own #236 continuity surface makes the first branch worse: a rotation *is* a key change the pin exists to surface. This is the replay surface the cryptographer's queue names for the envelope (item 3) and §10 never names for the statement.

- **§10 step 4 crosses the native/Dart boundary §0 exists to respect (unstated assumption: the pre-Dart push handler can read Dart-owned state).** §0's whole premise is that Swift must report to CallKit *before the delivery handler returns*, which is why arm C puts the open in the native path. §10.0.4 then says the handset "opens the envelope natively, verifies the inner signature against the pinned signing key, and only then consults its **device-local ring consent** (`ring_allowlist_store.dart`, **unchanged**)." But the pin is established in Dart (from a DM statement), the consent store is `SharedPreferences`-backed Dart keyed `aiko_ring_consent_<userId>`, and the private K lives in `flutter_secure_storage`. Native can consult none of these without a second reader — a coupling to *remove*, not guard — or without Dart running first, which §0 forbids. "Unchanged" is false, and this is the same class of failure §0 already recorded once: §1's admission architecture had no input. §10 has re-created it one layer down.

- **§10.3 and §10.4.2 are mutually inconsistent, and the fix re-introduces the reading the design forbids.** §10.3 says the island "shape-checks nothing new (its Q2: no). The key statement is just a signed DM." §10.4.2's proposed remedy — exclude key statements from "has spoken" — *requires* the island to recognize and classify key statements, i.e. to parse DM bodies for a specific statement type. You cannot answer "shape-check nothing" and "exclude from gate 7" simultaneously. One of them must be chosen and its cost written down.

- **Scope under-counted: DM-only where the consent model was built for channels.** §10.4.3: "Groups: §10 is DM-only, as §9 was." The allowlist header states the per-conversation scope exists *because* "a resident agent may hold membership in many channels" — the case that motivated the whole consent shape is exactly the case the sealed ring does not cover. Named, not costed.

**What holds:**

- **The reframe is correct and dissolves §9.** Cutting the tie between handing out K and consenting means consent never touches the wire; a plaintext-DM island learns nothing about it, and "withdraw by doing nothing" is sound. §9 was genuinely broken by the island read and §10 genuinely fixes the leak it names.
- **K is public, so announcing it costs no secrecy, and the island can drop but not forge** (no signing key). Drop fails safe to tier 3. §10.1 is right about the island's *knowledge*.
- **§10.2's two rules are right** — own inner tag signed separately from the carrying DM, and the signer structure in the tag rather than the signature count. That matches `aikochat:msg:v1` / `react:v1` and gives ADR-0009's link and this statement one layout.
- **§8's conditions survive**: shape-check belongs on the sealed push envelope, not the statement; the size budget belongs in the contract; the crypto waits for the specialist. §10.3's "no shape check on the statement" is right for the reason given.
- **The tier-1 rejection stands** (no unverified native name cache).

**If RECAST, what to fold back:**

- **Drop per-DM distribution.** Announce the X25519 key **once per account** on the surface ADR-0009 already fixes for the link (`/v1/keys` / `IdentityDoc`), signed under its own domain tag. It meets the same bar the per-DM statement meets — the signing key signs the key, which is the TOFU binding — delivers the same K to the same peers, and touches gate 7 not at all. If per-conversation pinning is still wanted, pin `(signing key, K)` from the fetched statement at first DM use rather than from a per-DM post. This removes flaw 1 entirely and reduces flaw 4 to moot.
- **Specify the second statement.** A rotation must be an ordered, signed successor (epoch/version, monotone), the pin must surface the change per #236 rather than accept silently, and a superseded statement must be *rejected*, not replayed. Without this, "re-sent when the key rotates" is a replay oracle with the island holding the pen.
- **State where the native path gets its inputs.** Either mirror the pin, the device K, and the consent list into a store the push handler owns — and withdraw the "unchanged" claim on `ring_allowlist_store.dart` — or re-scope the pre-CallKit decision to what native can actually decide before Dart runs. Do not leave "natively" and "unchanged Dart store" in the same sentence.
- **Answer §10.4.2 in the design, not as a question to the island.** Either exclude key statements from "has spoken" and pay for it (the island must recognize them, contradicting §10.3), or restate gate 7's meaning and name and bound the wake surface it now leaves open (per-peer budget, island rate limit).
- **Count the group case.** Either state that channels fall back to tier 3 and accept that the consent model's motivating case is unsealed, or extend the announcement to channel membership.

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** Separating consent from key publication is sound. §10 still spends ordinary-message side effects to distribute account metadata, leaves native admission undefined, and calls an unauthenticated fallback safe. Dijkstra: "Simplicity is prerequisite for reliability." No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are.

**Fatal flaws:**
- The transport defeats a security gate. §10.4.2 acknowledges that automatic announcements make every DM participant 'have spoken', satisfying wake gate 7 without human participation. This is a prerequisite to resolve, not a question to leave open. Excluding statements requires the island to recognise a control-message class, contradicting the claim that these are ordinary DMs requiring no new handling.
- The rejection path contradicts the supplied platform constraint. §10.0.4 promises 'not allowed: no ring', while §0 requires reporting a VoIP push to CallKit before returning. A hostile island can send refused or malformed envelopes regardless of the conduct gate. The architecture must explain how rejection preserves platform compliance and future push delivery; cryptographic correctness does not answer that.
- The fallback is an attacker-controlled downgrade. §10.1 says dropping a statement produces tier 3 and 'fails safe'. If tier 3 rings without authenticated local authorisation, suppression bypasses the protection. If it preserves that authorisation, the document must explain what evidence makes that possible when the statement or envelope is absent. A generic caller label establishes neither safety nor consent.
- The native decision has no defined source of truth. The supplied consent store is Dart SharedPreferences, scoped per user and conversation; §10 requires Swift to consult consent, pins, private keys and a verified name before Dart runs. No architecture establishes their availability while locked, account isolation, or what happens after revocation, logout, interrupted updates or missing state. A signature also does not authenticate an island-supplied display name.
- Key publication lacks lifecycle semantics. 'One statement per DM per key' specifies sending, not convergence: offline peers, restored devices, new conversations and suppressed updates remain unresolved. A valid old statement remains signed after rotation. ADR-0009 makes lost-device recovery an account-wide rotation, so acceptance of stale state can preserve the compromised device's reach. These are product trust-state decisions that must precede the specialist's format work.

**What holds:**
- Publishing independently of consent removes the explicit grant and withdrawal records that broke §9. Keeping consent device-local preserves its per-user, per-conversation attention model.
- A signing-key attestation can authenticate an encryption key relative to an already trusted signing key. It does not independently establish the person's identity; §10 correctly retains TOFU as an unresolved assumption.
- Separate signing and encryption keys follow the external review. Envelope shape and size constraints remain useful, and construction details belong with the cryptographer.

**If RECAST, what to fold back:**
- Replace mandatory ordinary-DM announcements with an account-scoped signed key object, carried independently of consent and conversation activity. Evaluate the existing IdentityDoc/key-serving seam as an opaque carrier: recipients verify against their established signing-key pin, rather than trusting the island's roster. This removes repeated per-DM publication and its 'has spoken' coupling.
- Write the admission outcomes before choosing the transport: authenticated and allowed, authenticated and refused, missing key, stale key, malformed envelope and missing native state. For each, specify both attention behaviour and compliance with the platform requirement. Do not label tier 3 safe until it satisfies those rules.
- Define one authoritative native-readable admission view containing the active account, conversation-scoped consent, established identity pins and trusted presentation data. Specify update ordering and failure behaviour, especially immediate revocation and account switching.
- Define key scope, continuity, rotation acceptance and recovery across the copied-key devices. Distinguish an unavailable update from permission to accept an older key; delegate the cryptographic expression of those decisions to the specialist.
- Make preservation of gate 7 and native rejection feasibility blocking acceptance conditions. The entropy here comes from coupling key discovery to chat activity; remove that coupling before adding guards around it.


## Tesla, the Arc-Prophet's Design Strike

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Verdict:** RECAST

**Summary:** §10 correctly cuts consent free from the key, then nails the key back onto a DM message, so at 3am the automatic utterance rings the sleeper the allowlist was built to protect, and the one account-key splits into as many pins as there are rooms.

**Fatal flaws:**

- **The sleep-check sits on the far side of the wake (§10.0.4, §10.3, §10.4.2, against §0 and §2).** PushKit has already woken the locked handset before the allowlist is consulted. iOS demands a CallKit report before the handler returns; a quiet refusal is how a device loses VoIP delivery. §10.3 calls a sealed ring from any DM peer "the same refusal as today, one layer later." The layer later is the glass. Today `ring_allowlist_store` is explicit that "may this agent wake me at 3am" is attention, a property of the sleeper. After §10 the sleeper is already awake, and consent only chooses the costume. The announcement makes it structural: a key statement is a post, a post satisfies gate 7 (`push_service.py:41-44`, named in §10.4.2 and left open), and every account posts into every DM. "Has spoken" becomes true for every participant the moment the feature ships. Excluding this one statement from gate 7 damps one harmonic. Unread, notification, last-spoke, the Carried Record, and the next conduct predicate keyed on "a message exists" all still hear it. §2 dismissed the notification-service-extension entitlement because the island can tell a call from a message. It cannot tell a wanted call from an unwanted one. That second predicate is the one §10 just moved entirely onto the device, which has no legal way to swallow a VoIP push.

- **One key, N messages, no single pitch (§10.0.1, §10.4, ADR-0009 ref. 4).** ADR-0009 fixed the account as one Ed25519 and one X25519, copied onto every device, with a lost phone revoked only by rotating that pair. §10 distributes the pair as one independent DM post per room, re-sent on rotation, droppable per post, with the pin taken per conversation. A lossy island turns one rotation into a chord: some peers seal to K, some to K′, and the lost phone still holds K and can announce it again, signed by the same key the legitimate phone is signing with. Nothing in the protocol converges. There is no ack, no single document, no moment the old K dies everywhere. Seals to the stale pin wake the stolen handset and never reach the new one. The user hears "I rotated." The pins did not.

- **The announcement is the wrong socket, and it is §9's shape with the consent bit scraped off (§10.0, §10.3; ADR-0009 ref. 2).** The island read killed "ordinary signed message" as a carrier of consent. §10 kept the ordinary signed message and changed the payload. ADR-0009, accepted the day before, already cut the socket: `IdentityDoc.verificationMethod[]` is a set, and a key vouching for its sibling is the same shape as the link. A DM-per-room bus is a second home for a statement that already has one. It is also why sealing "cannot" be the distribution path in the §10 preamble: that paradox is real only if the certificate has to ride to the peer inside a message the peer must read before any key exists. An account document signed by the signing key the peer already pinned from real speech does not need that loop.

- **Consent's own motivating case is left outside the ring (§10.4.3, against the allowlist header).** The store was recut per conversation because a resident agent sits in many channels, and a blessing anywhere must not wake you everywhere. §10 announces only into DMs, and parks groups in one line. The agent in the channel never receives K, never gets a sealed invite, and falls through to tier 3 (`"Aiko"`) forever. The architecture covers the easy pair and misses the sleeper the data model was rewritten around. Widening the same "post a statement into every conversation" fix to channels multiplies flaw 1 by the agent's membership set.

- **A dropped announcement is labeled fail-safe and behaves as a downgrade (§10.1, inheriting §9.1's tier-3 fallback, against §4's hostile-island claim).** The threat §0 and §4 still name, once the conduct gate exists, is a hostile island. That island holds no signing key, so it cannot forge a statement. It can drop one. §10.1 says the drop degrades to tier 3 and fails safe. Tier 3 still rings, under a name the island chose, on a path that never needed K. Selective drop is how the island steers a caller off the sealed path and back onto the wake it fully controls. Silence would fail safe. An unverified ring is the original instrument.

- **The verified name is pinned on a message no person sent (§10.0.2, §10.4.1).** §9's TOFU at least rode a human grant. §10 pins `(signing key, K)` on an automatic first post, which is the cheapest moment for the first-contact substitution §9.4.1 already confessed. The handset then reports a verified caller to CallKit. The badge claims a human checked the key. The human was asleep to the pin. Queue item 4 asks whether TOFU is enough binding. The architectural answer is already no, for this particular utterance: a pin established before any real speech is an island-chosen key with a hymn under it.

**What holds:**

- Cutting the tie. Consent is the sensitive act; K is not. Sending the certificate *because* of consent is what told a plaintext island who allowed whom (§9, broken correctly by the island read). Withdrawal as a local edit, with nothing on the wire, keeps the island from learning who withdrew. That part is true and should survive.
- Decision 6 as a property of Apple, the reader. A sealed invite on the VoIP path still teaches Apple an opaque blob plus `c`. The island read agrees that room is for the push envelope.
- The allowlist's own doctrine: device-local, per conversation, keyed on the signing multikey, never on a display name the island can relabel. §10 leaves `ring_allowlist_store.dart` unchanged. Keep that. The break is when the check runs, not how the set is stored.
- Two keys, a certificate of use, and the specialist's ownership of formats. #316 stands. §10.2's demand that the key statement carry its own inner tag, and that signer structure live in the tag, is an architectural constraint the island earned. Leave the bytes to the queue.
- §8.1 and §8.2 still belong to the sealed push envelope alone. The island's refusal to shape-check the key statement (its Q2) is right for any object whose recognition would become a social signal. It is not a reason to keep the statement disguised as a chat message.

**If RECAST, what to fold back:**

- **Replace §10.0's per-DM announcement with one account-level statement in the IdentityDoc socket ADR-0009 already opened.** The account's Ed25519 signs "this X25519 is my ring-sealing key" once. Peers who have already pinned that signing key from real messages accept K from that document. No post into the DM, so gate 7, unread state, notifications, and the transcript stay still. One document rotates atomically; a successor is signed by the current key; peers have a single pin per account, shared by every DM and every channel. The lost phone can shout in old rooms and not fork the pin. State explicitly that K in the IdentityDoc is public account material, same class as the signing key, and that this is the roster option §4a already named, with the binding the 2026-09-15 review demanded supplied by the signing key the peer already trusts from speech.
- **Write the trilemma into §10 in one paragraph, and pick a branch.** Either the island learns who may ring (rejected, that is §9's corpse), or the device can discard a push without a CallKit report (that reopens §2's entitlement, because "is this a call" is no longer the predicate), or every conduct-legal peer can wake the handset and the allowlist is only a display filter. The third is what §10 currently builds while describing the first's promise. If the third is honestly chosen, change the allowlist header's "wake me at 3am" sentence so it stops claiming a property the push has already spent. If sleep still matters, the refuse path has to be off the VoIP wire or under an entitlement that may swallow.
- **Match scope to the store.** Say in §10 that channel and agent rings use the same account K, or say ring-sealing is DM-only and channel consent is outside this design. Parking "groups" as §10.4.3 leaves the original sleeper on tier 3.
- **Rename the drop.** In §10.1, a missing or suppressed statement means the caller has no K and must not fall through to a tier-3 ring that the hostile island can emit on its own. No pin, no verified wake. Tier 3, if it still exists, is a separate product decision with the hostile island assumed to be holding the microphone.
- **Put the human back on the pin.** A verified CallKit name requires a signing key pinned from a message a person actually sent or from a later QR check (§9.4.1). The automatic key statement, wherever it lives, does not by itself mint the badge.
