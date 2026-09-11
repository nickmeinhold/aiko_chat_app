# Private relational gating: can a server enforce "only friends may ring you" without learning who your friends are?

**Prior-art and literature synthesis — 2026-09-11**

Confidence tags on every substantive claim: `[verified: <url>]` = read in a primary source · `[secondary]` = blog/summary/forum · `[inferred]` = my own reasoning from cited facts.

---

## Headline

The structural argument is **correct about servers and wrong about necessity.** It is a true statement of an unavoidable fact: any server that evaluates a predicate learns that predicate's output. But the brief's own premise — *"the ring/no-ring decision CANNOT be made on the device after the push arrives"* — is **false as stated**. It is true of **PushKit VoIP pushes only**. Since **iOS 14.5**, Apple has shipped a documented, first-party path where a **plain `alert` push** is decrypted by a **notification service extension on the device**, and the *device* decides whether to escalate it into a full CallKit ring. Apple's stated rationale for that API is, verbatim, the situation in this brief: use it *"when your server can't determine whether an outgoing notification is a request for a VoIP call or some other data (such as a text message) due to metadata encryption."* `[verified: https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls]`

That is the escape the argument misses. It does not defeat the argument — it **relocates the decider**, which is the only move that ever defeats it.

There is a second, weaker escape (**capability-based gating**: the relation becomes a bearer token the sender presents, so the server verifies authorisation without learning identity). It is real, deployed, and academically formalised — and it **collapses at ~46 users**, by the explicit admission of its own literature.

---

## 1. Signal sealed sender

### Mechanism

| Component | What it does |
|---|---|
| **Sender certificate** | Short-lived certificate issued by Signal attesting the sender's phone number, public identity key, expiry. Included *inside* the encrypted envelope; validated by the **receiving client**, not the server. `[verified: https://signal.org/blog/sealed-sender/]` |
| **Delivery token / access key** | A 96-bit token derived from the recipient's **profile key**, registered with the service. "The service requires clients to prove knowledge of the delivery token for a user in order to transmit 'sealed sender' messages to that user." `[verified: https://signal.org/blog/sealed-sender/]` |
| **What the server learns** | The **recipient** ("it always needs to know where a message should be delivered"), the timing, the size, the IP. Not the sender identity, not the content. `[verified: https://signal.org/blog/sealed-sender/]` |

**This is directly load-bearing for the central question.** The delivery token *is* a relational access-control gate enforced server-side without a friend table: the server checks "does this sender know Alice's secret?" and learns only a **bit about the sender set**, never a **pair**. That is escape (b) in its shipped form.

### How the guarantee degrades

This is where it matters, and the literature is unambiguous.

**Orca (USENIX Security 2022, Tyagi–Len–Miers–Ristenpart) states the small-set collapse in a primary source:**

> "access keys must be distributed over non-sender-anonymous channels, meaning **the platform learns the identities of users who can send sender-anonymous messages to a particular recipient**. This significantly lowers the anonymity guarantee — **in the limit of having only a single contact, there is no anonymity at all.**"
> `[verified: https://eprint.iacr.org/2021/1380.pdf]`

That sentence is the strongest published statement of the brief's own concern, and it is about *exactly* the access-key mechanism.

**Statistical disclosure attacks (Martiny et al., NDSS 2021, "Improving Signal's Sealed Sender"):** sealed sender does not compose over a conversation. Signal could link sealed-sender users **in as few as 5 messages**, exploiting delivery receipts (on by default, not user-disableable). The attack works at the **application layer**, so Tor/VPN do not defeat it. Proposed mitigations cost "less than $40/month" at millions-of-users scale. `[secondary: https://www.ndss-symposium.org/ndss-paper/improving-signals-sealed-sender/]` (abstract-level read; I did not obtain the full PDF)

**Extension to groups (Brigham & Hopper, arXiv 2305.09799, U. Minnesota):** read in full. The attack generalises from pairs to whole group rosters via the **"flurry"** — the burst of delivery receipts back to Bob after Bob posts to a group. "By monitoring who receives messages most often before a flurry, we can identify the likely members of the group." Confirmed empirically against Android emulator logs. Requires members to be online (else no receipts). `[verified: https://arxiv.org/pdf/2305.09799]`

**Orca's griefing attack:** a malicious sender can craft malformed sealed-sender messages that *neither* the recipient *nor* the platform can attribute; the recipient's client processes them before rejecting, draining battery, and the victim cannot know whom to block. `[verified: https://eprint.iacr.org/2021/1380.pdf]`

### Is sealed sender meaningful at ~50 users on a self-hosted server?

**No — and this is not a judgement call, it is arithmetic plus the Orca sentence above.** `[inferred, grounded in verified sources]`

- The anonymity set is bounded above by the user population (46), and in practice by the recipient's contact list, because only access-key holders can send. Orca: single contact ⇒ zero anonymity. `[verified: https://eprint.iacr.org/2021/1380.pdf]`
- The self-hosting operator additionally sees IP, device tokens, and session timing — signals Signal's own blog concedes are *outside* what sealed sender addresses ("we're continuing to work on metadata resistance against timing and IP-based correlation"). `[verified: https://signal.org/blog/sealed-sender/]`
- Orca's own headline improvement — non-interactive initialisation "expands the anonymity set to be as large as **all registered users of the system**" `[verified: https://eprint.iacr.org/2021/1380.pdf]` — expands it to **46** here.

**NOT FOUND:** a published quantitative study of sealed-sender anonymity at populations under ~1,000. Every analysis I located assumes internet scale.

---

## 2. Message requests / first-contact gating in practice

| System | Gate | Where enforced | Notes |
|---|---|---|---|
| **Signal** | Message Requests (Aug 2020) — non-contacts are accept/reject before they can converse; profile pictures blurred; URLs not linkified on the request screen; repeated reports trigger a CAPTCHA "proof of humanity" | Mixed: UI gate is client-side, the CAPTCHA/rate-limit is server-side | `[secondary: https://signal.org/blog/keeping-spam-off-signal/]` `[secondary: https://latesthackingnews.com/2020/08/17/signal-launches-message-requests-feature-to-fend-off-spammers/]` |
| **Signal (calls/rings)** | The sealed-sender **access key** is the actual server-side relational gate — see §1 | Server, capability-based | `[verified: https://signal.org/blog/sealed-sender/]` |
| **WhatsApp** | "Silence Unknown Callers" (Jun 2023) — Settings › Privacy › Calls. Calls from unknown numbers are silenced but **still appear in the call list** | **NOT VERIFIED** whether device- or server-side | `[secondary: https://blog.whatsapp.com/new-privacy-features-silence-unknown-callers-and-privacy-checkup]`. WhatsApp's own privacy page for calls contains only the settings path, no mechanism description `[verified: https://api.whatsapp.com/privacy/calls]`. **The fact that the call still lands in the call list is weak evidence the call reaches the device and is filtered there** `[inferred]` |
| **iMessage** | "Filter Unknown Senders" — Settings › Messages. Separate tab; **no notifications** for unknown senders | On-device (Apple has the address book locally; the gate is a notification-suppression, not a delivery refusal) `[inferred from behaviour described in]` `[secondary: https://support.apple.com/en-us/125068]` |
| **Matrix** | `m.ignored_user_list` (nuclear: suppresses invites *and* events); **MSC4155 invite filtering** (granular, account-data-driven, `m.invite_permission_config`, error `M_INVITE_BLOCKED`); **MSC2403 knock** (room v7, request admittance without an out-of-band invite) | **Server-side**, explicitly — see below | `[secondary: https://github.com/Johennes/matrix-spec-proposals/blob/johannes/invite-filtering/proposals/4155-invite-filtering.md]` `[secondary: https://github.com/matrix-org/matrix-spec-proposals/pull/2403]` |

### Matrix is the confirming case for the structural argument

