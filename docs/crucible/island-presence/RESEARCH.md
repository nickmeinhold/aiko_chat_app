# Heat — island presence: what the field already knows

> Movement 2 artifact. Deep research against the Ore pick, 2026-09-04.
> Method: primary sources wherever reachable (RFCs, vendor specs, issue threads via the
> GitHub API, spec text). Every claim is tagged **VERIFIED** (a primary source was read),
> **INFERRED** (secondary or synthesised), or **NOT FOUND** (searched, nothing citable).
>
> **Structural note for the forge:** §1–§4 are CONSTRAINTS and OTHERS' FAILURE MODES —
> they feed the next movement. §5 is THE SOLUTION SPACE (how prior art actually solved it)
> and is **deliberately withheld from Spark**. §6 is the adversarial steelman. Read §1–§4
> and §6 before Spark; hold §5 until Cast.

---

## 0. The five findings that most change the design

1. **Matrix's presence problem is a *large-room federation* problem, not a presence
   problem — and a Synapse maintainer says so in the negative.** On the issue asking
   matrix.org to re-enable presence, `anoadragon453` writes: *"we do run the feature for
   another homeserver with around ~100 users internally with no issues."* The cost driver
   named repeatedly in the threads is membership of huge public rooms (Matrix HQ), not user
   count. **An island of a handful of people is on the far side of the cliff Matrix fell
   off.** The famous "presence is too expensive" lesson does not transfer to this design
   as-is, and treating it as a constraint here would be importing someone else's cliff.

2. **A naive lease/heartbeat design costs MORE at rest than the event model costs at peak.**
   My own fanout arithmetic (§4.2): relaying every renewal makes cost a function of the
   *clock*, not of *behaviour* — a silent island with 50 idle members generates more traffic
   than a busy one under event-driven presence. The lease is the right fix for ghosts and
   the wrong thing to put on the wire. **Renewals must terminate at the island; only derived
   state crosses to other clients.** This is the sharpest engineering constraint found.

3. **The privacy property the Ore doc is excited about does not come from the signature.**
   "You cannot be shown present unless you said so" is delivered in full by *client-originated*
   presence — Discord already ships exactly this, unsigned, and gets invisible mode for free.
   The twist bundles two separable ideas (client-originated presence: cheap and genuinely
   valuable; cryptographic self-attestation: expensive and marginal *at one island*) and
   credits the privacy win to the wrong half. This is §6's main blade and the design must
   answer it explicitly.

