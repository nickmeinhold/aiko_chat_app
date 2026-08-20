# HEAT — Research brief: federated key-anchored identity & passkey custody

> Crucible phase: HEAT (deep research). This document gathers **ground-truth mechanisms and
> failure modes** from real systems. It does **not** design or recommend — the KEY-vs-HOME fork is
> resolved downstream. Every non-obvious claim carries a URL. Where a source could not be verified,
> it says so.
>
> **The fork under study:** is a user's identity anchored to their **KEY** (you exist everywhere;
> islands are venues you visit) or to their **HOME island** (`@you:island`; the island dies → the
> identity dies)? Aiko leans key-anchored (Ed25519, passkeys as sole ingress). The systems below
> have each already picked a corner and lived with the consequences.

---

## 1. Bluesky / AT Protocol — `did:plc` decouples identity from the host

AT Protocol splits the persistent account identifier (a **DID**) from the mutable hosting server (a
**PDS**, Personal Data Server). The DID is the durable "you"; the PDS is just where your repo
currently lives. atproto blesses exactly two DID methods: **`did:plc`** (self-authenticating,
default for new accounts) and **`did:web`** (hostname-based, "an independent alternative")
([atproto.com/specs/did](https://atproto.com/specs/did)).

The resolved DID document holds three things that matter here
([atproto.com/specs/did](https://atproto.com/specs/did)):
- a **signing key** (`verificationMethod` id `#atproto`, type `Multikey`) — signs repo commits;
- a **PDS service endpoint** (`service` id `#atproto_pds`) — the HTTPS URL of the host;
- a **handle claim** (`alsoKnownAs`, `at://…`) — the human-readable name, which is *not* the identity.

**`did:plc` mechanism.** PLC = "Public Ledger of Credentials." The DID string is the **hash of the
genesis operation** — `did:plc:ewvi7nxzyoun6zhxrhs64oiz` is literally derived from the first signed
op, so it is self-certifying and cannot be forged
([did-method-plc](https://github.com/did-method-plc/did-method-plc)). Each identity is an **append-only,
hash-linked operation log**, "each operation referencing a prior version of the identity state by
hash." A **central directory server** "collects and validates operations, and maintains a
transparent log of operations for each DID" (ibid).

**Rotation key vs signing key — the crucial split.** Control over the identity "rests in a set of
reconfigurable **rotation keys**" ([did-method-plc](https://github.com/did-method-plc/did-method-plc)).
Rotation keys authorize *changes to the identity itself* (including swapping the PDS endpoint or
rotating the signing key). The signing key only signs data. This separation is what lets you fire
your host: even if the PDS goes rogue or dies, whoever holds a rotation key can re-point the DID.
atproto recommends users "include a **self-controlled PLC rotation key**" so identity updates don't
depend on the original PDS ([account-migration](https://atproto.com/guides/account-migration)).

**Migration without losing identity** ([account-migration](https://atproto.com/guides/account-migration)):
1. Get a service-auth token from the old PDS; `createAccount` on the new one (starts *deactivated*).
2. Transfer repo, blobs, preferences (`com.atproto.repo.importRepo` etc.).
3. **Fetch recommended DID credentials, submit a signed PLC operation** re-pointing the DID doc at the
   new PDS.
4. Activate on new, deactivate on old. **"The DID itself never changes — only which PDS hosts it."**

**Centralization critique.** The PLC directory is a single trusted operator (Bluesky PBC). It is
self-certifying (it can't silently forge history — the log is hash-linked and signed) but it *can*
censor, go offline, or be compelled, and it is the resolution bottleneck. The maintainers concede
this, expecting to "evolve the system (in a backwards-compatible manner) into something less
centralized — likely a permissioned DID consortium"
([did-method-plc](https://github.com/did-method-plc/did-method-plc)). So today PLC buys sovereignty
*from your host* by introducing a dependency *on the directory*.

**`did:web` and its sovereignty cost.** `did:web` maps the identifier to a hostname and serves the
DID doc from `https://<host>/.well-known/did.json` ([atproto.com/specs/did](https://atproto.com/specs/did)).
It removes the central directory — but re-anchors identity to **DNS + TLS + continuous hosting
control**. Lose the domain (lapsed registration, seizure, provider ban) and the identity is gone;
there is no hash-derived self-certification and no rotation-key recovery path independent of the
domain. It trades one custodian (PLC) for another (your registrar/CA).

- **Mechanism summary:**
  - DID = durable identity; PDS = swappable host; handle = mutable label, never the anchor.
  - `did:plc` DID = hash of a signed genesis op → self-certifying, host-independent.
  - **Rotation keys** (govern identity/host changes) are separate from **signing keys** (sign data).
  - Migration = signed PLC op re-pointing the DID doc; DID constant throughout.
  - PLC directory is centralized (censor/offline risk) but hash-linked/tamper-evident.
  - `did:web` removes the directory but re-couples to DNS/TLS/domain custody.
- **Relevance to a key-anchored chat app:** this is the reference design for "island is a venue, not
  the identity" — but note it did **not** anchor purely to a key; it anchors to a
  **rotation-key-governed record in a directory**, precisely to get recoverability that a raw key
  can't give.

---

## 2. Nostr — pure key-anchoring, and the rotation problem it can't solve

Nostr is the maximal version of the KEY corner: your identity **is** your secp256k1 public key
(`npub…`). Relays are pure dumb pipes — they store and forward signed events and hold **no identity
state whatsoever**; you can post the same signed events to any relay, and switching relays changes
nothing about who you are. There is no account, no home server, no registration.

**NIP-05 (DNS-based identifier, not verification).** A user puts `"nip05": "bob@example.com"` in
their profile; clients GET `https://example.com/.well-known/nostr.json?name=bob` and check the
returned pubkey matches ([NIP-05](https://github.com/nostr-protocol/nips/blob/master/05.md)). The
spec is explicit that this is **identification, not verification**: *"The NIP-05 is not intended to
verify a user, but only to identify them… for the purpose of facilitating the exchange of a contact
or their search."* Critically: *"Clients must always follow public keys, not NIP-05 addresses"* — so
a domain takeover can steal your *name* but never your *identity*. The human-readable handle is a
soft pointer layered on top of the key, never the anchor. (This is the inverse of Matrix, §3.)

**NIP-26 (delegated event signing — discouraged).** Lets a delegator sign a delegation token
(a Schnorr sig over `nostr:delegation:<delegatee-pubkey>:<conditions>`) so a secondary key can
publish events attributed to the root pubkey, optionally scoped by `kind` and `created_at`
([NIP-26](https://github.com/nostr-protocol/nips/blob/master/26.md)). It was the closest Nostr came
to a "hot key / cold key" story. It is now flagged **`unrecommended`** at the top of the spec:
*"adds unnecessary burden for little gain"* (ibid). So Nostr tried and largely abandoned the
delegation approach that could have softened key loss.

**The unsolved problem: key rotation / key loss.** Because identity *is* the key, there is **no
protocol-level way to rotate a compromised key or recover a lost one** while keeping your identity,
followers, and history. If your `nsec` leaks, an attacker is indistinguishable from you forever; if
you lose it, you are a new person and must rebuild your social graph from zero. There is no
directory op (unlike PLC §1), no sigchain re-key (unlike Keybase §5), no server-mediated reset. This
is widely regarded as pure key-anchoring's **fatal UX flaw** — the whole burden of an unrecoverable
bearer secret lands on ordinary users. (Proposals like NIP-41 "key invalidation/migration" exist but
are not standardized/adopted; unverified here — treat as open, not solved.)

- **Mechanism summary:**
  - Identity = pubkey; relays store zero identity state (pure venues).
  - NIP-05 = DNS handle for *discovery*, explicitly not the anchor; clients follow the key.
  - NIP-26 delegation existed but is now `unrecommended`.
  - No rotation, no recovery: key compromise = permanent impersonation; key loss = new person.
- **Relevance to a key-anchored chat app:** Nostr is the pure-KEY end state Aiko is closest to, and
  its live wound is exactly the one Aiko must pre-solve: **rotation and recovery are not free — a raw
  key with no recovery envelope is a UX cliff, not a feature.**

---

## 3. Matrix — `@user:homeserver` is welded to the host, and unwelding it is a decade-long saga

Matrix chose the HOME corner and has been trying to escape it ever since. A Matrix ID is
`@localpart:homeserver.tld`. The homeserver name is **baked into the MXID string itself**, and that
MXID is **embedded in every event** the user ever sends (membership, messages, state), signed by the
homeserver. Because history is an event DAG stamped with server-scoped IDs, you cannot move to a new
server without either (a) changing your MXID (becoming a new person) or (b) rewriting/relinking all
prior events. The homeserver is not a venue — it is your namespace, your signer, and your address of
record simultaneously.

**The unwelding efforts (all long-running, none shipped as GA account portability):**
- **MSC1228** ("removing MXIDs from events") — the seminal proposal to stop embedding server-scoped
  MXIDs in events so identity can detach from the homeserver. *(Direct spec-repo fetch 404'd on the
  URLs tried — the MSC has been renumbered/relocated across the repo's history; treat the title/intent
  as reported, not quoted from source.)*
- **MSC2787** — "Portable Identities," proposing DIDs as portable identifiers
  ([HN discussion](https://news.ycombinator.com/item?id=39278695);
  [orionwl toot](https://x0f.org/@orionwl/105683910322992403)).
- **Pseudonymous identities** — replacing MXIDs with pseudonyms so identifiable info (e.g. a legal
  name in an MXID) stops leaking over federation
  ([Matrix Foundation toot](https://mastodon.matrix.org/@matrix/110357251798241306)).
- **Cryptographic identities / CryptoIDs** — the current direction: switch user IDs to **public keys**
  (MSC4243) with **client-owned identities** (MSC4080) as "the cornerstone of mainstream account
  portability." Per community reporting, **account-portability work was paused as of early 2024**,
  expected to return ([TWIM 2024-01-05](https://matrix.org/blog/2024/01/05/this-week-in-matrix-2024-01-05/)).
  *(MSC4080/4243 numbers reported via search summaries, not fetched from source — flag as unverified.)*
- **P2P Matrix** — running homeservers embedded in clients so "your server" travels with you; long a
  research track, not a shipped product path.

**Why it's a decade-long unfinished migration.** Every event in the federation is signed with the
server-scoped MXID, so portable identity is not a new-accounts feature — it's a **retroactive
re-architecture of the event format, the signing model, and every deployed homeserver and client at
once**. The install base that made Matrix valuable is the same install base that makes the change
nearly impossible to land without breaking federation. Choosing HOME was cheap on day one and has
cost ~10 years of unfinished work.

- **Mechanism summary:**
  - MXID `@user:homeserver` hard-codes the host into the identifier and into every signed event.
  - Moving hosts ⇒ new MXID (new person) or rewrite all history ⇒ practically impossible.
  - MSC1228 → MSC2787 → pseudonymous IDs → CryptoIDs (MSC4080/4243, keys-as-IDs) — a migration *toward*
    key-anchoring, paused early 2024.
- **Relevance to a key-anchored chat app:** Matrix is the cautionary tale for the HOME corner. The
  server-in-the-name decision is the cheap default that becomes structurally unpayable at scale — and
  the escape route they are now cutting is *toward* keys-as-identity, i.e. toward where Aiko already
  is. Do not put the island in the identifier.

---

## 4. FIDO2 / WebAuthn — synced vs device-bound passkey custody

**Definitions** ([W3C WebAuthn L3](https://www.w3.org/TR/webauthn-3/)):
- **Multi-device credential (synced / "passkey")** — a credential source whose private key **can** be
  copied/synced across devices by the authenticator (iCloud Keychain, Google Password Manager). The
  spec: "A **backup eligible** public key credential source is referred to as a **multi-device
  credential**."
- **Single-device credential (device-bound)** — "one that is not backup eligible." The key never
  leaves the authenticator; if the device is lost, the credential is gone.

**Which `authenticatorSelection` fields control this** ([W3C WebAuthn L3](https://www.w3.org/TR/webauthn-3/)):
- **`residentKey` / `requireResidentKey`** — control whether the credential is **discoverable**
  (client-side resident). "Historically, client-side discoverable credentials have been known as
  resident credentials or resident keys." Discoverability enables usernameless login; it is
  **orthogonal to** whether the credential syncs.
- **`authenticatorAttachment`** — `"platform"` (built into the device) vs `"cross-platform"` (roaming,
  e.g. a security key). This selects *where* the authenticator lives, and is the closest lever an RP
  has, but it still does **not** dictate sync behavior of a platform authenticator.

**Can an RP force device-bound? No — not on modern platform authenticators.** Backup eligibility is
set **by the authenticator at creation time, and is permanent for that credential** — "Backup
eligible is a credential property and is **permanent** for a given public key credential source"
([W3C WebAuthn L3](https://www.w3.org/TR/webauthn-3/)). The RP does not get a "must not sync" knob.
On iOS/Android, **platform passkeys sync regardless** of RP preference; Apple's implementation
doesn't even support attestation, "prioritizing user privacy," so the RP can't reliably distinguish
or constrain hardware either
([Corbado](https://www.corbado.com/blog/passkey-providers/why-some-platforms-do-not-support-attestation-for-passkeys)).
The only genuine routes to device-bound are (a) require a **cross-platform/roaming** authenticator
(security key), or (b) request the **`devicePubKey` (Device-bound Public Key) extension**, where
Android returns a *second* device-bound signature alongside the synced passkey — a supplementary
signal, not a way to stop the passkey syncing
([Corbado](https://www.corbado.com/blog/passkey-providers/why-some-platforms-do-not-support-attestation-for-passkeys)).

**How an RP reads synced vs device-bound: the BE/BS flags in authenticator data**
([W3C WebAuthn L3](https://www.w3.org/TR/webauthn-3/)):
- **BE (Backup Eligibility)** — *can* this credential be backed up/synced. Permanent per credential.
- **BS (Backup State)** — *is* it currently backed up/synced. Can change over time.
- Reading them: **BE=1, BS=1** ⇒ multi-device / synced; **BE=1, BS=0** ⇒ syncable but not yet synced;
  **BE=0 (⇒ BS=0)** ⇒ device-bound, single-device. These bits are present on **every** assertion's
  authenticator data, so the RP can observe custody at each ceremony — but only observe, not dictate.

- **Mechanism summary:**
  - Synced (multi-device) ⇔ **backup-eligible**; device-bound ⇔ not backup-eligible; set by the
    authenticator at creation, **permanent**.
  - `residentKey` = discoverability (usernameless), *not* sync. `authenticatorAttachment` =
    platform vs roaming.
  - RP **cannot** force a platform passkey to be device-bound; platform passkeys sync anyway.
  - RP **reads** custody via **BE/BS** flags (observe-only); force device-bound ⇒ demand a roaming
    authenticator or use `devicePubKey` for a supplementary bound signature.
- **Relevance to a key-anchored chat app:** if passkeys are the sole ingress, the app must assume the
  passkey is **synced and outside its control** (BE=1). It can *detect* device-bound vs synced via
  BE/BS but cannot *mandate* device-bound without pushing users to hardware keys. The passkey is a
  custody mechanism for *an authenticator secret*, not for the Ed25519 identity key — the two must be
  designed as separate layers (see Synthesis).

---

## 5. Key rotation / recovery patterns for sovereign identity

**Bluesky (rotation keys).** New device / lost signing key: sign a **PLC operation with a rotation
key** to install a new signing key and/or re-point the PDS; the DID (identity) is untouched
([account-migration](https://atproto.com/guides/account-migration)). Recovery hinges on **still
holding a rotation key** (self-custodied or held by the PDS). There is also a time-boxed recovery
window on rotation-key changes in the PLC design (unverified specifics here). Corner picked:
**recoverable + sovereign-ish**, at the cost of **simplicity** (users must understand two key classes
and a directory).

**Keybase (device keys + paper key + sigchain).** Each device has its own keypair; **public halves
are published in the user's append-only sigchain, private halves never leave the device**
([Keybase Book](https://book.keybase.io/account)). Adding a device requires an existing device or a
**paper key** to countersign the new key into the sigchain; revoking a lost device rolls a new
**Per-User Key (PUK)** to the survivors ([Keybase PUK docs](https://book.keybase.io/docs/teams/puk)).
Recovery = any surviving device or paper key. **If you lose all devices and all paper keys, the
account is unrecoverable** ([Keybase Book](https://book.keybase.io/account);
[jms1 lost-access notes](https://jms1.info/keybase/lost.html)). Corner: **sovereign + recoverable**
via a *quorum-of-your-own-devices* sigchain, at the cost of **simplicity** (users must provision and
safeguard paper keys ahead of loss).

**Signal (no cross-device identity portability; safety-number reset).** Signal's identity key is tied
to the install. An **official device transfer or a linked-device change keeps the key material**, so
**safety numbers don't change** — identity persists across that path
([Signal support](https://support.signal.org/hc/en-us/articles/360007060632)). But a fresh
**reinstall on an unlinked device generates a new identity key ⇒ the safety number changes** and
contacts are warned
([BleepingComputer](https://www.bleepingcomputer.com/news/security/signal-app-safety-numbers-do-not-always-change-heres-why/)).
There is no user-facing key portability across a lost primary with no transfer — you come back as a
re-keyed identity and re-verify with every contact. Corner: **simplicity + sovereignty** (no central
identity custodian, dead-simple UX), at the cost of **recoverability** (lose the primary without a
transfer and your cryptographic identity resets).

**The recovery trilemma — sovereignty / recoverability / simplicity, pick 2** (framing, not a cited
theorem):
- **Nostr** → sovereignty + simplicity; **sacrifices recoverability** (lost key = new person).
- **Signal** → simplicity + sovereignty; **sacrifices recoverability** across an untransferred loss.
- **Keybase** → sovereignty + recoverability; **sacrifices simplicity** (paper keys, sigchain,
  pre-provisioning).
- **Bluesky/PLC** → recoverability + (partial) sovereignty; **sacrifices simplicity** *and* leans on a
  directory — arguably buying recoverability by softening pure sovereignty.
- **Matrix (HOME)** → recoverability + simplicity (server resets your password); **sacrifices
  sovereignty** (the homeserver owns you).

- **Relevance to a key-anchored chat app:** every sovereign system that made recovery *usable* did it
  by adding a **second key class or a quorum** (rotation keys, device+paper sigchains) — never by
  making the one identity key recoverable directly. Aiko's recovery story is a design choice about
  *which corner to sacrifice*, and "pure key, no envelope" silently picks Nostr's corner (loses
  recoverability) whether or not that was intended.

---

## Synthesis: what the real systems teach about the KEY-vs-HOME fork

1. **HOME is the cheap default that becomes structurally unpayable.** Matrix welded the server into the
   identifier and into every signed event; a decade of MSCs (1228 → 2787 → pseudonymous → CryptoIDs)
   has not fully un-welded it. If the island appears in the identifier, you inherit this debt. **Do not
   put the island in the identity string.**

2. **Nobody who escaped HOME anchored to a raw key alone.** Bluesky anchors to a *rotation-key-governed
   record*; Matrix's escape route (CryptoIDs) pairs keys with client-owned identity + recovery
   thinking. Pure raw-key anchoring is *only* fully embraced by Nostr — and Nostr's key-loss problem is
   its most-cited wound. Key-anchored ≠ single-key.

3. **Separate the "identity-governing" key from the "data-signing" key.** PLC's rotation-vs-signing
   split, and Keybase's per-device-key-under-a-sigchain, both exist specifically so a compromised or
   lost *operational* key doesn't destroy the *identity*. A design with one Ed25519 key doing both
   jobs has no recovery surface.

4. **Passkeys are custody for an authenticator secret, not for your identity key — and they sync
   outside your control.** BE=1 platform passkeys are copied across a user's devices by the OS
   (WebAuthn L3); an RP can *read* BE/BS but cannot *force* device-bound without pushing users to
   hardware keys. So a passkey is a fine *login gesture / recovery factor*, but binding the sovereign
   Ed25519 key's fate to a single passkey conflates two custody models.

5. **Handles must be soft pointers, never anchors.** Nostr's NIP-05 nails this: the DNS name aids
   discovery, but "clients must always follow public keys." Bluesky agrees (handle in `alsoKnownAs`,
   not the DID). A domain/island takeover should be able to steal a *name*, never the *identity*.

6. **A directory buys recoverability at the price of a new centralization.** PLC gives migration and
   rotation that Nostr can't — but reintroduces a trusted operator the maintainers themselves want to
   decentralize. `did:web` removes the directory but re-couples identity to DNS/TLS/domain custody.
   There is no free recoverability; pick the custodian consciously.

7. **The recovery trilemma is the real decision, and "pure key" silently picks Nostr's corner.**
   Sovereignty / recoverability / simplicity — pick 2. Every usable-recovery sovereign system spent its
   third budget on a *second key class or a device quorum*. If Aiko ships one unrecoverable key, it has
   chosen to sacrifice recoverability by default — that should be a deliberate, named choice, not an
   emergent one.

8. **Migration is a signed pointer-update, not a data-move — if the anchor is right.** Bluesky's
   whole migration is "sign an op that re-points the DID; the DID never changes." That elegance is
   *available only because identity was never the host.* Getting the anchor right up front is what makes
   "island dies → you survive, just re-point" a one-operation event instead of a decade-long re-architecture.

---

### Source ledger
- AT Proto DID spec — https://atproto.com/specs/did
- did:plc method spec — https://github.com/did-method-plc/did-method-plc
- AT Proto account migration — https://atproto.com/guides/account-migration
- Nostr NIP-05 — https://github.com/nostr-protocol/nips/blob/master/05.md
- Nostr NIP-26 — https://github.com/nostr-protocol/nips/blob/master/26.md
- W3C WebAuthn Level 3 — https://www.w3.org/TR/webauthn-3/
- Corbado, passkey attestation / device-bound — https://www.corbado.com/blog/passkey-providers/why-some-platforms-do-not-support-attestation-for-passkeys
- Matrix TWIM 2024-01-05 (portability paused) — https://matrix.org/blog/2024/01/05/this-week-in-matrix-2024-01-05/
- Matrix Foundation, pseudonymous identities — https://mastodon.matrix.org/@matrix/110357251798241306
- MSC2787 discussion — https://news.ycombinator.com/item?id=39278695 ; https://x0f.org/@orionwl/105683910322992403
- Keybase account/sigchain — https://book.keybase.io/account ; PUK — https://book.keybase.io/docs/teams/puk ; lost access — https://jms1.info/keybase/lost.html
- Signal safety numbers — https://support.signal.org/hc/en-us/articles/360007060632 ; https://www.bleepingcomputer.com/news/security/signal-app-safety-numbers-do-not-always-change-heres-why/

### Verification caveats (unverified / could not fetch from primary source)
- **MSC1228** direct spec-repo fetch returned 404 on the URLs tried (renumbered/relocated in repo
  history); title and intent reported from secondary context, not quoted from source.
- **MSC4080 / MSC4243** (CryptoIDs / keys-as-user-IDs) numbers come from search-result summaries, not a
  fetched MSC document — treat as directionally correct but unverified.
- **Nostr NIP-41** (key invalidation/migration) mentioned as an *existing but non-adopted* proposal;
  not fetched/verified — treat the "rotation is unsolved" claim as the robust one.
- **Bluesky PLC rotation recovery window** (time-boxed rotation-key change) referenced from general
  knowledge; specific window/behavior not verified against the spec text here.