Matrix — the largest open federated messaging system — puts the gate **squarely on the server and accepts the leak**:

- **Push rules are evaluated on the homeserver**, which stores the user's rule configuration; the push gateway "merely delivers" already-filtered notifications. `[verified: https://spec.matrix.org/latest/client-server-api/#push-notifications]`
- MSC4155's invite-permission config lives in **account data on the server**. `[secondary: https://github.com/Johennes/matrix-spec-proposals/blob/johannes/invite-filtering/proposals/4155-invite-filtering.md]`
- The privacy work went into the *payload*, not the *predicate*: the `event_id_only` push format sends only `event_id`, `room_id`, counts, devices — so the **push gateway** learns little, while the **homeserver** knows everything. `[verified: https://spec.matrix.org/unstable/push-gateway-api/]` `[secondary: https://github.com/matrix-org/sygnal/blob/main/docs/applications.md]`

Matrix's threat model treats the homeserver as trusted and the *push gateway* as the adversary. `[inferred]` That is a different model from the one in this brief, where the island operator is the party the relation is being hidden from.

### Has anyone reversed or weakened such a gate?

**NOT FOUND** — I found no case of a shipped first-contact gate being withdrawn. The observable direction of travel is the opposite: Signal added Message Requests in 2020, WhatsApp added Silence Unknown Callers in 2023, Matrix has been layering invite filtering since. The MSC4155 discussion notes the invite-spam problem has **open proposals more than five years old** (MSC2270, MSC3840, MSC3847, MSC3659, MSC4264) — evidence of difficulty, not of reversal. `[secondary: https://github.com/Johennes/matrix-spec-proposals/blob/johannes/invite-filtering/proposals/4155-invite-filtering.md]`

**NOT FOUND:** published onboarding/discoverability cost figures for any of these gates. Nobody has released the funnel numbers. The consequences I can cite are qualitative only.

---

## 3. Is the claim named?

**There is no single canonical name for "the verdict leaks the predicate."** What exists is a cluster of named results that each cover a slice of it. `[inferred, after searching PIR / ORAM / anonymous credentials / PSI / metadata-private messaging / searchable encryption]`

### The named neighbours