4. **The clock question has a known, boring, universally-converged answer, and it is not
   clock synchronisation.** Five independent systems (SPIFFE, CA/Browser Forum, AWS
   presigned URLs, Kubernetes bound tokens, SSH certs) all solve "the issuer picks its own
   expiry" the same way: the **verifier clamps to `min(claimed_exp, verifier's absolute
   ceiling)`**, regardless of what the assertion says. A signed "aboard until T" needs no
   skew protocol — it needs a hardcoded island-side and client-side maximum lifetime.

5. **There is one strong MEASURED privacy source and it says users actively fight presence.**
   Cobb, Simko, Kohno & Hiniker, CHI 2020, n=200: **43% had changed settings or behaviour
   specifically to avoid being seen by one particular person**; >50% had logged in purely to
   check someone else's status; 28% gave up trying to find the privacy settings. This is the
   evidence base for the disclosure argument — and note it cuts *for* the design's
   client-originated half, not for its cryptographic half.

**Looked for and could not find:** an official Signal statement explaining why it ships no
presence (§3.2 — the "Signal chose this for privacy" claim is received wisdom with no
traceable origin); a citable source for the folkloric "presence was X% of XMPP traffic"
statistic (§2.1); any measured study of consumer-device clock skew (§4.4); any isolated
measurement of presence-heartbeat battery cost as distinct from other background traffic
(§3.4); any protocol that signs a short-lived *liveness* assertion (as opposed to a
*status* one — §5.5 — the twist appears to be genuinely unbuilt prior art).

---

# PART I — CONSTRAINTS AND OTHERS' FAILURE MODES

*(feeds the next movement)*

## 1. Matrix — the most important single case

### 1.1 What actually happened

Presence is specified in Matrix and disabled nearly everywhere. Synapse's config carries
this comment **(VERIFIED**, `docs/other/running_synapse_on_single_board_computers.md`):

```yaml
# Disable presence tracking, which is currently fairly resource intensive
# More info: https://github.com/matrix-org/synapse/issues/9478
use_presence: false
```

The same document calls presence *"the main reason people have a poor matrix experience on
resource constrained homeservers"* and locates the cause precisely: Synapse has performance
bugs, *but the fundamental problem is that "federation makes it combinatorial"* — cheap for
a centralised service, combinatorial once distributed across servers.
Source: https://matrix-org.github.io/synapse/latest/other/running_synapse_on_single_board_computers.html

The meta-issue #9478 (**VERIFIED** via GitHub API) opens: *"Traditionally this feature has
been turned off in all major deployments due to its enormous performance costs."*
Source: https://github.com/matrix-org/synapse/issues/9478

### 1.2 The mechanism, from the spec

**VERIFIED** (Matrix client-server spec, presence module):

- Three states: `online`, `unavailable` ("not reachable at this time e.g. they are idle"),
  `offline`.
- The fanout rule, verbatim: **"Presence events are sent to interested parties where users
  share a room membership."** Rooms with a `public` join rule allow federation-wide access.
- Server-side idle inference: *"The server will automatically set a user's presence to
  `unavailable` if their last active time was over a threshold value (e.g. 5 minutes)."*
- `currently_active` exists purely as a **damping mechanism** — when true, the server stops
  sending `last_active_ago` updates until the state changes. Matrix had to invent a
  suppression flag inside the data model because the naive version emitted too much.

Source: https://spec.matrix.org/latest/client-server-api/#presence

**The load-bearing observation:** the cost rule is *"everyone you share a room with"*. Join
one 30,000-member public room and your every idle-timer tick fans out to 30,000 people
across hundreds of servers. That is the combinatorial explosion — **it is driven by
membership of large rooms, not by the number of users on your server.**

### 1.3 The field reports (VERIFIED via GitHub API)

Issue #3971 "Presence is increasingly heavy" — the reporter:

> *"It seems like sending out presence updates whenever my presence changes, would cause
> 100% CPU usage for a while on my small VPS... If I just keep alternating between
> backgrounding and foregrounding the riot-ios app, I can effectively keep my homeserver at
> 100% CPU."*

Note the trigger: **mobile app backgrounding/foregrounding**. Each transition is a
`PUT /presence/{userId}/status`, each one fans out. Mobile lifecycle is a presence-event
*generator*, and it is adversarial by accident.

Same thread, `MurzNN` reporting a slow-building failure:

> *"after enabling presence - first day all works well, but after one-two days - load is
> slowly increased, and after 4-5 days - Synapse becomes very slow!"*

and the workaround he asks for, which is the whole diagnosis in one line:

> *"maybe make presence quering rules as per-room basis? For ability to disable presence
> querying events in large rooms like Matrix HQ, Riot-*, etc. This will be much better,
> than globally disabling presence!"*

Another user, `lpulley`: *"I want presence on my homeservers and on my friends' but I don't
want it at all on the big matrix.org rooms."*

Source: https://github.com/matrix-org/synapse/issues/3971

### 1.4 The finding that most changes our design

Issue #10808 asks matrix.org to turn presence back on. Synapse maintainer
`anoadragon453` replies (**VERIFIED**):

> *"There's still some outstanding performance work for presence which we'd like to see
> finished before enabling the feature of matrix.org. ... That being said, **we do run the
> feature for another homeserver with around ~100 users internally with no issues.**"*

Source: https://github.com/matrix-org/synapse/issues/10808

**This is the single most design-relevant sentence in the entire research pass.** Matrix
presence works fine at ~100 users on one server. It falls over on federated fanout into
enormous public rooms. An aiko island is the former case, not the latter. The correct
lesson to import is **not** "presence is expensive, be afraid" — it is **"presence cost is
a function of the size of the audience you fan out to, so bound that audience by
construction and you are on the safe side of the cliff."**

Corollary constraint: the cliff arrives with **cross-island federation**, not with member
growth. Whatever is built should have federation's fanout question answered before it
crosses islands, not before it ships.

### 1.5 Current state of the art (2026) — Matrix is redesigning presence right now

**VERIFIED.** A community initiative, "Presence v2", is actively reworking this. From
*This Week in Matrix*, 2026-06-26:

> *"Presence is notoriously one of the more expensive features in Matrix. Most large public
> deployments disable federated presence, commonly citing performance concerns. **Current
> Matrix presence is fundamentally flawed: users receive presence information for all users
> they share rooms with, even if they are uninterested.**"*

The first proposal, **MSC4495: Selective Presence**, aims *"to reduce federation load by
only sharing presence with interested users, alongside giving room administrators an option
to suggest whether presence should be shared between members or not. This provides both
substantial performance **and** privacy improvements."*

Status (TWIM 2026-08-28): experimental unmerged implementation in Continuwuity, 3 servers
running it. Companion proposals in flight: MSC4532 (Revised Social Presence, adds a `busy`
status), a sliding-sync extension sending presence only for actively-viewed users, and an
exploratory "fetchable presence" (pull on demand rather than continuous broadcast).

The project's status site states the problem with a number (**VERIFIED**, verbatim):

> *"The root problem is architectural. Today, Matrix servers distribute presence to anyone
> who shares a room with a user, even if the two users have never interacted. **Small
> servers regularly send updates upwards of 100,000 times an hour.** This expense results in
> server operators disabling presence entirely, which in turn results in a poor user
> experience for the large public servers where it matters most."*

Sources: https://matrix.org/blog/2026/06/26/this-week-in-matrix-2026-06-26/ ·
https://matrix.org/blog/2026/08/28/this-week-in-matrix-2026-08-28/ ·
https://ispresencefixedyet.com/

**Constraint for us:** performance and privacy are the *same fix*. Every serious presence
redesign in the field narrows the audience, and narrowing the audience is simultaneously
the load fix and the disclosure fix. A design that treats them as two features is paying
twice for one mechanism.

---

## 2. XMPP — the original fanout

### 2.1 The multiplication (VERIFIED, RFC 6121)

The model: `<presence/>` with optional `<show/>` (exactly four values: `away`, `chat`,
`dnd`, `xa`), free-text `<status/>`, and integer `<priority/>` in [-128, 127]. Availability
itself is binary; everything else is annotation.

Subscription is roster-coupled: states `none` / `to` / `from` / `both`, established by the
`subscribe` → `subscribed` handshake. On presence change the server **MUST broadcast** from
the user's full JID to all entities subscribed to the bare JID — **and delivery is to each
of the recipient's connected resources individually**, not once per account.

So a single status change costs approximately **R × S × M** stanzas (my resources ×
subscribers × their resources). At 3 devices each and 40 contacts that is ~360 stanzas for
one idle-timer tick. Source: https://xmpp.org/rfcs/rfc6121.html

**Caveat on instrument:** the RFC section text was read through a summarising fetch, not
byte-for-byte by me. The *substance* (MUST-level broadcast, per-resource delivery) is
corroborated independently by the Facebook and Slack sources below; the exact section
numbers should be re-checked before being quoted verbatim anywhere binding.

### 2.2 "Presence dominates traffic" — chased to ground

The widely-repeated claim that presence was the majority of Google Talk's or WhatsApp's
XMPP traffic: **NOT FOUND.** Multiple search framings returned no primary engineering source
for any specific percentage. Treat the statistic as folklore.

What *is* verified, and is stronger for our purposes, is Facebook's 2008 chat engineering
post — the same claim, made on the record, about the same mechanism:

> *"The most resource-intensive operation performed in a chat system is not sending
> messages. It is rather keeping each online user aware of the online-idle-offline states
> of their friends"*

with the cost characterised as O(average friend-list size × peak concurrent users × churn
rate). Source: https://engineering.fb.com/2008/05/13/web/facebook-chat/

Also verified and useful for its honesty: the IETF draft *"Interdomain Presence Scaling
Analysis for XMPP"* (Saint-Andre) is a **modelling** document whose own text concedes
*"Naturally, real-world studies of deployed systems will be necessary to determine if these
theorized differences occur in reality."*
Source: https://datatracker.ietf.org/doc/html/draft-saintandre-xmpp-presence-analysis-01

### 2.3 Privacy failure modes in XMPP

- **"Presence leak" is a named threat in the RFC itself.** RFC 6121 instructs clients to
  verify the `from` address on roster pushes and *"MUST NOT process the pushed data"* from
  an unauthorised entity — explicitly overriding a MUST from XMPP-CORE *"for the purpose of
  preventing a presence leak."* (VERIFIED)
- **Directed presence** lets a client push presence to a JID that never subscribed —
  presence delivery is not strictly subscription-gated. (VERIFIED)
- **Invisibility needed its own extension** (XEP-0126), and privacy filtering needed another
  (XEP-0016, Privacy Lists). Base RFC 6121 has no privacy-preserving third state: you are
  subscribed-and-visible or unsubscribed-and-invisible.
  Sources: https://xmpp.org/extensions/xep-0126.xml · https://xmpp.org/extensions/xep-0016.html
- Real-world consequence (INFERRED, credible named source): auto-populated corporate rosters
  leak org-chart data — names, titles, usernames — as phishing recon.
  Source: https://bishopfox.com/blog/xmpp-underappreciated-attack-surface

**Constraint:** if invisibility is bolted on afterwards it will be incomplete. The Ore
doc's instinct — invisible mode as *the absence of an action* rather than a flag the server
honours — is the direct structural answer to XEP-0126 existing at all.

---

## 3. The disclosure problem

### 3.1 The measured evidence (VERIFIED — anchor citation)

**Cobb, Simko, Kohno & Hiniker, "User Experiences with Online Status Indicators", CHI 2020.**
n=200, MTurk, ages 19–64, >90% US, across 44 apps with online status indicators (OSIs).
DOI 10.1145/3313831.3376240

Measured findings:

| finding | figure |
|---|---|
| changed settings/behaviour to avoid being seen **by one specific person** | **43%** |
| logged into an app specifically to check someone else's status | **>50%** |
| suspected someone had noticed their status | **>50%** |
| unsure whether an app they use broadcasts their status | **62.5%** |
| wrongly believed an app they regularly use does *not* broadcast status | **35.5%** |
| gave up trying to find the OSI privacy settings | **28%** |
| believed they had disabled an OSI setting **that does not exist** | **23%** |

The paper's framing: *"Online status indicators are sharing information without taking
explicit direction from the user."*
Sources: https://dl.acm.org/doi/abs/10.1145/3313831.3376240 ·
https://www.washington.edu/news/2020/04/13/how-online-status-indicators-shape-our-behavior/

**This is the strongest single argument for the design's client-originated half**, and it
is an argument about *explicit direction*, not about cryptography. Note also the second-order
finding: presence is a *pull* for the observer (>50% logged in just to check someone), which
is why every product ships it despite the above.

### 3.2 Signal — the absence, and the missing rationale

Signal ships no presence indicator. **NOT FOUND: any official Signal statement giving the
reason.** Feature requests exist and are old (`signalapp/Signal-Android#3252`,
"Please add optional online/offline/last seen status feature"; `#3835`) but Signal routes
feature discussion off GitHub to its community forum, and no forum thread with a staff
rationale surfaced. Every third-party page asserting "Signal omits presence for privacy"
states the conclusion without linking a Signal source.

