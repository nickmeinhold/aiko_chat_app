# Design 18 — the visibility boundary: what each party can actually see

**Status:** first cut, 2026-09-09. claude-tasks#3695.
**Audience:** anyone deciding a privacy question about aiko calls or messages. It states
*what the system does*, not what it should do. Every judgement is left open on purpose.

## Why this document exists

Nick asked on 2026-08-30 whether native ringing changes that an island operator cannot see who
is calling whom — **believing operator-blindness was a property we had built.** It is not, and
the record is why: every document in the corpus states what is *protected*; none states the
*boundary*.

The wrong inference was the reasonable one. Sender anonymity is a real named property somewhere
in the corpus (`friends-bilateral-tie/DESIGN.md:189` — *"the island cannot LINK a ring to an
account in its own data"*), and `push_service._payload` argues payload opacity hard. The clause
that scopes it — *"such facts stay WITH the operator"* — is doing enormous work in three words,
in a code comment, in the other repo.

**So the failure this document fixes is not a missing protection. It is a missing sentence.**

---

## The table

**Legend:** ● sees it · ◐ partial, or derivable with effort · ○ does not see it ·
◇ **prospective** — depends on CallKit, which is **not built** (verified: no `CallKit`,
`PushKit`, `CXProvider` or `includesCallsInRecents` anywhere in `ios/` or `macos/`).

| | the user | **own island operator** | **foreign island operator** ◇ | Apple / APNs | Google / FCM | holder of the unlocked handset |
|---|---|---|---|---|---|---|
| **message bodies** | ● | **●** | ○ | ○ | ○ | ● |
| **who-messaged-whom** | ● | **●** | ○ | ◐ | ◐ | ● |
| **call existence** | ● | **●** | ● | ◐ → ● ◇ | ◐ | ● |
| **who-called-whom** | ● | **●** | ● | ○ | ○ | ● |
| **call media (audio + video)** | ● | **●** | **●** | ○ | ○ | ● (live) |
| **IP address** | — | **●** | **●** | ● | ● | ○ |
| **timing / frequency** | ● | **●** | ● | ◐ | ◐ | ● |
| **device tokens** | ● | ● | ○ | ● | ● | ◐ |

**The two columns worth staring at are the bold ones**, and the second one does not exist yet.

---

## Row notes, with provenance marked

Claims are marked **[app]** (verified in this repo this session), **[island]** (inherited from
the island tab or island design docs, **not** re-read against island source by this tab), or
**[open]** (established by neither).

### message bodies · who-messaged-whom — the own-operator column is total

**[island]** `messages.body` is a plaintext `Text` column. `should_wake()` compares it against
the call-invite sentinel *in cleartext*. `_recipients` reads raw membership rows.

**There is no message confidentiality from your own operator today, and none is designed.**
Messages are **signed, not sealed** — signing proves authorship and defeats tampering; it does
nothing for confidentiality. That is a known keystone gap with its own open task, not an
oversight.

### call existence · who-called-whom — a call is an ordinary message

**[app]** A call invite is an ordinary signed DM message whose *body* is a sentinel
(`aiko:call/1 · 📞 started a call`). It carries no parameters — room is the channel, caller is
the signing key, start time is the signature timestamp. That design buys unforgeability and
inherits the whole moderation stack for free.

**It also means the operator sees a call the same way it sees any message:** sender, channel,
body, timestamp, in the clear. **[island]** `schedule_wake(*, channel_id, channel_kind,
sender_id, ...)` carries `sender_id` by construction, so the ring path is attributable in code,
not merely in principle.

**The unresolved tension, stated rather than settled:** Nick ruled on 2026-08-25 that the
island should learn neither who is friends with whom nor who is calling. Designs 12 and 16
build the ring as a stored, attributable message. Those have not been reconciled
(claude-tasks#3745). A counterintuitive corollary belongs here because it cuts the wrong way
for most intuitions: **restricting the caller set SHRINKS the anonymity set** — consent makes
the operator's picture of who-rang-whom *more* precise, not less.

### call media — the row where the two operator columns differ, and it is the biggest cell

**[app, verified at the call site]** `livekit_call_service.dart:210` calls `_room.connect()`
with `connectOptions` and `fastConnectOptions` and **no `e2eeOptions`**. A sweep for
`e2eeOptions | frameCryptor | keyProvider` across `lib/` returns only comments. **The SFU
decrypts your audio and video in order to forward it.** Every call today is in the clear to the
operator hosting it.

**◇ Under cross-island calling (island design 13, Decision 9a — not built):** a call between
two islands is hosted on the **callee's**. The caller's app connects directly to that SFU. So a
**foreign** operator — one the caller never chose, is not a member of, and has no relationship
with — receives the caller's IP, the call's timing and duration, and **the audio and video in
the clear.**

This is not a regression: cross-island calling does not work today
(claude-tasks#3196), so 9a *changes which operator holds that position* for a capability that
does not exist yet. It is listed because it is the shape it would ship in.

**Two halves that differ in kind, not just in recipient:**

- **IP and call metadata** — already a *knowingly accepted* residual. The recorded claim is
  narrow: the island cannot LINK a ring to an account, *"not 'the island doesn't know who
  rang'. Without a mixnet this is an operator promise about logging."* Owner: Nick. What 9a
  does is **transfer that promise-dependency to an operator the user never chose.** E2EE does
  not fix this half.
- **Audio and video content** — never covered by that residual, because same-island hosting
  meant media only ever reached the operator you picked. **This is the bigger half, and it is
  the one E2EE does fix.**

### IP address — and a correction to how this is usually described

**[app]** ICE is **relay-only** (`RTCIceTransportPolicy.relay`), and the reason is *not* peer-IP
privacy. LiveKit's signalling proto has two trickle targets — the client's own publisher and
subscriber connections — and `ParticipantInfo`, the struct the server broadcasts about you, has
**no address field at all**. **No other participant can learn your address under either
policy.** Under `.all` the party that learns it is the operator's SFU; under `.relay` it is the
operator's TURN, which on both live islands is *the same process*.

What relay-only actually buys: **NAT traversal from restrictive networks**, and forcing media
over 443 so it reads as HTTPS to a middlebox. **Reachability and traffic shape, not privacy.**
Cost, real and unpriced: 100% of media egress crosses the operator.

### Apple / Google — the opacity is aimed HERE, and only here

**[island]** `push_service._payload` keeps identities off the push wire. That protects against
**Apple**, not against the operator; own-operator visibility was never protected and, given
cleartext bodies, cannot be by this mechanism.

**◇ Under CallKit, Apple learns slightly more**: a `.voip` topic with `apns-push-type: voip`
makes the event explicitly *"a call"*, where today it is a generic wake for a channel. Identity
stays off the wire via a Swift-readable on-device name cache.

### Holder of the unlocked handset — ◇ a new surface, small and real

**◇** `includesCallsInRecents = true` (Nick, 2026-08-30, and the iOS 26.5 SDK header confirms
`YES` is the default anyway) puts finished calls in the **system call history** — visible on an
unlocked handset and in device backups.

**[open] Whether iOS syncs call history off-device is unverified by either tab.** It has been
asked and not answered. Do not assume either way.

**◇** The CallKit design also introduces an **App Group cache** — a plaintext on-disk map of
channel id → display name and consented keys, readable without the app running. New artifact,
new exposure, small but real.

**So: the island deliberately forgets while iOS remembers on-device.** Nick ruled on 2026-09-01
that the island keeps no record of who called whom (harassment-evidence case withdrawn,
claude-tasks#3773 closed). Written down as a choice it reads as a considered boundary;
discovered later in the code it reads as an inconsistency.

---

## What this document is FOR: three live decisions that should be made against it

### 1. Media E2EE — available today, switched off (claude-tasks#3426)

Room-level media E2EE is **available now** via LiveKit: insertable streams, all tracks and data
channels, group calls supported, the SFU forwards packets it cannot decrypt. **No MLS, no
message-path change.** It is held shut by an island config bolt that exists for a *different*
door — the message-E2EE problem, which is genuinely hard and genuinely unsolved.

Real costs of turning it on: server-side recording, transcription and simulcast layer switching
become limited; and `island_mode` must split into two signed manifest fields, since advertising
`moderator` while media is opaque is mislabel-by-omission.

**And it forces a question rather than avoiding one:** an agent that participates in a call must
be a **keyholder, not an eavesdropper** — a pipeline that cannot decrypt cannot run inference.
Resident agents ringing handsets is already shipped and proven live, so this is not hypothetical.

**Why it is worth re-pricing now:** #3426's decision was priced when the only operator seeing
your media was the one you chose. Under 9a it becomes the thing keeping an **unchosen** operator
out of your call content.

### 2. Cross-island call hosting (island design 13, Decision 9a)

The row above is the decision. It is currently an engineering ruling about where a room lives.

### 3. The momentary ring (design 16 v2 §1d)

iOS requires every VoIP push be reported to the system **before** the app may decide anything.
So a caller the device refuses still makes the phone buzz for a fraction of a second — through
silent mode and Do Not Disturb — before it stops. Bounded, and **observable by whoever is
doing it**, which makes it the harassment surface.

The alternative — the island refusing to send at all — buys genuine silence at the price of the
island learning that *"the same relationship rang N times"*. Unlinkable, revocable,
offline-mintable: pick two.

**[open]** Whether any blind-signature construction gives unlinkability here is **not
established, and neither Claude tab is competent to assert it.**

---

## What is NOT established

- Whether iOS syncs call history off-device.
- Unlinkability of any capability scheme (above).
- The island rows here are **inherited, not re-read against island source by this tab.**
- Everything marked ◇ describes a design, not a running system. **Calling is gated off in every
  shipped build.**

## Provenance

Claude (app tab), 2026-09-09, per claude-tasks#3695. App-side cells verified in this repo this
session at the call sites named. Island-side cells attributed to the island tab and island
design docs, unverified here. Table structure and seed cells are #3695's own.