| Name | What it names | Relevance |
|---|---|---|
| **Access-pattern leakage / leakage-abuse attacks** (Cash et al. 2015 and successors) | The *pattern of which records a query touches* deanonymises the query, even when everything is encrypted. LEAP, VAL, and forward/backward-private SSE attacks extend it. | The closest formal analogue. The lesson generalises: it is not the data that leaks, it is **the system's observable response to a decision**. `[secondary: https://eprint.iacr.org/2016/718.pdf]` `[secondary: https://arxiv.org/pdf/2309.04697]` |
| **Policy-hiding / hidden-policy access control**; **oblivious transfer with hidden access control lists** | Explicitly the problem that an ACL is itself sensitive. The canonical example: a medical record's ACL lists treating doctors, so "the fact that a patient's record has certain specialists in its ACL leaks information about the patient's disease." | This is the brief's claim, named, in a different domain. `[secondary: https://arxiv.org/pdf/1406.1823]` `[secondary — patent literature: https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9111115]` |
| **Secret handshakes** (Balfanz et al., 2003; Castelluccia–Jarecki–Tsudik CA-oblivious encryption 2004) | Two parties authenticate as co-members of a group *only to each other*; a non-member learns nothing, including whether the other party is a member. Properties are formalised as **affiliation privacy**, **fairness**, and **result-hiding** — "even participants within a shared group cannot infer outcomes of unrelated handshakes." | **The named result closest to a genuine escape.** But note what it requires: the *two endpoints* decide. There is no third party rendering a verdict. `[secondary: https://eprint.iacr.org/2004/133]` `[secondary: https://eprint.iacr.org/2009/148.pdf]` |
| **Keyed-verification anonymous credentials (KVACs)** / Signal Private Group System | The server verifies a member holds a credential over the same identity as *some* encrypted roster entry, "without revealing their UID or anything else." The server maintains the group without knowing the group. | The mechanism behind escape (b). `[secondary: https://eprint.iacr.org/2019/1416]` `[secondary: https://signal.org/blog/signal-private-group-system/]` |
| **Differential-privacy metadata-private messaging** (Vuvuzela, Stadium, Karaoke, Talek, Express) | Accepts that *some* leakage is unavoidable and **bounds it with noise** rather than eliminating it. "Systems providing the differential privacy notion of security allow **some quantifiable leakage** of metadata." | The field's own concession that the verdict cannot be fully hidden — only budgeted. `[secondary: https://dl.acm.org/doi/fullHtml/10.1145/3427228.3427231]` `[secondary: https://people.eecs.berkeley.edu/~matei/papers/2017/sosp_stadium.pdf]` |
| **Orca** (USENIX Sec '22) | The named result for *exactly this problem in messaging*: "Without learning the sender's identity, the platform can check that the sender is not on the blocklist and that the sender can be identified by the recipient." | See §5. `[verified: https://eprint.iacr.org/2021/1380.pdf]` |

### The standard escapes, and what each actually buys

1. **Move the decider off the server** (secret handshakes; on-device filtering). Fully defeats the argument, because there is no server verdict to leak. Cost: the server must act unconditionally, so it does more work and the *attempt* is still visible.
2. **Make the predicate not-about-identity** (capabilities, anonymous credentials, delivery tokens, Orca). The verdict still leaks — but it leaks *"an authorised party acted"*, a fact about a **set**, not a **pair**. The residual leak is the set's existence and cardinality.
3. **Add noise / cover traffic** (Vuvuzela family). Bounds the leak instead of removing it, at real bandwidth cost, and the bound degrades with a shrinking population.
4. **PIR / ORAM.** Hides *which* record was touched. **Does not hide a boolean output**, and I found no construction claiming to. `[inferred — negative result of my search; treat as "not found", not "does not exist"]`

---

## 4. iOS push mechanisms as of late 2026 — **the highest-value section**

### Complete enumeration of `apns-push-type` values

`[verified: https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification]`

| `apns-push-type` | Wakes app from cold start? | CallKit report required? | Ring-like? | Entitlement |
|---|---|---|---|---|
| `alert` | Yes — delivered reliably, user-visible | **No** | Not by itself; **yes via NSE → CallKit** (see below) | none (NSE filtering entitlement needed to suppress/report) |
| `background` | Unreliable; throttled; commonly not delivered when terminated `[secondary]` | No | No | none |
| `voip` (PushKit) | Yes | **YES — mandatory** | Yes, full CallKit | `com.apple.developer.networking.voip` |
| `liveactivity` | **Yes, incl. push-to-start (iOS 17.2+)** — starts a Live Activity with the app fully terminated | No | Persistent Lock Screen / Dynamic Island surface; **not** a ringtone or an answer/decline call UI | Live Activities capability |
| `pushtotalk` | Yes | No (uses PTT framework) | PTT audio session, not a ring | `com.apple.developer.pushtotalk` |
| `complication`, `fileprovider`, `mdm`, `location`, `widgets` | n/a to this problem | No | No | various |

**Interruption levels** (orthogonal to push type): `passive`, `active` (default), `time-sensitive`, `critical`. `[verified: same]`

- **`time-sensitive`** breaks through Focus and the Notification Summary. Requires the Time Sensitive Notifications entitlement (self-service in Xcode). `[secondary: https://documentation.onesignal.com/docs/en/ios-focus-modes-and-interruption-levels]`
- **`critical`** bypasses Do Not Disturb **and the mute switch**, playing sound at a developer-set volume. Requires `com.apple.developer.usernotifications.critical-alerts`, manually reviewed by Apple. Apple "declines requests where alerts are promotional, social or merely time-sensitive"; approved categories are health, safety, security (intrusion/SOS). `[secondary: https://newly.app/articles/critical-alerts-entitlement]` **A social chat app is a poor fit for this entitlement** `[inferred]`.

**iOS 26 additions:** Broadcast push (one payload → all subscribers of a channel, no per-device token list) — relevant to live sports/news, **not** to targeted ringing. `[secondary: https://dev.to/arshtechpro/ios-18-broadcast-push-one-notification-unlimited-reach-1pe0]`

### The PushKit contract has *tightened*, not loosened

- **iOS 26 SDK:** "ALL apps that link against the iOS 26 SDK which receive a voip push through PushKit and which fail to report a call to CallKit **will be now be terminated by the system**, as the API contract has long specified." The last unrestricted PushKit entitlement (`com.apple.developer.pushkit.unrestricted-voip.ptt`) is disabled in the iOS 26 SDK. New development/TestFlight-only diagnostic dialogs warn on failure-to-report and on delivery stoppage; **App Store builds get the termination with no dialog.** `[verified: https://developer.apple.com/forums/thread/787466]`
- **iOS 26.4:** new `didReceiveIncomingVoIPPushWithPayload` delegate carrying `PKVoIPPushMetadata` with a **`mustReport`** property. Criteria that currently make `mustReport` false: **app in the foreground**, **app already on an active call**, **system judges delivery delays have made the call stale**. When false, just call the completion handler. Apple explicitly says the criteria are undocumented and may change. `[secondary: https://developer.apple.com/forums/thread/816211]`

  **`mustReport` is not an escape hatch for a relational gate.** None of the criteria are recipient-policy-driven; they are all system-state observations. `[inferred]`

### **The middle mechanism exists, and it is not new**

**`CXProvider.reportNewIncomingVoIPPushPayload(_:completion:)` — introduced iOS 14.5 / iPadOS 14.5 / Mac Catalyst 14.5 / visionOS 1.0.** `[verified: developer.apple.com JSON API for /documentation/callkit/cxprovider/reportnewincomingvoippushpayload(_:completion:)]`

Apple's documented flow, quoted from the primary source `[verified: https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls]`:

> "If your app can send multiple types of end-to-end encrypted (E2EE) data—for example both text messages and voice over IP (VoIP) calls—**send the encrypted content as a remote notification**. Then, on the receiving device, **use a notification service extension to decrypt the incoming content**. If the content represents a VoIP call, pass the call information to [CXProvider] by calling the [reportNewIncomingVoIPPushPayload] method. The system launches your app before passing the message on to [CallKit]. [CallKit] then displays the call to the user. It uses the same interface as the Phone app… It also responds appropriately to system-level behaviors such as Do Not Disturb."

> "**Only use this approach when your server can't determine whether an outgoing notification is a request for a VoIP call or some other data (such as a text message) due to metadata encryption.** If your server knows that the outgoing content is a VoIP call, send a [voip] push notification instead."

Setup requirements, verbatim from the same page:

1. Request remote-notification permission via UserNotifications.
2. Register for VoIP calls using CallKit.
3. Add a **Notification Service Extension** target.
4. Add **`com.apple.developer.usernotifications.filtering`** to the **NSE target's** entitlements file. (Apply to Apple for it.)
5. Send with **`apns-push-type: alert`**.
6. The NSE decrypts; if it is a call, it calls `reportNewIncomingVoIPPushPayload` **and then silences the push notification**; the system launches the containing app, which reports the call to CallKit normally.

**Why this matters for the central question** `[inferred, from the verified quote above]`: the server sends an ordinary `alert` push **unconditionally**, with an opaque payload. It never evaluates a relational predicate, so it renders no verdict. The **device** — holding the device-local consent list — decides between (a) escalate to a full CallKit ring, and (b) silence it or render it as an ordinary notification. **The premise "the server MUST decide whether to send a VoIP push" does not hold on this path.**

### Caveats on the NSE path — all real, none fatal

- **Entitlement gate.** `com.apple.developer.usernotifications.filtering` is manually granted; reported approved categories are **end-to-end encrypted messaging**, earthquake warnings, education platforms, enterprise healthcare. `[secondary: https://developer.apple.com/forums/thread/713997]` E2EE messaging being an approved category is favourable; a system whose *media* is not E2EE may face a harder review `[inferred]`. There are public reports of rejections `[secondary: https://developer.apple.com/forums/thread/707406]`.
- **Suppression mechanics.** Suppress by returning `NULL` in the content handler, or by setting title, subtitle **and** body all to empty strings. `[secondary: https://developer.apple.com/forums/thread/807801]` (One WebFetch summary claimed suppression works by *not calling* the completion handler — **that is wrong**; not calling it causes the 30s timeout and the *original* notification to display. Do not rely on that reading.)
- **NSE reliability.** ~**30s** budget before the system calls the handler for you; ~**24 MB** memory limit; on crash, timeout, or the system simply not invoking `didReceive`, **the original notification is displayed unmodified.** `[secondary: https://developer.apple.com/forums/thread/744188]` `[secondary: https://developer.apple.com/forums/thread/64634]` `[secondary: https://developer.apple.com/forums/thread/757930]`
  **The failure mode is fail-quiet: a plain notification, not a spurious ring.** For a consent gate that is the safe direction `[inferred]`.
- **Latency.** Alert pushes are not prioritised the way VoIP pushes are, and the NSE adds a decrypt+decide hop before CallKit. **NOT FOUND:** any published measurement of cold-start alert-push → CallKit ring latency versus PushKit. This is the one thing I would measure before committing.

---

## 5. Prior art on private wake/ring gating

### SimpleX — the strongest architectural precedent

SimpleX's whole design *is* escape (b) taken to its limit: there is no user identifier, so there cannot be a friend table.

- **Pairwise per-queue identifiers**: 2 addresses per unidirectional queue, **plus an optional 3rd address specifically for iOS push notifications**, 2 queues per connection. `[secondary: https://github.com/simplex-chat/simplex-chat]`
- The notification server "can observe how many messaging queues your device has notifications enabled for, and approximately how many messages are sent to each queue," but **"cannot observe the actual addresses of these queues, as a separate address is used to subscribe to the notifications."** `[verified: https://github.com/simplex-chat/simplex-chat/blob/stable/PRIVACY.md]`
- Notifications "only contain end-to-end encrypted metadata, not even encrypted message content, and they look completely random to Apple push notification servers." Apple sees only *how many* notifications, "not from how many contacts, or from which messaging relays." `[verified: same]`
- **Limitation SimpleX states itself:** APNs delivery is only available via servers operated by SimpleX Chat Ltd. `[secondary: https://github.com/simplex-chat/simplex-chat]`

**Does it generalise?** `[inferred]` The relation is enforced as a **bearer capability** (holding the queue address) rather than a **lookup** (consulting a table). The server enforces "only authorised parties may deliver here" and learns only that *someone* authorised did. This is precisely escape (b) — and it is the same shape as Signal's delivery token and Orca's tokens. **The cost SimpleX pays is that the server cannot identify senders at all**, which is directly at odds with the brief's stated requirement that the server know the sender for moderation, blocking and rate limiting.

**NOT FOUND:** documentation of how SimpleX handles *incoming calls* on iOS specifically — whether it uses PushKit/CallKit, and whether the ring decision is server- or device-side. This is a gap worth closing directly against the SimpleX iOS source.

### Orca — the academic resolution of exactly the brief's tension

Orca is the paper written for this problem. From the abstract `[verified: https://eprint.iacr.org/2021/1380.pdf]`:

> "Orca … allows recipients to register a **privacy-preserving blocklist** with the platform. **Without learning the sender's identity, the platform can check that the sender is not on the blocklist and that the sender can be identified by the recipient.**"

- Built on a **new group signature scheme** supporting multiple openers, keyed verification, and local revocation.
- **Non-interactive initialisation**: a user can send sender-anonymously to someone they have never contacted, which "expands the anonymity set to be as large as all registered users of the system."
- Extended with **anonymous credentials** so the expensive group signature runs only at conversation initiation, minting a batch of **one-time-use sender tokens**; steady-state cost is **30 B/message** + one group exponentiation client-side, one exponentiation + a strikelist check server-side. Initialisation is O(blocklist size) — ~200 ms for a blocklist of 100.
- Scale claim: "a medium-provisioned server can comfortably support a deployment of a million users."

**Note the polarity.** Orca is a **blocklist** (default-allow, enforce exclusions). The brief wants an **allowlist** (default-deny, enforce inclusions). **NOT FOUND:** a published allowlist analogue with the same properties. `[inferred]` The primitive looks reusable in principle — an allowlist is a membership proof rather than a non-membership proof, which is *easier* — but the anonymity-set arithmetic gets **worse**, because the set shrinks from "all users" to "my friends".

### Other systems surveyed

| System | Finding |
|---|---|
| **Matrix** | Gate is server-side and the server holds the policy. Push rules evaluated on the homeserver `[verified: https://spec.matrix.org/latest/client-server-api/#push-notifications]`; privacy work targeted the push gateway (`event_id_only`, `events_only`, `only_last_per_room`) `[verified: https://spec.matrix.org/unstable/push-gateway-api/]` `[secondary: https://github.com/matrix-org/sygnal/blob/main/docs/applications.md]`. **Sygnal's docs note there is generally no contractual relationship between homeserver operators and push-gateway operators** — the gateway is deployed by the app's owner. `[secondary: same]` |
| **Threema** | Push payloads carry, encrypted, "the Threema ID and (if set) the nickname of the sender along with the ID of the incoming message" — **not readable by Apple**. Threema flags the real risk: correlating a Threema ID's inventory data with push-service data links a Threema ID to an Apple/Google account. Confirms calls depend on push: disabling notifications means "it will no longer be possible to receive calls unless the app is in the foreground." **NOT FOUND** whether Threema gates rings relationally at the server. `[verified: https://threema.com/en/blog/push-notifications-and-data-privacy]` |
| **Session** | Runs its own push notification server sending "oblivious notifications"; Session ID and push token registered **over onion requests**, so they are "never tied to any real-world identifier." Two modes: APNs "fast mode" (exposes IP + token to Apple) and background-polling "slow mode." `[secondary: https://sessionapp.zendesk.com/hc/en-us/articles/4439028541849]` `[secondary: https://github.com/oxen-io/session-push-notification-server]` |
| **Briar** | **No push notifications at all**, by design — P2P over Tor/Bluetooth/WiFi with no central routing server. Cannot ring a cold-started iOS handset. `[secondary: https://briarproject.org/]` `[secondary: https://medium.com/@DarKrMsg/briar-advantages-cons-dangers-34b773fb7244]` The honest reading: Briar solves the privacy problem by **giving up the capability**. |
| **XMPP, Tox, Wire, Jami** | **NOT FOUND.** I did not locate any specification or implementation in these projects for deciding server-side whether to ring without learning the permitting relation. |

**Bottom line on §5:** I found **no system, shipped or specified, that has a server render a relational ring/no-ring verdict without learning something about the relation.** Every real system either (i) accepts the leak (Matrix, Threema), (ii) converts the relation into a capability and accepts a set-cardinality leak (Signal, SimpleX, Orca), or (iii) drops the capability (Briar). The fourth option — move the verdict to the device — is what Apple's NSE path enables and what I found **nobody documented as doing for privacy reasons**, though WhatsApp's Silence Unknown Callers behaviour is consistent with it.

---

## Verdict on the structural argument

**"If the server knows the sender, knows the recipient, and makes a decision depending on the relation between them, it learns the relation — by its own answer. Zero-knowledge proofs hide the witness, not the verdict."**

**The argument is SOUND, and it is TIGHT. Every clause earns its place, and the ZKP sentence is exactly right** — this is the same observation the searchable-encryption field arrived at via leakage-abuse attacks, and the metadata-private-messaging field conceded by switching from *eliminating* leakage to *budgeting* it with differential privacy. `[inferred, grounded in §3]`

**But it is a conditional, and the antecedent is a design choice, not a law.** It holds *given* that the server is the decider. There are exactly two ways out, and the literature knows both:

**(a) Deny the antecedent — take the decision away from the server.** The brief rules this out on the ground that PushKit forbids it. **That ground is factually mistaken.** Apple has shipped, since iOS 14.5, a documented path (`alert` push → notification service extension → `reportNewIncomingVoIPPushPayload` → CallKit) built *for the case where the server cannot tell a call from a message*. On this path the server evaluates nothing, so there is no verdict to leak. This is the escape the argument misses, and it is the only one that fully defeats it. `[verified: https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls]`

**(b) Change what the predicate is about — from an identity *pair* to a bearer *capability*.** The server checks "did this party present a valid token for this recipient?" and its verdict then leaks a fact about a **set** ("someone Bob authorised rang Bob"), never a **pair**. This is Signal's delivery token, SimpleX's queue address, and Orca's group-signature tokens. It **narrows** the leak; it does not remove it. And it is in direct conflict with the brief's requirement that the server know the sender for moderation — Orca exists precisely to reconcile those two, at the cost of a group signature scheme. `[verified: https://eprint.iacr.org/2021/1380.pdf]`

**The strongest published statement to cite** is Orca's, because it names both the tension and its collapse condition in one place:

> "access keys must be distributed over non-sender-anonymous channels, meaning the platform learns the identities of users who can send sender-anonymous messages to a particular recipient. This significantly lowers the anonymity guarantee — in the limit of having only a single contact, there is no anonymity at all."
> — Tyagi, Len, Miers, Ristenpart, *Orca: Blocklisting in Sender-Anonymous Messaging*, USENIX Security 2022. `[verified: https://eprint.iacr.org/2021/1380.pdf]`

**One correction to the framing itself.** The operator's stated objection was to a server-side friend table because "it IS the queryable social graph." That objection is about a **durable, enumerable artifact**. The structural argument is about **inference from behaviour**. These are different harms with different mitigations, and conflating them makes escape (b) look worthless when it is not: a capability system genuinely destroys the durable artifact (there is nothing to subpoena or dump) while leaving the behavioural inference intact. Whether that trade is worth anything depends entirely on the threat model — a snapshot adversary versus a longitudinal one. `[inferred]`

---

## Scale-dependence

**This is where most of the published guarantees evaporate.** Marked ⚠ where the answer differs materially between internet scale and ~50 users.

| Property | Internet scale (10⁶–10⁹) | Household scale (~46) |
|---|---|---|
| ⚠ **Sealed sender anonymity** | Anonymity set = the contact-list holders; meaningful for typical contact lists | Bounded by 46 users, and in practice by the recipient's friend count. Orca: single contact ⇒ **zero** anonymity `[verified: https://eprint.iacr.org/2021/1380.pdf]` |
| ⚠ **Orca's headline improvement** | Anonymity set expands to "all registered users" — millions | Expands to **46** `[inferred from https://eprint.iacr.org/2021/1380.pdf]` |
| ⚠ **Statistical disclosure attacks** | Need ~5 messages against a large population; a real but bounded threat `[secondary: NDSS]` | Trivially easier: fewer candidates, fewer confounding flows, and the operator additionally holds IP, device tokens and session timing `[inferred]` |
| ⚠ **Timing / IP / device-token correlation** | Signal explicitly does **not** defend against these `[verified: https://signal.org/blog/sealed-sender/]`; large populations provide cover | At 46 users on one self-hosted box, the operator sees every side channel simultaneously and has almost no cover traffic. **Any cryptographic sender-anonymity claim is dominated by this.** `[inferred]` |
| ⚠ **Differential-privacy cover traffic** (Vuvuzela family) | Noise is amortised over millions of users; costs are tolerable | Noise must be a large multiple of real traffic to hide anything at n=46; the per-user cost is brutal. **NOT FOUND:** any DP-messaging system evaluated below ~10³ users `[inferred]` |
| **Capability enforcement mechanics** (delivery tokens, queue addresses, Orca tokens) | Works | **Works identically.** The *mechanism* is scale-free — only the *anonymity claim* built on it is scale-dependent `[inferred]` |
| **On-device NSE decision (escape a)** | Works | **Works identically, and is the only listed option that is genuinely scale-free** — it relies on no anonymity set, because the server never evaluates the predicate `[inferred from https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls]` |
| **Message-request UX cost** | Measurable spam-reduction benefit at scale | At 46 known people, a stranger-gate has near-zero spam value; its value is consent and interruption control, not abuse mitigation `[inferred]` |
| **Server-side moderation / rate limiting** | Needs identity at scale | At 46 users, **out-of-band social moderation is available** in a way it is not at internet scale. **NOT FOUND:** literature on whether household-scale systems need cryptographic abuse mitigation at all — every paper I read assumes an adversarial open population `[inferred]` |

**The trap named in the brief is real and it fires here.** Sealed sender, and every anonymity-set-based construction, is a guarantee whose strength is a function of population. At 46 users with a single operator holding every side channel, those guarantees are close to decorative. **The one approach in this entire survey that does not degrade with population is moving the decision off the server** — because it does not hide the decider in a crowd, it removes the decider.

---

## What I could not establish

- Cold-start latency of `alert` push → NSE → CallKit ring versus PushKit VoIP. No published measurement found. **This is the load-bearing unknown for escape (a).**
- Whether `com.apple.developer.usernotifications.filtering` is granted to a messaging app whose *calls* are not end-to-end encrypted.
- Whether WhatsApp's Silence Unknown Callers filters on-device or server-side.
- How SimpleX handles iOS incoming calls specifically (PushKit? CallKit? where is the ring decision?).
- Any published allowlist (rather than blocklist) analogue of Orca.
- Onboarding/discoverability cost figures for any shipped first-contact gate.
- Any XMPP / Tox / Wire / Jami specification addressing private ring gating.
- Any sealed-sender anonymity analysis at populations below ~1,000.

---

# Follow-up: entitlement and latency

*Appended 2026-09-11. Same tagging convention. Nothing above this line was modified.*

## Headline of the follow-up

Two findings invert parts of the picture, in opposite directions.

**The bad one (A3/A4):** an app that fits Apple's *stated* rationale exactly — a genuine end-to-end encrypted messenger whose server cannot distinguish a call from a message — applied for this entitlement for precisely this API and was **rejected twice over two months**, with: *"Support for VoIP calls should be provided by PushKit."* `[secondary: https://developer.apple.com/forums/thread/806632]` The entitlements team appears to reject the VoIP use case **categorically**, notwithstanding Apple's own documentation recommending it. If that generalises, the E2EE-vs-metadata-minimisation distinction is moot, because even the clean E2EE case does not clear the bar.

**The good one (A5):** an **Apple engineer states the entitlement is not needed at all** for the half that matters. And that half is the whole consent gate.

## A5 — Is the entitlement required to *report* a call, or only to *silence* the notification?

**This is a genuine two-source conflict between Apple's documentation and Apple's staff, and I am not going to tie-break it.**

**Source 1 — Apple documentation (iOS 14.5+), says the entitlement IS required to call the method:**

> "To call the `reportNewIncomingVoIPPushPayload(_:completion:)` method, a notification service extension must have a `com.apple.developer.usernotifications.filtering` entitlement."
> `[verified: developer.apple.com JSON API, /documentation/callkit/cxerrorcodenotificationserviceextensionerror-swift.struct/missingnotificationfilteringentitlement]`

There is a **dedicated error case** for it — `CXErrorCodeNotificationServiceExtensionError.missingNotificationFilteringEntitlement`, introduced iOS 14.5 — returned "to the `reportNewIncomingVoIPPushPayload(_:completion:)` method's completion handler." `[verified: same, and /documentation/callkit/cxerrorcodenotificationserviceextensionerror-swift.struct]` A dedicated error code is not weak evidence.

**Source 2 — Apple Staff ("Engineer OP"), Apple Developer Forums, Nov 2025, says it is NOT:**

> "That said, use of `reportNewIncomingVoIPPushPayload()` does not depend on the filtering entitlement. **The filtering entitlement is only required to make the notification silent.** You can still use the functionality of converting notifications to VoIP calls, although the notification will be visible."
> `[secondary: https://developer.apple.com/forums/thread/806632]`

And the same engineer offers the fallback design explicitly:

> "By adapting your messaging in the notification (using the extension) to something that explains the situation and changing the `interruption-level` key in the payload to `passive`, so the notification will not interrupt a foreground app, or make a sound or light up the screen in most cases (while still being visible, though), you should be able to implement the functionality you are after, albeit without the ability to make the notification that turned into a call invisible."
> `[secondary: same]`

**Why this matters more than it looks** `[inferred]`: the entitlement governs **invisibility**, not **decision authority**. If source 2 holds, the relational consent gate works with **no entitlement at all**:

- consented caller → NSE calls `reportNewIncomingVoIPPushPayload` → **full CallKit ring**;
- non-consented caller → NSE does not report → a **`passive`** notification: no sound, no screen wake, no foreground interruption, just an entry in the list.

That is arguably the *right* product behaviour anyway — a non-consented call attempt leaving a quiet trace rather than vanishing. The entitlement would only buy the ability to make it vanish entirely.

**This is a cheap decisive measurement, and it should be run before any more design work:** build an NSE without the entitlement, call `reportNewIncomingVoIPPushPayload`, and read the completion handler. If it returns `missingNotificationFilteringEntitlement`, the docs win. If the call succeeds and a visible notification accompanies the ring, the engineer wins. One afternoon, and it decides whether the entitlement is on the critical path at all.

## A1 — The request process

- Apple's entitlement documentation links to **"Request Notification Service Entitlement"** at `https://developer.apple.com/contact/request/notification-service`. `[verified: developer.apple.com JSON API, /documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering — the reference appears in the page's link table]`
- **The form is behind Apple ID authentication** (302 → `idmsa.apple.com`), so I could not read its fields or its stated criteria. `[verified: HTTP 302 observed]`
- **NOT FOUND:** any public Apple page stating eligibility criteria. Apple's own entitlement doc says only what the entitlement *does* ("Enable receiving notifications without displaying the notification to the user"), then points at the auth-gated form. `[verified: same JSON source]`
- Apple staff on eligibility: *"The decision of whether the filtering entitlement is granted or not is solely in the hands of the entitlements team. Nobody here will have any involvement in granting or expediting the request."* `[secondary: https://developer.apple.com/forums/thread/806632]`

## A2 — Approved categories

Two independent forum posts quote the **request form's own category list** identically:

> "End-to-end encrypted messaging, Earthquake warnings, Education/learning platforms, Enterprise healthcare apps"
> `[secondary: https://developer.apple.com/forums/thread/821262 (Apr '26)]` `[secondary: https://developer.apple.com/forums/thread/713997]`

**Confidence note:** both are developer reports of what they saw in an auth-gated form, not an Apple publication. Two independent sightings agreeing is reasonable corroboration `[inferred]`, but I could not read the form myself.

**NOT FOUND:** any public report from a team that *was* granted it, naming their category. Every thread I found is either a rejection, an unanswered request, or a question. That asymmetry is itself informative — grants generate no forum posts `[inferred]`.

## A3 — Rejections

| Requested for | Apple's stated reason | Source |
|---|---|---|
| Suppressing notifications by device location vs. geofences | **"This is not a supported usecase of the Notification Service Extension filtering entitlement."** | `[secondary: https://developer.apple.com/forums/thread/707406]` (Jun '22, 0 replies) |
| **E2EE messenger, for E2EE VoIP calls via `reportNewIncomingVoIPPushPayload`** — rejected **twice over ~2 months** | **"Support for VoIP calls should be provided by PushKit. For more information, please consult the documentation page 'Responding to Notifications from PushKit'."** | `[secondary: https://developer.apple.com/forums/thread/806632]` (Nov '25) |
| E-commerce, suppressing by local device conditions | asked, never answered | `[secondary: https://developer.apple.com/forums/thread/821262]` (Apr '26) |
| Various | **No response at all** from Apple, including after email follow-up | `[secondary: https://developer.apple.com/forums/thread/757197]` `[secondary: https://developer.apple.com/forums/thread/724206]` |

**The second row is the one that matters, and it should be read carefully.** The applicant's justification is almost word-for-word Apple's own documented rationale:

> "Our server cannot make a distinction when to use 'voip' (call) and 'alert' (apns-push-types). Therefore, the application must be able to use `reportNewIncomingVoIPPushPayload(_:completion:)` function, where `com.apple.developer.usernotifications.filtering` entitlement is needed."
> `[secondary: https://developer.apple.com/forums/thread/806632]`

Rejected. Twice. Told to use PushKit — which is the thing that cannot work here. `[verified quote; inference that this generalises is mine]`

## A4 — The precise question: is "server can't tell it's a call" vs "server can't tell if it should ring" load-bearing?

**Answering exactly, not generously.**

**On the evidence I found, the distinction is probably not the binding constraint — because the *stronger* case already fails.** `[inferred, grounded in the row above]` The E2EE applicant in thread 806632 had the constraint Apple's documentation names, in its purest form, and was rejected with a categorical redirect to PushKit. A weaker variant — "our server *can* tell it is a call, it just cannot tell whether the recipient consented" — is unlikely to clear a bar the stronger one did not.

**Is the entitlement tied to E2EE of message *content* specifically?** The form category is worded "End-to-end encrypted messaging" `[secondary: two sources above]`, which is a claim about the app, not about a specific push. Apple's *API* rationale, by contrast, is about the *server's epistemic position* — "can't determine … due to metadata encryption" `[verified: https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls]`. **These two framings are not the same, and I found nothing reconciling them.** Which one the entitlements team actually applies: **NOT FOUND.**

**Has anyone been granted it for a consent/policy reason rather than an E2EE reason?** **NOT FOUND.** No public report either way.

**Plainly, on the E2EE point you flagged:** a system whose media is not end-to-end encrypted, whose push payload is opaque by *metadata minimisation* rather than by content E2EE, does not sit inside the "End-to-end encrypted messaging" category as worded. Describing it as E2EE to the entitlements team would be a misrepresentation, and describing it accurately puts it outside the four listed categories. **Better to know now than at review — you asked, and that is the honest read.** `[inferred]`

**The consequence, though, is smaller than it looks — see A5.** If the entitlement is not required to report the call, the entitlement question moves off the critical path entirely and becomes a nice-to-have for suppressing the residual notification.

## A5b — An engineering side effect worth knowing before you want the entitlement

Apple DTS (Kevin Elliott, CoreOS/Hardware):

> "Because that entitlement can 'hide' notifications, **its sandbox profile is actually more restrictive than the standard NSE sandbox.** That's what's preventing access to `CXCallDirectoryManager`, not the App ID properties."
> `[secondary: https://developer.apple.com/forums/thread/713997]`

Reported consequences of holding the entitlement, from the same thread: `CXCallDirectoryManager` inaccessible from the NSE; contacts with images cannot be added/updated (`CNInvalidRecords`); `UIScreen.main.bounds` returns zeroes. `[secondary: same]` **Holding the entitlement makes the NSE strictly less capable.** `[inferred]`

---

## B — Reliability and latency

### B1. Measured NSE invocation latency

**NOT FOUND.** I widened the search (general NSE invocation timing, cold-start cost, alert→CallKit benchmarks) and found nothing — no vendor benchmark, no Apple figure, no independent measurement. The searches surfaced only unrelated serverless cold-start literature. **This remains the load-bearing unknown, and it is only answerable by measuring it on a device.**

### B2. Time budget — verified, and it is Apple's own number

> "Your `didReceive(_:withContentHandler:)` method has **only about 30 seconds** to modify the payload and call the provided completion handler. If your code takes longer than that, the system calls the `serviceExtensionTimeWillExpire()` method, at which point you must return whatever you can to the system immediately. **If you fail to call the completion handler from either method, the system displays the original contents of the notification.**"
> `[verified: https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications]`

Corroborated in the class reference: "If you don't update the notification content before time expires, the system displays the original content." `[verified: https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension]`

The **~24 MB memory limit remains second-hand** — I found no Apple statement of a number. `[secondary: https://developer.apple.com/forums/thread/64634]`

**Fail-quiet confirmed from a primary source:** timeout, crash, or a missed completion handler yields the *original notification*, never a spurious ring. `[verified: above]`

### B3. When is the NSE skipped? — **the decisive reliability finding, and it is a real failure mode**

Apple, primary source, emphasis mine:

> "Notification service app extensions only operate on remote notifications configured in the system to display an alert to the user. **If alerts are disabled for your app**, or if the payload specifies only the playing of a sound or the badging of an icon, **the extension isn't employed.**"
> `[verified: https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications]`

And the payload preconditions, same source:

> "The system executes your notification service app extension only when a remote notification's payload contains the following information: The payload must include the `mutable-content` key with a value of `1`. The payload must include an `alert` dictionary with title, subtitle, or body information."
> `[verified: same]`

**This is the sharpest difference between the two paths, and it answers your question directly** `[inferred, from the verified quote]`:

> **The NSE path makes the ability to receive a call conditional on the user having notification alerts enabled for the app. PushKit VoIP does not.**

A user who declines the notification permission prompt, or later switches alerts off — a thing people do to a chat app without ever imagining it disables their phone — **silently loses the ability to be rung at all**. There is no CallKit fallback, because the extension never runs. That is a real failure mode with a plausible user path to it, not a theoretical one.

Low Power Mode is a *separate* and lesser concern: it disables Background App Refresh `[secondary: https://developer.apple.com/library/prerelease/ios/documentation/Performance/Conceptual/EnergyGuide-iOS/LowPowerMode.html]`, but Background App Refresh and alert notifications are different systems, and I found **no** source saying Low Power Mode suppresses NSE execution for a visible alert push. **NOT FOUND** — do not assume it does, and do not assume it doesn't.

### B4. Is an `alert` push throttled where a `voip` push is not?

**No — the documented throttling budget applies to `background` pushes, and `alert` is not a `background` push.** `[verified, with the inference marked]`

Apple's throttling language is scoped explicitly to background notifications:

> "The system treats **background notifications** as low priority: you can use them to refresh your app's content, but the system doesn't guarantee their delivery. In addition, the system may throttle the delivery of **background notifications** if the total number becomes excessive. The number of background notifications allowed by the system depends on current conditions, but don't try to send more than two or three per hour."
> `[verified: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app]`

Nothing in that document extends the budget to `alert`. `[inferred — an argument from the absence of a statement, so treat it as strong-but-not-conclusive]`

Priority: `apns-priority` defaults to 10, and "Specify `10` to send the notification immediately … If the notification requires immediate action from the user, set notification priority to `10`." `[verified: https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns]`

**But APNs is best-effort for every push type, VoIP included**, and two documented behaviours deserve flagging `[verified: same]`:

- **"APNs stores only one notification per bundle ID.** When you send multiple notifications to the same device for a bundle ID, APNs selects only one notification to store." Relevant if the device is offline and several call invites queue — only one survives.
- "As a best-effort service, **APNs may reorder notifications** you send to the same device token." Relevant to invite/cancel ordering: a cancel could in principle arrive before its invite `[inferred]`.
- Note also that Apple's PushKit guidance carries no delivery guarantee either: *"due to the nature of networks, it cannot be guaranteed that a target device will not receive a notification past the `apns-expiration` time."* `[secondary]`

### B — verdict: is the NSE path as reliable as PushKit?

**No, and the gap is one specific thing — not throughput, not throttling, and (as far as anyone has measured publicly) not latency.**

| Axis | NSE + alert push | PushKit VoIP | Verdict |
|---|---|---|---|
| Throttling budget | Not subject to the background-push budget | Not throttled | **Parity** `[inferred from verified docs]` |
| Priority | Default 10, "send immediately" | High priority | **Parity** `[verified]` |
| Delivery guarantee | Best-effort; one stored notification per bundle ID | Best-effort | **Parity** `[verified]` |
| **Requires notification alerts enabled** | **YES — extension isn't employed if alerts are disabled** | **NO** | **NSE is strictly worse** `[verified]` |
| Requires `mutable-content: 1` + an alert dictionary | YES | n/a | Constraint on payload design `[verified]` |
| Failure mode | Fail-quiet: original notification shown | App terminated + VoIP delivery disabled for the device | **NSE is strictly better** `[verified]` |
| Time budget | ~30s, then original content | Must report synchronously | NSE more forgiving `[verified]` |
| Cold-start latency to ring | **NOT FOUND** | **NOT FOUND** (no comparison exists) | **Unknown — measure it** |
| Entitlement risk | Contested (A5); if required, evidence says likely denied | `networking.voip`, self-serve | **NSE riskier, unless A5 resolves favourably** |

**"A ring that usually works is not a phone"** — agreed, and the honest answer is that the NSE path's one real reliability deficit is **not stochastic, it is a permission dependency**. That is a materially better kind of problem than a flaky one: it is deterministic, detectable on-device (the app can read its own notification authorisation status), and therefore **recoverable by telling the user** — "calls are off because notifications are off" — rather than failing invisibly. Whether that is acceptable is a product call, not a research finding. `[inferred]`

---

## What the follow-up could not establish

- Whether `reportNewIncomingVoIPPushPayload` actually requires the filtering entitlement. **Apple's docs and Apple's staff say opposite things.** Resolvable in an afternoon on a device; nothing further can be learned from the literature.
- Any measured NSE invocation latency, or any alert-push→CallKit vs PushKit comparison. Searched twice, widened, still nothing.
- The request form's own text and criteria (Apple ID auth-gated).
- Any public report of the filtering entitlement being **granted**, for any category.
- Whether the entitlements team's "use PushKit" rejection is a standing policy or one reviewer's call — n=1 applicant, n=2 rejections.
- Whether Low Power Mode affects NSE execution for visible alert pushes.
- What Element/Matrix iOS ultimately shipped: issue #2714 explores NSE as "the most serious alternative" and names the 30s window and the degraded-title failure mode, but the page carries no resolution. `[secondary: https://github.com/element-hq/element-ios/issues/2714]`

---

# Follow-up 2: simulator NSE viability

*Appended 2026-09-11. Nothing above this line was modified.*

## Answer to the question that actually matters

> **Is the null result explained by the instrument, or is it evidence?**

**Explained by the instrument. The harness is sound, the payload was correct, and the observation carries no information about the entitlement.** Apple documents this exact limitation in its own release notes.

`simctl push` **cannot** invoke a Notification Service Extension. It never could. `mutable-content` is not honoured by the local-simulation path at all — so `didReceive` not firing is the documented behaviour of the tool, not a fact about the extension, the entitlement, or the payload.

**And there is a working simulator route** that Apple explicitly says *does* support NSEs — see Q2. It may save the device session for the entitlement question.

## Q1 — Does `xcrun simctl push` invoke an NSE?

**No. Apple states it directly, twice.**

**Xcode 11.4 Release Notes, Known Issues** — the feature's introduction, and the limitation is called out in the same release:

> "**Notification Service Extensions do not work in simulated push notifications. The `mutable-content` key is not honored.** (55822721)"
> `[verified: https://developer.apple.com/documentation/xcode-release-notes/xcode-11_4-release-notes — retrieved via developer.apple.com's JSON API; the HTML is JS-rendered and returns only a title to a plain fetch]`

**Xcode 14 Release Notes** — confirms it obliquely but unambiguously, by contrast:

> "**Remote Notifications support more features (like Notification Service Extensions) than locally simulated notifications using `.apns` payload files or the `simctl` push command.**"
> `[verified: https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes — same JSON API]`

Note the phrasing of that second quote carefully: it groups **`.apns` drag-and-drop and `simctl push` together** as "locally simulated notifications", and names **Notification Service Extensions** as a specific example of what they do *not* support. `[verified: same]`

**Your suspicion was right** — local simulation injects a notification without running the mutable-content pipeline. It is now `[verified]`, not `[inferred]`, and you were right not to bank it.

## Q2 — Is there ANY way to exercise an NSE on the simulator?

**Yes — real APNs delivery to a simulator, added in Xcode 14. Apple names NSE support as the reason it is better than local simulation.**

> "Simulator now supports remote notifications in iOS 16 when running in macOS 13 on Mac computers with Apple silicon or T2 processors. Simulator supports the Apple Push Notification Service Sandbox environment. **Your server can send a remote notification to your app running in that simulator by connecting to the APNS Sandbox (api.sandbox.push.apple.com).** Each simulator generates registration tokens unique to the combination of that simulator and the Mac hardware it's running on."
> `[verified: https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes]`

Preconditions, all from the same primary source plus one widely-reported constraint:

| Requirement | Source |
|---|---|
| macOS 13+ host | `[verified: Xcode 14 release notes]` |
| Mac with **Apple silicon or T2** | `[verified: same]` |
| iOS 16+ simulator runtime | `[verified: same]` |
| **APNs Sandbox** (`api.sandbox.push.apple.com`), not production | `[verified: same]` |
| **Debug build** targeting the sandbox environment; "attempting otherwise will fail to register or receive push notifications" | `[secondary: https://notificare.com/blog/2022/10/07/testing-push-notifications-ios-simulator-in-2022/]` |
| The app must actually **register** and receive a device token — the simulator mints one | `[verified: Xcode 14 release notes]` |

Also flagged by Apple, and easy to trip over: "**Device Registration Tokens are of variable length.** Tokens in Simulator may be larger than current physical device tokens. Don't hardcode any specific length or format for these tokens. (60974170)" `[verified: same]`

**On the drag-and-drop `.apns` file specifically (you asked whether it differs):** it does **not** differ. Apple's own sentence puts `.apns` payload files and `simctl push` in the same bucket as "locally simulated notifications". `[verified: Xcode 14 release notes]` Do not spend time on it.

**NOT FOUND:** any documented way to make the extension run by launching the extension scheme directly and attaching. I found no source describing that as a working route for an NSE, and no local-push-provider trick that bypasses the mutable-content limitation.

**Your harness needs one change, not a rewrite** `[inferred]`: swap `simctl push` for a real APNs Sandbox push to the token the simulator hands you. Everything else you built — the extension, the branch logging, the positive controls — stays.

## Q3 — Was the payload missing something?

**No. Your payload was correct.** For a *real* push, Apple's requirements are exactly the two things you had:

> "The system executes your notification service app extension only when a remote notification's payload contains the following information: The payload must include the `mutable-content` key with a value of `1`. The payload must include an `alert` dictionary with title, subtitle, or body information."
> `[verified: https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications]`

No `category`, no `interruption-level`, no special `apns-push-type` is required to make the extension run. (`apns-push-type: alert` *is* required to later **silence** the notification `[verified: /documentation/bundleresources/entitlements/com.apple.developer.usernotifications.filtering]`, but that is a different step and not why `didReceive` was silent.)

**There was nothing to fix in the payload.** The `mutable-content` key was simply not read by the tool you sent it with. `[verified: Xcode 11.4 release notes]`

## Q4 — Does CallKit / `reportNewIncomingVoIPPushPayload` work on the simulator?

**Contested, and I am not going to give you the tidy answer the blogs give.**

The widely-repeated claim is blanket: "the simulator does not support PushKit or CallKit's full telephony features", "CallKit won't work on your simulator." `[secondary: https://www.videosdk.live/developer-hub/voip/ios-voip-callkit]` `[secondary: https://connectycube.com/2025/11/06/troubleshooting-common-issues-with-voip-push-notifications-on-ios/]`

**But the primary evidence does not support a blanket reading:**

- CallKit's declared platforms carry **no simulator-unavailable marker**, and `reportNewIncomingCall` is listed as available from iOS 10.0 with no simulator caveat in its Discussion. `[verified: developer.apple.com JSON API, /documentation/callkit and /documentation/callkit/cxprovider/reportnewincomingcall(with:update:completion:)]` Apple's docs do not, as a rule, mark simulator gaps — so this is weak evidence, and I am flagging it as such rather than leaning on it. `[inferred]`
- More usefully: a forum thread reporting that CallKit's `didActivateAudioSession` is *not* called on the iOS 16 simulator lists CallKit as **working** on the iOS 15.2 simulator and under Xcode 13.2.1, and failing only on iOS 16 / Xcode 14 beta. `[secondary: https://developer.apple.com/forums/thread/711956]` **A regression report of one callback presupposes the rest of the flow ran.** That is inconsistent with "CallKit does not work on the simulator" and consistent with "the audio path is the broken part." `[inferred]`

**NOT FOUND:** any Apple statement — documentation, release note, or DTS reply — saying whether CallKit or `reportNewIncomingVoIPPushPayload` is supported on the simulator. **NOT FOUND:** anyone who has specifically tested `reportNewIncomingVoIPPushPayload` on a simulator and reported the result.

**Why this may not block you anyway** `[inferred]`: the A5 experiment does not need a *rendered ring*. It needs the **completion handler's error value** — specifically whether it is `missingNotificationFilteringEntitlement`. That is an entitlement check, and there is no reason to expect it to depend on telephony hardware. If the NSE runs at all under a real APNs push, you can likely read that error on the simulator even if no call UI ever draws. **That is a hypothesis, not a finding** — but it is cheap to test, and it is the whole question.

The parts most likely to genuinely require a handset are the ones you would want the handset for regardless: audio, the lock-screen ring UI, ring-from-cold-start latency, and behaviour under Focus/Do Not Disturb. `[inferred]`

## Bottom line for the device session

**Do not read your null result as evidence about the entitlement. It is a fact about `simctl push`.** `[verified: Xcode 11.4 release notes]` Had you carried it forward, the device test would have been read against a false prior — which is exactly the failure you were trying to head off.

**Cheapest next step, before booking anyone's afternoon** `[inferred]`: re-point the existing harness at a real APNs Sandbox push to the simulator's own token (Xcode 14+ / macOS 13+ / Apple silicon or T2 / iOS 16+ sim / debug build). Apple explicitly says that path supports Notification Service Extensions. Two outcomes, both worth having:

- **`didReceive` fires** → the harness is proven live, and you can immediately read the `reportNewIncomingVoIPPushPayload` completion handler to settle A5 (docs vs Apple staff) — possibly without a handset at all.
- **`didReceive` still does not fire** → *now* you have a real anomaly, on a path Apple documents as supporting NSEs, and the device session is unambiguously justified.

**One precondition I cannot check for you:** the Apple-silicon-or-T2 requirement is a property of your Mac, not of the project. If the host does not qualify, this route is closed and the handset is the only option. `[verified requirement: Xcode 14 release notes]`

## What Follow-up 2 could not establish

- Whether `reportNewIncomingVoIPPushPayload` functions on a simulator. No Apple statement, no public test report.
- Whether CallKit is *officially* supported on the simulator — the blanket "no" is secondary and contradicted by a regression report that assumes it works.
- Any route to invoking an NSE via the extension scheme, attaching a debugger, or a local push provider.
- Whether the iOS 16 simulator `didActivateAudioSession` regression `[secondary: https://developer.apple.com/forums/thread/711956]` persists under current toolchains.

---

# RESOLUTION — measured, 2026-09-11 08:30 AEST

**The docs/staff contradiction in "Follow-up: entitlement and latency" (A5) is SETTLED. The docs are right. The entitlement is required to CALL the method, not merely to silence the notification.**

## Method

A throwaway app + Notification Service Extension (`/tmp/nse-entitlement-spike`, xcodegen), iPhone 15 Pro simulator, iOS 26 toolchain, Apple M1 Max / macOS 26.6.2. The **NSE carries no entitlements of any kind** — verified with `codesign -d --entitlements`. The app carries only `aps-environment: development`, needed to mint a token.

Delivered by **real APNs Sandbox push** (`api.sandbox.push.apple.com`) to the simulator's own token, per the Xcode 14 route — not `simctl push`, which Apple's own release notes say does not honour `mutable-content`.

## Controls, all passing before the result was read

| Control | Reading |
|---|---|
| APNs accepted the push | `HTTP/2 200`, `apns-id: 7DCA7ECC-…` |
| Extension actually ran | `[NSE-SPIKE] didReceive FIRED — extension is running` |
| Logging pipeline works | app-side `NSLog` lines visible throughout |
| Notification authorization | `authorizationStatus=3`, `alertSetting=1` (provisional, granted with no dialog) |
| NSE entitlements | none — the absence IS the experiment |
| Provider key correct | 64-zero-hex probe → `400 BadDeviceToken` (key valid); the other key → `403 InvalidProviderToken` |

## Result

```
[NSE-SPIKE] RESULT=ERROR
  domain=com.apple.CallKit.error.notificationserviceextension
  code=2
```

From `iPhoneOS26.5.sdk/…/CallKit.framework/Headers/CXError.h`, read on disk, not inferred:

```c
CXErrorCodeNotificationServiceExtensionErrorUnknown = 0,
CXErrorCodeNotificationServiceExtensionErrorInvalidClientProcess = 1,
CXErrorCodeNotificationServiceExtensionErrorMissingNotificationFilteringEntitlement = 2,
```

**Code 2 is exactly the missing-entitlement case the documentation predicts.** The Apple engineer's forum claim that *"use of `reportNewIncomingVoIPPushPayload()` does not depend on the filtering entitlement"* is **refuted by measurement**.

## Consequence

The NSE path is **closed** for this project, and closed by evidence rather than by argument:

1. The entitlement is required to call the method at all.
2. It is Apple-granted, and an applicant fitting Apple's stated rationale *exactly* — an E2EE messenger whose server genuinely could not distinguish a call from a message — was rejected twice, told *"Support for VoIP calls should be provided by PushKit."*
3. This project's case is strictly weaker: its server **can** tell it is a call, and its media is not end-to-end encrypted.

MLS would not rescue it. Even with E2EE messaging the entitlement remains the binding constraint, and the perfect-fit applicant was refused.

## The trap that was avoided

The first run used `simctl push` and produced silence. Read as a result it would have said *"no entitlement needed"* — right conclusion, wrong reason — and the follow-on device test would have failed identically for the same unexamined reason, with that failure then read as *"the entitlement is required"*. Two wrong readings, one of which would have been banked as evidence.

What separated them was a positive control: **`didReceive FIRED` proves the extension ran, so its verdict is about the entitlement and nothing else.** Apple documents the `simctl push` limitation in the Xcode 11.4 release notes.