What Signal *does* ship, and documents, is the adjacent-but-different thing: **typing
indicators and read receipts, both opt-in and user-controllable**, delivered inside the
encrypted channel rather than as server-observed state.
Source: https://support.signal.org/hc/en-us/articles/360020798451-Typing-Indicators

**Finding, stated as a finding:** "Signal chose no-presence for privacy reasons" is received
wisdom with no traceable origin. If the design leans on it, phrase it as an inference from
behaviour, not a quotation. The *shape* of what Signal actually ships is more useful anyway:
ephemeral social signals that live in the encrypted channel and are per-conversation
controllable.

### 3.3 WhatsApp — the seven-year gap

- **The primary artifact: WhatsSpy Public**, Maikel Zweerink, Feb 2015. An explicit
  proof-of-concept that tracked online/offline transitions **even when the target set "last
  seen" to "nobody"** — because the privacy control covered the *last seen text* and not the
  *real-time online pip*. A short polling script recording first/last "online" per day
  infers sleep and wake times.
  Sources: https://www.theregister.com/security/2015/02/16/whatdahell_whatsapp_student_claims_stalker_tool_shows_security_flaws/ ·
  https://github.com/jorik041/WhatsSpy-Public
- **WhatsApp's fix landed in 2022** — Aug 2022 announcement of online-presence control,
  broad rollout Nov 2022. **Roughly seven years** between the public demonstration and a
  dedicated control.
  Sources: https://techcrunch.com/2022/08/09/whatsapp-privacy-presence-control-screenshot-blocking/
- **Reciprocity** (mechanism VERIFIED, official rationale NOT FOUND): hide your last seen
  and you lose the ability to see others'. Same symmetric rule for read receipts.

**Constraint, and it is a sharp one:** WhatsApp's failure was that it had **two presence
signals with one privacy control**. The "last seen" setting did not govern the live pip. Any
design here that renders more than one liveness signal (aboard, in a call, typing,
last-active) must have the disclosure control govern **all** of them or it will reproduce
this exactly.

The reciprocity pattern is also a live design question for us: is invisibility one-sided
(you hide, you still see) or symmetric? The Ore doc's "invisible mode is simply not signing"
is *one-sided* by construction — you stop emitting but keep receiving. That is the
surveillance-friendly direction, and it is worth deciding on purpose rather than inheriting
it from the mechanism.

- **No academic paper** specifically on WhatsApp-online-status sleep inference — the primary
  source is a researcher PoC plus press. **NOT FOUND** at the peer-reviewed level.
- **Intimate-partner surveillance:** Freed et al., *"A Stalker's Paradise"*, CHI 2018 (n=89)
  establishes the "UI-bound adversary" threat model — abusers using ordinary app UI, not
  exploits. **UNCONFIRMED at the passage level** whether presence/last-seen is named
  specifically; the fetch returned raw PDF bytes. Flagged rather than asserted.
  Source: https://nixdell.com/papers/stalkers-paradise-intimate.pdf

### 3.4 Battery and mobile cost

**Effectively NOT FOUND** as an isolated measurement. No study separates presence-heartbeat
cost from other background messaging traffic. Adjacent measured data only:

- An Apple developer forum report: keep-alive pushes every 10 minutes held CPU/network awake
  **~36 seconds per push** for 2–3 seconds of actual work — wake overhead exceeding useful
  work by ~10–15×. Anecdotal, not a controlled study.
  Source: https://developer.apple.com/forums/thread/89270
- ~2% additional battery drain/hour on standby LTE from frequent background prekey traffic
  in WhatsApp (arXiv 2504.07323) — adjacent mechanism, not presence.

**Constraint:** the mechanism (frequent small background wakes cost battery disproportionate
to their bytes) is well-supported even though the number is not. This bites the heartbeat
interval directly, and it bites *harder on the signing client than on a plain beacon*, since
a signature is CPU work on a wakeup path. It also interacts badly with Matrix's observed
failure trigger — mobile background/foreground churn (§1.3).

---

## 4. Expiry, ghosts, and clocks — the hard part

### 4.1 Nothing below the application layer will tell you a peer died

**VERIFIED.** RFC 6455 defines Ping (0x9) and Pong (0xA) and says an endpoint *"MAY send a
Ping frame any time after the connection is established"*. The word "interval" does not
appear in the RFC. Cadence, timeout, and how-many-misses-is-dead are entirely
implementation-defined. Source: https://www.rfc-editor.org/rfc/rfc6455.html

The half-open case — peer crashed, power lost, NAT silently dropped the mapping, VM killed —
produces **no packets at all**, so TCP's ACK/retransmit machinery never fires on an idle
connection. The OS backstop is far too slow to matter (**VERIFIED**, `man 7 tcp`):

- `tcp_keepalive_time` = **7200s (2 hours)** before the first probe
- `tcp_keepalive_intvl` = **75s**, `tcp_keepalive_probes` = **9**
- worst case ≈ **7875s ≈ 2h11m** — and `SO_KEEPALIVE` is off unless explicitly set.

Source: https://man7.org/linux/man-pages/man7/tcp.7.html

**Constraint, stated flatly:** *a socket being open is not evidence that anyone is there.*
A green dot driven by connection state is a claim about a file descriptor. This is
independent of, and prior to, any argument about signing.

### 4.2 The fanout arithmetic at our actual N — my own calculation

*(This is my arithmetic, not a cited source. Model stated so it can be attacked.)*

Model: island of **N** members, all mutually visible (island-wide presence, as Nick asked
for), **D** live connections each. Every presence change is relayed to every other member's
every connection.

**Event-driven (relay on state change).** One transition costs `(N−1)·D` frames. With each
member generating **T** transitions/hour (mobile background/foreground churn plus idle
timers — Matrix's §1.3 report shows this is the dominant generator; T=30/hr is a moderate
active-mobile estimate):

| N | D=2, T=30/hr | frames/sec |
|---|---|---|
| 5 | 1,200 /hr | 0.3 |
| 50 | 147,000 /hr | 41 |
| 500 | 14,970,000 /hr | 4,158 |

The N² term is invisible at 5, awkward at 50, fatal at 500 for a single FastAPI process.
Note the middle row lands right on ispresencefixedyet's *"upwards of 100,000 times an hour"*
for small servers — the arithmetic reproduces the field's reported figure, which is a weak
positive control on the model.

**Lease-driven (relay every renewal), heartbeat every H seconds:**
cost = `N · (3600/H) · (N−1) · D` frames/hour — **independent of user behaviour**.

| N | H=60s, D=2 | vs. event-driven above |
|---|---|---|
| 5 | 2,400 /hr | **2× worse** |
| 50 | 294,000 /hr | **2× worse** |
| 500 | 29,940,000 /hr | **2× worse** |

**This is finding #2 and it is the sharpest constraint in the document.** A lease model
relayed naively is *strictly worse at every scale*, and worse in a nastier way: its cost is
paid **at rest**. A silent island at 3am costs exactly as much as a busy one. Event-driven
presence at least goes quiet when people do.

The resolution is structural, not parametric: **renewals must terminate at the island.**
The client→island heartbeat is `N · 3600/H` messages/hour — **linear in N** (50 users at
H=60 → 3,000/hr, nothing). The island→client direction then carries only *derived state
changes*, which is the event model again, now with ghosts correctly resolved. The lease
belongs on the client↔island edge; it must never appear on the island↔client fanout edge.

Second-order: this also fixes the mobile battery problem asymmetrically. The expensive
direction (waking N−1 devices) becomes silent; the cheap direction (one device emitting on
its own schedule) is the one that stays.

**Signature cost is not the bottleneck.** Ed25519: 64-byte signature, 32-byte public key
(RFC 8032, VERIFIED). Verification is sub-millisecond on modern hardware (INFERRED — order
10⁵ cycles; I did not land a citable benchmark, and the conclusion is robust to an order of
magnitude either way). At N=500 a client verifying every peer's assertion once a minute
does ~500 verifies/min — tens of milliseconds. **The crypto is cheap; the fanout is not.**
The real signing cost is *bytes on the wire* (a signed assertion is perhaps 5× a bare state
flag) and *CPU on a mobile wakeup path* (§3.4), not verification throughput.

### 4.3 What TTL multiple do real systems use

**VERIFIED**, each from primary docs:

| system | heartbeat | timeout | multiple |
|---|---|---|---|
| **MQTT 5.0** | client-chosen Keep Alive | broker MUST disconnect after **1.5×** — normative `[MQTT-3.1.2-24]` | **1.5×** |
| **SignalR** | `KeepAliveInterval` 15s | `ClientTimeoutInterval` 30s; docs say client timeout *"should be at least double"* keep-alive | **2×** |
| **Socket.IO v4** | `pingInterval` 25s | `pingTimeout` 20s → worst case ~45s | **~1.8×** |
| **etcd lease** | client convention: renew at **TTL/3 + 1s** | app-chosen TTL | **3×** |
| **Kubernetes node Lease** | kubelet renews every **10s** | `node-monitor-grace-period` **40s** | **4×** |
| **Discord gateway** | server-assigned `heartbeat_interval` (~41.25s typical) | no ACK by the *next* tick ⇒ close and Resume | **1×** |
| **Phoenix Channels** | 30s default | relies on transport idle timeout | — |
| **Consul session** | app-driven | default TTL **15s**; separate `LockDelay` 15s | — |

Sources: https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html ·
https://learn.microsoft.com/en-us/dotnet/api/microsoft.aspnetcore.signalr.huboptions.keepaliveinterval ·
https://socket.io/docs/v4/server-options/ · https://etcd.io/docs/v3.5/tutorials/how-to-create-lease/ ·
https://kubernetes.io/docs/concepts/architecture/leases/ ·
https://docs.discord.com/developers/events/gateway-events ·
https://developer.hashicorp.com/consul/api-docs/session

**The engineering answer:** production systems cluster at **1.5–2×** when they want fast
detection and can absorb false positives, and **3–4×** when a false "dead" verdict is
expensive. Nobody runs 1× **except** systems whose reconnect is nearly free — Discord can,
because its Resume protocol makes a wrong death verdict almost costless. The stated reason
everywhere is identical: **absorb one missed or delayed heartbeat**, because jitter and GC
pauses make 1:1 produce unacceptable false-positive churn.

Constraint: pick the multiple from *what a false offline costs*. For social presence a false
offline is cheap and self-correcting (they reappear in seconds), which argues toward the
fast end — but it interacts with the battery constraint, since fast detection means a short
heartbeat means more mobile wakeups. That trade is the design's to make.

### 4.4 Clock trust — the converged answer

RFC 7519 (JWT) on `exp`/`nbf`, verbatim: *"Implementers MAY provide for some small leeway,
typically no more than a few minutes, to account for clock skew."* **MAY**, and
deliberately unquantified. OIDC Core repeats the identical language for ID Tokens.
Real defaults are stricter than the RFC suggests — **PyJWT ships leeway = 0**; you must pass
`leeway=` explicitly.
Sources: https://www.rfc-editor.org/rfc/rfc7519 · https://openid.net/specs/openid-connect-core-1_0.html ·
https://pyjwt.readthedocs.io/en/latest/usage.html

**The core problem, named:** in a *self-issued* assertion the issuer picks `exp`, so the
issuer's clock is the authority and a broken or malicious issuer can claim a far-future
expiry. Biscuit's issue tracker has this exact bug on record: a block adding a future time
fact can *"effectively nullify all following TTL checks."*
Source: https://github.com/eclipse-biscuit/biscuit/issues/88

**How every real system solves it — and they all solve it the same way.** Not with clock
synchronisation. With a **verifier-side absolute ceiling** applied regardless of what the
assertion claims: `effective_exp = min(claimed_exp, now + MAX_LIFETIME)`.

| system | the cap |
|---|---|
| **SPIFFE/SPIRE** | `default_jwt_svid_ttl` ~5 min, `default_x509_svid_ttl` ~6h; deployments split *default* from operator-set *maximum* |
| **CA/Browser Forum** | TLS cert lifetime cap, currently 398d, ballot SC-081v3 steps it to **200d (Mar 2026) → 100d (2027) → 47d (2029)** |
| **AWS presigned URLs** | hard **7-day** max, further bounded by the signing credential's own expiry |
| **Kubernetes bound SA tokens** | default 1h, floor 10 min, ceiling via `--service-account-max-token-expiration` |
| **SSH certificates** | convention 8–24h, minutes for per-access certs (no protocol backstop — convention *because* there is none) |

Sources: https://spiffe.io/docs/latest/deploying/spire_server/ ·
https://cabforum.org/2025/04/11/ballot-sc081v3-introduce-schedule-of-reducing-validity-and-data-reuse-periods/ ·
https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html ·
https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/

**Constraint:** "whose clock is T on?" is the wrong question and has been answered wrongly by
people who asked it. The right question is **"what is the maximum lifetime the verifier will
honour?"** — and both the island and every verifying client must clamp independently. A
client with a badly-wrong clock then fails *closed* (its assertions look expired or
not-yet-valid and it appears offline), which is the correct failure direction for presence.

This retires the Ore doc's second falsifier — *"if the island cannot bound a signed claim's
lifetime without a server-side clock anyway, the signature may buy less than it costs"* —
but only halfway. The island **can** bound it, with a constant, no clock negotiation needed.
Whether the signature is then worth its cost is §6's argument, not this one.

**NOT FOUND:** any rigorous measured distribution of consumer-device clock skew in the
field. Studies exist that *use* clock skew for device fingerprinting, and IoT drift studies
exist, but no population measurement of how far off a typical phone runs. So any skew
allowance chosen here is a convention (the RFC's "a few minutes"), not an empirical number
— and should be labelled as such rather than defended as measured.

### 4.5 Why a lease beats an event model for ghosts

**INFERRED** — I could not find a canonical essay arguing "presence is a lease you renew,
not a state you set" (that framing appears to be ours, not the literature's). Martin
Fowler's *Lease* pattern documents the renewal mechanism but does not make the presence
argument. Source: https://martinfowler.com/articles/patterns-of-distributed-systems/lease.html

The reasoning the sources *do* support is §4.1's: an event model requires the `offline`
event to always fire, and the crashed peer is precisely the one that never gets to send it.
A lease inverts the default — **offline is what decay produces automatically, online is what
must be continuously re-earned.** This is exactly the Kubernetes node-Lease and DHCP shape.
The claim is sound; it is our synthesis of verified mechanisms rather than a citation.

---

# PART II — THE SOLUTION SPACE

> **Withheld from Spark.** How prior art actually solved it. Read at Cast.

## 5. How others built it

### 5.1 Slack — pushed, then forced to pull, and they said why

Presence is **per-workspace** (VERIFIED). The interesting part is the migration. Slack's own
developer changelog, 2017, verbatim:

> *"Dispatching presence events for all users in a workspace is an expensive operation for
> Slack. A flood of presence events from large workspaces can also disrupt your app's
> ability to process more useful, timely messages."*

Mandatory Nov 15 2017; fully enforced Jan 30 2018. The replacement is a subscription model:
`presence_sub` (ongoing, and **the client must declare its entire subscription set in each
request** — not additive) and `presence_query` (one-shot bulk, ≤500 user IDs). `rtm.start`
stopped bulk-returning presence; `users.list` presence was capped then deprecated.
Presence is **RTM/WebSocket only — it cannot be delivered via the Events API at all.**

Auto-away after **10 minutes** of inactivity, server-inferred; `manual_away` persists across
reconnects and overrides.

Sources: https://docs.slack.dev/changelog/2017-10-making-rtm-presence-subscription-only ·
https://docs.slack.dev/changelog/2018-01-presence-present-and-future ·
https://docs.slack.dev/apis/web-api/user-presence-and-status

### 5.2 Discord — the client self-reports, and that is the whole trick

Two mechanisms worth separating:

**Client-originated state.** Discord clients send their own presence via gateway op 3
(`online`/`idle`/`dnd`/`invisible`), rate-limited to 5 updates per 20 seconds. The server
relays what the client says. **Discord does not infer your state from your socket** — it is
told. (INFERRED from gateway docs; the mechanism is well attested.)

This matters enormously for §6: **`invisible` on Discord is exactly "don't say you're
here", unsigned, and it delivers the Ore doc's privacy property already.**

**Audience narrowing.** Presence is per-guild, gated behind the `GUILD_PRESENCES` privileged
intent — opt-in, with Discord's stated rationale being user privacy (*"so users across the
platform can enjoy a higher level of privacy"*; INFERRED, the primary support page returned
403). Access moved in 2026 from a 100-server threshold to a **10,000 unique-user** threshold.
And clients auto-subscribe to full presence only for guilds under **75,000 members**
(the "Lazy Guild" mechanism); above that, presence is pulled for specific member subsets.

Sources: https://docs.discord.com/developers/events/gateway-events ·
https://support-dev.discord.com/hc/en-us/articles/40281523410967-Changes-to-Privileged-Intent-Access-for-Discord-Apps ·
https://discordpy-self.readthedocs.io/en/v2.0.1/guild_subscriptions.html ·
https://arandomnewaccount.gitlab.io/discord-unofficial-docs/lazy_guilds.html

**The architectural fork, stated plainly:** *Slack infers presence from server-observed
activity; Discord trusts the client's self-report.* The proposed twist is the Discord side of
this fork, plus a signature.

### 5.3 The convergence

XMPP, Slack, Discord and Matrix all started with broadcast-to-everyone presence and were
**each independently forced into a subscription or pull model by production load**. Four
systems, four independent discoveries, one answer: **narrow the audience.** Matrix is
executing this migration right now (MSC4495, §1.5) and explicitly claims it as a
*privacy* improvement as well as a performance one.

### 5.4 Nostr — the closest thing to a self-signed status that exists

**VERIFIED** from the NIP source files:

- **Ephemeral events (NIP-01):** *"for kind `n` such that `20000 <= n < 30000`, events are
  ephemeral, which means they are not expected to be stored by relays."* Note carefully:
  this is a **storage hint**, not a time bound and not a liveness claim.
- **NIP-38 User Statuses, kind 30315:** an **addressable** (replaceable) event —
  *"an optionally expiring addressable event, where the `d` tag represents the status type"*.
  Last-write-wins per `(pubkey, kind, d-tag)`. Status types `general` and `music` — and the
  `music` case sets the event's expiration **to match the remaining track duration**, which
  is the closest existing example anywhere of a signed claim whose expiry is computed to
  match a real-world liveness window. Empty content clears the status.
- **NIP-40 expiration:** relays *"SHOULD NOT send expired events to clients, even if they
  are stored"* and *"SHOULD drop any events that are published to them if they are expired"*
  — **SHOULD, not MUST**, and explicitly *"relays MAY NOT delete expired messages
  immediately on expiration and MAY persist them indefinitely."* The NIP carries its own
  blunt caveat that expiration *"should not be considered a security feature."*

Sources: https://github.com/nostr-protocol/nips/blob/master/01.md ·
https://github.com/nostr-protocol/nips/blob/master/38.md ·
https://github.com/nostr-protocol/nips/blob/master/40.md

**Direct lesson:** relay-side expiry enforcement is advisory. **Staleness must be computed
client-side from the signed timestamp**, never trusted to the relay/island honouring an
expiry — a lazy or malicious island can keep serving an expired "aboard" claim forever.
This is a *mandatory* property of the design, not a nicety. It is also the one place where
the signature does unambiguous work: because the assertion carries its own signed T, a
client can refuse a stale claim **without the island's cooperation**.

### 5.5 The gap — nobody signs *liveness*

- **ActivityPub:** **NOT FOUND** for presence. There is a proposal-stage FEP-82f6 "Actor
  statuses" (short status text, optional expiration) — the ActivityPub analogue of NIP-38,
  under discussion, not ratified.
  Source: https://socialhub.activitypub.rocks/t/fep-82f6-actor-statuses/5310
- **DIDComm Trust Ping:** a *liveness probe*, point-to-point request/response ("are you
  there" → "yes"), not a broadcast presence primitive. Doesn't scale to a roster without
  N individual polls, which is worse than XMPP's fanout.
  Source: https://identity.foundation/didcomm-messaging/spec/v2.1/#trust-ping-protocol-20
- **Nothing found** that signs a short-lived self-issued *liveness* assertion.

**Every federated signed-object protocol converges on self-signed *status* (what am I doing)
and none of them has built self-signed *presence* (am I here).** That gap is either a real
opportunity or a signal that everyone who got close decided it wasn't worth it. §6 argues
the latter case as hard as it can.

### 5.6 Summary of the solution space

| system | who originates | audience | expiry | signed |
|---|---|---|---|---|
| XMPP | client sends stanza, server broadcasts | roster subscribers × resources | dies with the stream | no |
| Matrix (today) | server infers | everyone sharing a room | server idle timer ~5 min | no |
| Matrix (MSC4495) | server infers | **explicitly interested users only** | as today | no |
| Slack | server infers from activity | per-workspace, **subscription-scoped** | 10 min auto-away | no |
| Discord | **client self-reports** | per-guild, intent-gated, <75k auto | client-driven | no |
| Nostr NIP-38 | **subject signs** | pull/query from relays | optional tag, **advisory** | **yes** |
| Signal | — | — | — | — |
| **proposed** | **subject signs** | island-wide | **signed T** | **yes** |

---

# PART III — THE STEELMAN

## 6. "The signature is theatre" — the strongest case against

*Requested explicitly and argued at full strength. My own analysis; the mechanisms it leans
on are cited above.*

### 6.1 The signature protects the wrong failure, and the unprotected one is invisible

Presence has two failure directions. **False positive:** showing someone aboard who is not.
**False negative:** hiding someone who is. Signing prevents only the first — the island
cannot fabricate an assertion for a key it does not hold.

But the second failure is the one the island can commit *perfectly*, and signing makes it
no harder: the island simply drops your assertion and you appear offline. And here is the
sting — **in a lease model, "offline" is the null hypothesis.** Absence of evidence *is* the
rendered state. Censorship is not merely undetectable; it is byte-identical to the system's
own idle path. There is no anomaly to notice, ever.

So the design cryptographically closes the direction that requires the island to *act*, and
leaves wide open the direction it accomplishes by *doing nothing*. For a feature whose entire
value proposition is "is this person reachable", suppression is the higher-impact attack.

### 6.2 Replay bounds the guarantee at exactly the parameter cost pressures upward

A signed "aboard until T" is a **bearer token for the interval [signed_at, T]**. The island
can hold it and release it later within the window — making you appear present at a moment
you were not. The signature does not prevent this; only a short T does.

So the guarantee is "not present beyond T", and T is set by fanout economics (§4.2), which
push it *up*. The cryptographic property degrades in direct proportion to the performance
pressure. A design that answers "shorten T" is answering with money it showed in §4.2 it
does not want to spend.

*(In fairness: the island cannot* extend *T, because the client's signature covers it and
every verifier clamps independently — §4.4. That is real and it is the honest counter. But
"cannot extend beyond a bound you were pressured to make generous" is a thinner property
than the pitch implies.)*

### 6.3 The trust merely moves one layer down, into a place the island still owns

A verifying client checks: signature valid, T in the future, and **this key belongs to the
person whose avatar I am about to light up green.** That last binding is the load-bearing
one, and per ADR-0004 there is no central directory — the app resolves key↔person through a
**member roster the island serves.**

So the island cannot forge your presence, but it can shape which key the app believes is
Andy. Signed presence relocates the trust from "island asserts presence" to "island asserts
identity binding" — a trust it already holds for messages. **Signing presence therefore adds
no security beyond what message-signing already establishes**, while inheriting that same
unverified binding. The chain is exactly as strong as the roster, and the roster is
unsigned.

### 6.4 The privacy win is real and the signature contributes nothing to it — this is the blade

The Ore doc's most exciting sentence: *"you cannot be shown as present unless you signed a
statement saying so."*

Delete "signed". Substitute "sent". The sentence remains true, and the privacy property is
**identical**:

> you cannot be shown as present unless you *sent* a statement saying so.

That property comes entirely from **moving origination to the client** — from the server not
inferring presence from socket state. It is the Discord architecture (§5.2), it is unsigned,
it has shipped for a decade, and `invisible` is exactly "don't send". The cryptography adds
nothing whatsoever to the disclosure story.

The twist bundles two independent ideas:

| idea | value | cost |
|---|---|---|
| **client-originated presence** | delivers the entire privacy property; retires §4.1's "a socket is not a person"; makes invisibility structural rather than a flag | ~nil — it is a simpler server |
| **cryptographic self-attestation** | protects only §6.1's fabrication direction; relocates trust per §6.3 | wire bytes, mobile CPU on a wakeup path (§3.4), key handling, verification UX for unresolvable keys |

**And the design credits the privacy benefit to the wrong half.** If Spark and Cast do not
separate these, the forge will spend its budget defending cryptography for a property that
was already free — and the CRUCIBLE's own falsifier ("if Nick looks at a plain green-dot
mock and says yeah, that's all I wanted") will have been answered with the wrong variable
held fixed. The honest experiment is a **client-originated unsigned** mock, not a
server-inferred one; if *that* satisfies, the signature was never the thing.

### 6.5 Who is the adversary, and is this their cheapest attack?

The island is self-hosted, typically by a member of the community. The signature defends
against **a malicious island operator fabricating your presence**. Price that attack: it
mostly causes people to message you. Now price what the same operator can already do
without breaking anything:

- read all message plaintext (group E2EE is unbuilt — `project_group_e2ee_crucible`)
- observe all call media in the clear (LiveKit SFU, forced relay, no `e2eeOptions`)
- withhold, delay, and reorder anything, including presence (§6.1)
- serve the roster that decides which key is which person (§6.3)

Against that list, presence-forgery is a **strictly lesser** attack, and it is the only one
the proposal closes. Spending the fanout budget, the byte budget and the mobile-wakeup
budget on the weakest hole in the wall is misallocation — the exact shape
`chatskin/TEMPER.md` struck down: build the smaller gold, make the abstraction earn itself.

### 6.6 For robots, the signature attests something that cannot be interesting

A resident agent is aboard permanently. Its signed lease, renewed forever by a loop, attests
"a process that holds this key is running" — which is what a heartbeat says, for 64 fewer
bytes each time. The Ore doc's line that robots "arrive correctly and for free" is true and
is a property of **key-based identity**, which the app already has. It is not a property of
signing *presence*.

### 6.7 What the signature actually does buy — the honest counter

Argued against myself, at the same strength:

1. **Cross-island federation.** A remote island relaying claims about *my* members has no
   authority to assert them; a signed claim is self-authenticating in transit and needs no
   trust in the relaying hop. **This is real, it is not obtainable any other way, and
   federation is this project's north star.** But it is a bet on a capability that does not
   exist yet, and it should be *stated as such* — not sold as today's privacy win.
2. **Client-side staleness without island cooperation** (§5.4). Because T is signed, a
   client can refuse an expired claim even if the island keeps serving it. Nostr's NIP-40
   proves this matters: relay-side expiry is advisory everywhere it has been tried. This is
   the strongest *present-tense* argument for the signature.
3. **Non-repudiable attendance.** Only a signed aboard-claim survives leaving the island —
   it can be carried, shown, and verified elsewhere. This connects directly to
   `project_the_carried_record`, and a compromised island cannot manufacture an attendance
   record. Whether presence should *be* evidence is a separate question the design should
   ask deliberately rather than acquire by accident.
4. **Consistency of law.** Task #17 already ruled that an evidence viewer must verify
   signatures itself and never render the island's attribution. Presence rendered on the
   island's unverified word is the one exception in an app where everything else is signed
   at birth — and exceptions to a trust rule are how trust rules die.

**The steelman's verdict, stated fairly:** arguments 2 and 4 survive §6.1–§6.6 intact.
Argument 1 is real but deferred. What does *not* survive is the privacy pitch (§6.4) and the
threat-model justification (§6.5). The design can live — but it must stop claiming the
signature buys privacy, and start claiming what it actually buys: **island-independent
staleness, a consistent trust law, and a federation property paid for early.**

---

## 7. Open questions this research did not settle

- **Scope** (Ore's open variable): island-wide vs per-channel. Every system studied narrowed
  the audience under load (§5.3) — but at N=5 there is nothing to narrow, and premature
  scoping is the abstraction `chatskin/TEMPER.md` struck down. The research says the answer
  changes at federation, not at member count.
- **Reciprocity** (§3.3): is invisibility one-sided or symmetric? "Not signing" gives
  one-sided by construction. WhatsApp chose symmetric. This is a values decision the
  mechanism will otherwise make silently.
- **One signal or several** (§3.3): aboard, in-a-call (claude-tasks#3159), typing,
  last-active. WhatsApp's seven-year failure was two signals under one control. If these are
  separate mechanisms they need one disclosure control, decided now.
- **Unverifiable keys** (Ore's open variable): what is rendered for a key the client cannot
  resolve to a person? Not answered by any prior art found — every system studied has a
  server-authoritative identity map. This may be genuinely novel territory.
- **Heartbeat interval vs battery** (§3.4 × §4.3): the trade is real, the numbers to price
  it do not exist in the literature, and it should be measured on a real device rather than
  argued.

## 8. Instrument notes and self-assessment

- **Strongest sections:** §4.3/§4.4 (every number from a primary spec or vendor doc) and
  §1 (GitHub API against the actual issue threads, not summaries).
- **Weakest:** §2.1's RFC 6121 quotes came through a summarising fetch, not a byte-level
  read — re-verify before quoting verbatim in anything binding. §5.2's Discord privacy
  rationale is search-indexed only; the primary support page returned HTTP 403.
- **§4.2 is my own arithmetic**, not a citation. The model is stated so it can be attacked;
  its weak positive control is that it reproduces the field's independently-reported
  "~100,000/hour for small servers" figure at N=50.
- **§6 is argument, not evidence** — deliberately so, and it is the section most likely to
  be wrong in an interesting way.
- Two findings arrived by *not* finding things: Signal's missing rationale (§3.2) and the
  absent self-signed-liveness prior art (§5.5). Both are treated as findings rather than
  gaps.
