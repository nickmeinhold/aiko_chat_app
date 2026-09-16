# 🜂 RESEARCH — key backup, known-keys sets, and the rotation link

> Movement 2 (Heat) of the `/crucible` forge run on `key-backup-and-known-keys`.
> Input: `CRUCIBLE.md` (Ore, movement 1). Output consumed by Spark and Cast.
>
> **This document does not design anything for aiko.** It reports what is known,
> separated from what is guessed. Read `CRUCIBLE.md` first — its measured facts
> about this repo are not repeated here.

## How to read the marks

Every claim carries one of:

- **[V] VERIFIED** — a primary source was read directly (spec text, source file,
  RFC, man page, live experiment). The URL is given and the load-bearing sentence
  is quoted rather than paraphrased.
- **[R] REPORTED** — a secondary source (blog, news, community post, vendor
  marketing). Believable, not verified.
- **[U] UNCERTAIN** — could not confirm. Named as a gap rather than filled in.

Where a system's status may have moved, this document says **what was actually
read and when**. All statuses were read **2026-09-16** unless stated.

**A note on negatives.** Several load-bearing findings here are negatives ("no
such mechanism exists"). Each one names the instrument and its coverage, because
a negative verified in the wrong artifact travels further than an unverified one.

---

# Q1 — THE FALSIFIER

> *Is a self-signed key-succession attestation useful WITHOUT a server/registry
> to distribute it?*

## The answer in one sentence

**Every succession scheme surveyed verifies its signatures offline; not one of
them can establish *ordering* or *completeness* offline — and the registry, in
every system that has one, exists for exactly and only those two properties.**

This is not a close call. Four independent ecosystems reached it by four
different routes, and two of them say so in their own specs.

## The decomposition the falsifier was missing

`CRUCIBLE.md`'s falsifier #1 reads: *"A self-signed new-key attestation is
worthless to a third party without an island-side registry to distribute it."*

The research says that sentence conflates three separable questions. A relying
party asking *"should I accept key K₂ as a successor to K₁?"* needs three
distinct things, and they have three different homes:

| Property | What it answers | Can a signature carry it? | Who supplies it in practice |
|---|---|---|---|
| **Authenticity** | "did K₁ really sign this?" | **YES** | the artifact itself, offline |
| **Ordering** | "which competing claim came first?" | **no** | a log, a timestamp anchor, or a wait |
| **Completeness** | "is there an *earlier* claim I haven't seen?" | **no** | a registry, a cartel, or the social graph |

A registry is never needed for authenticity. It is *always* needed for
completeness — and **completeness is a claim about absence, which no signature
can ever make.**

### The primary sources that state this directly

**did:plc (Bluesky) — shipped, live, and explicit.** [V]
https://github.com/did-method-plc/did-method-plc — the spec's own §"PLC Server
Trust Model":

> "The operation log is **self-certifying**, and contains all the information
> needed to construct (or verify) the current state of the DID document.
>
> **Some trust is required in the PLC server. Its attacks are limited to:**
> - **Denial of service**: rejecting valid operations, or refusing to serve some
>   information about the DID
> - **Misordering**: In the event of a fork in DID document history, the server
>   could choose to serve the '**wrong**' fork"

Read that list again: **forgery is not on it.** The directory's entire residual
power is DoS and fork-choice. The signatures verify without it; the spec
publishes a full offline validation procedure and makes the whole corpus
enumerable (`/:did/log/audit`, bulk `/export`) precisely so third parties can
check the server.

**Nostr NIP-41 — discovered it the hard way, and wrote it down.** [V] The current
draft is **PR #2137, open, unmerged, last activity 2026-03-04** (see Q2 for why
"kind 1776" is a *different, older* draft). Its own Appendix A:

> "This NIP is **highly dependent on the existence of a complete and ordered
> record** of `kind 360` and `kind 361` events."
>
> "**Nostr relays offer no consistency guarantees, which means commodity relays
> cannot support this use case.** Outbox relays can't be trusted because an
> attacker with access to a user's private key can update them. **Trusted relays
> of any kind can become attack vectors, since they can selectively omit entries,
> facilitating a migration attack.**"
>
> "**However these relays are chosen, the entire network MUST use the same set.
> Network partitioning is unacceptable in this case.**"

And from the PR body, the author naming his own unsolved problem:

> "This NIP relies on a **central group of trusted relays** to guarantee precommit
> availability and event validation (ordering is guaranteed by OTS, but not
> completeness). **I would be interested in a proposal to put precommits on a
> blockchain directly in order to remove this flaw.**"

**A registry-less network reinvented the registry and called it a relay cartel.**
That is the single most decisive datum for Q1.

**Keybase — buys ordering with a hash chain, and equivocation-resistance with a
blockchain, and nothing else.** [V] https://book.keybase.io/docs/server:

> "Every sigchain link is signed by one of the user's keys and includes a sequence
> number and the hash of the previous link. Because of this, **the server can't
> create links on its own or omit links without invalidating the whole
> sigchain.**"

> "A very sophisticated attacker could show my client and Alex's client different
> signed Merkle roots, **but must maintain these forks permanently and can never
> merge**. Users 'comparing notes' out-of-band immediately expose server duplicity."

> "**Enter the Bitcoin Blockchain. Thanks to Bitcoin, we are now unforkable.**"

Note the layering: the hash chain buys anti-rollback *within* a user's chain
(offline-checkable). The Merkle tree buys anti-omission across users. The
blockchain anchor buys anti-equivocation. Three separate mechanisms for three
separate non-signature properties. And the chain itself is still fetched **from
Keybase** — [V] the Stellar verification walkthrough's own step: *"Fetch **from
Keybase** the signatures over the grove… Also, include a path from the root of
the main tree down to the user's leaf."* Anchor ~hourly: *"Keybase publishes to
the Stellar Blockchain only about once an hour, despite updating itself about
once a second."*

Keybase **designed for third-party mirrors and never got them** [V]:
> "(**We're not aware of third-party mirrors yet**, and our reference client would
> need some modifications to handle a read-only server.)"

**Signal key transparency — says out loud that a log records *that*, not
*authorized-by-whom*.** [V] https://signal.org/blog/automatic-key-verification/
(2026-08-11):

> "Key transparency indicates that all devices in Signal's ecosystem share the
> same view of the associations between an identifier and its public encryption
> key. **It does not verify the identity of the user who controls a particular
> phone number or username.** … **additional verification (such as following up
> after a Safety Number change) would still be necessary to detect a scenario
> where Mallory has fully taken control of Alice's account.**"

So even a shipped, global, append-only log leaves the succession gap open. The
log gives you consistency. It does not give you authorization.

## The asymmetry the falsifier did not separate: self-facing vs third-party

This is the finding most directly relevant to the ore, and it is a **structural
observation, not a design proposal**.

The three properties above are only *hard* when the relying party is **someone
else**. When the relying party is **the subject's own device verifying the
subject's own history**, the picture changes materially:

- **Ordering**: the device that will later read the link is the same device
  lineage that wrote it. A locally-held, locally-appended chain has no ordering
  ambiguity to resolve — there is no second claimant with a competing timestamp,
  because there is no adversary racing to convince *you* about *your own* past.
- **Completeness**: "have I seen an earlier competing link?" is answerable from
  local storage. The subject's own device is the authority on its own record.

This is exactly the shape of the repo's `carriedRecord()` call site, which per
`CRUCIBLE.md` takes `required Uint8List subjectPublicKey` — **singular, and the
subject is the local user.** Whether that one site justifies a design is
falsifier #2, not falsifier #1; Q1's contribution is only that **the registry
argument does not reach the self-facing site.**

Two corroborations that the distinction is real and recognised elsewhere:

- **Signal's own asymmetry** [V]: `StorageService.proto`'s `AccountRecord` has
  **no** `aciIdentityKey*` field; the only `identityKey` field lives in
  `ContactRecord`. SVR-protected storage holds *other people's* public keys and
  *your* verification decisions — never your own private key. The self-facing and
  other-facing halves of identity are already stored in different places, under
  different trust assumptions, in a shipped product.
- **Keybase's `eldest_kid`** [V]: playback "starts at the most recent link whose
  `eldest_kid` matches the one in the Merkle tree" — the local replay of one's own
  chain is a pure function of the chain bytes.

## The other half: designs where the attestation travels WITH the messages

Q1 asked whether the relying party always needs a log, "or are there designs
where the attestation travels with the messages." There are. Three, of
increasing relevance:

### (a) MLS (RFC 9420) — membership changes validated in-band, no server validation

[V] https://www.rfc-editor.org/rfc/rfc9420.html

> "Recipients of an MLSMessage MUST verify the signature with the key depending
> on the `sender_type` of the sender"

> "MLS assumes a trusted AS but a largely untrusted DS. MLS is designed to
> protect the confidentiality and integrity of the group data even in the face of
> a compromised DS; in general, **the DS is only expected to reliably deliver
> messages**."

The confirmed transcript hash binds each epoch to the full history of Commits;
the confirmation tag is `MAC(confirmation_key, GroupContext.confirmed_transcript_hash)`
and "confirms that the members of the group have arrived at the same state."
So: **membership succession IS verified from the message stream alone.** The
price is that MLS still assumes a trusted **Authentication Service** for
identity→key binding, and [V] the spec does **not** describe a mechanism for
detecting a DS that shows different group states to different members. Ordering
is inherited from the epoch chain; equivocation across the whole group is not
addressed. Same split as everywhere else.

### (b) SSH `hostkeys-00@openssh.com` — succession proven over a channel the outgoing key authenticated

This is the closest living analogue to "the outgoing key vouches for the
incoming one," and it is **shipped and default-on**. [V] verbatim from
`PROTOCOL` at tag `V_9_8_P1`:

> "OpenSSH supports a protocol extension allowing a server to inform a client of
> all its protocol v.2 host keys after user-authentication has completed."
>
> "If the client identifies any keys that are not present for the host, it should
> send a `hostkeys-prove@openssh.com` message to request the server prove
> ownership of the private half of the key."
>
> "It also supports **graceful key rotation**: a server may offer multiple keys of
> the same type for a period (to give clients an opportunity to learn them using
> this extension) before removing the deprecated key from those offered."

What is signed is three fields: the literal context string (domain separation),
**the session identifier**, and the hostkey being proven.

**Verdict on portability: it does NOT travel with messages — it is the opposite
of a durable artifact.** [V] The session identifier is why: the proof cannot be
pre-generated (the session does not exist yet), cannot be transferred to a third
party (their session id differs), cannot be archived and re-verified later, and
**there is no artifact to publish at all**. It works precisely because it is
*not* a carried record. It solves the distribution problem by not having one:
the channel that carries the succession claim is itself authenticated by the
outgoing key.

The trust ceiling is stated in the draft, and it is the honest bound on every
design of this shape [V] `draft-miller-sshm-hostkey-update-01` §5.1:

> "This mechanism cannot be used to estabish trust in a SSH server where it did
> not previously exist. … **Keys learned though this mechanism can never be more
> trustworthy than the key used to establish the SSH transport session.**"
> *(sic — "estabish", "though" are in the original.)*

And the mandatory-proof rule, §5.2 — the sharpest single paragraph in the whole
corpus:

> "**MUST not record new host keys without verifying private key possession
> proofs.** Supporting the advertisment component alone… **allows an attack where
> a malicious server advertises a host key for a different legitimate server.**"

Status note [V]: both revisions of `draft-miller-sshm-hostkey-update` have
**expired** (`-00` expired 2026-02-02, `-01` expired 2026-02-04) and it is an
individual draft, not WG-adopted. **[U]** on whether a `-02` or WG adoption
exists. The *implementation* is nonetheless shipped since OpenSSH 6.8 (2015) and
default-on since 8.5 (2021) [V] — and notably, what flipped the default was not
the rotation use case but **SHA-1 RSA deprecation**: *"This release enables the
UpdateHostKeys option by default to assist the client by automatically migrating
to better algorithms."* A succession mechanism sat dormant for six years and was
activated by an unrelated crypto deprecation.

### (c) MINGLE (2026) — piggybacking consistency proofs on ordinary messages

The most directly on-point paper found, and it is new. [V] — I extracted the PDF
text locally. Fasllija, Heimberger, Paul (ASIT / TU Graz), *"Signal and Ready to
MINGLE: In-Band Gossip for Key Transparency Split-View Detection in E2EE
Messengers"*, https://eprint.iacr.org/2026/1010.pdf

> "Current deployments delegate detection to a small set of third-party auditors,
> creating a **centralized trust bottleneck** that can be pressured, compromised,
> or fail to audit continuously."
>
> "We ask whether clients can detect equivocation themselves, without dedicated
> infrastructure, simply by comparing KT state as they communicate. … **MINGLE
> piggybacks compact KT commitments on a subset of ordinary messages before
> encryption**, keeping gossip indistinguishable from regular application data
> while **requiring no external services or overlay network.**"
>
> "**an adversary wishing to sustain a split view must permanently isolate
> targeted clients from the rest of the network**, preventing any cross-partition
> message from ever being delivered, a requirement that grows increasingly
> difficult to maintain covertly as the social graph densifies."

Measured cost and performance, verbatim: *"a payload overhead of **119 bytes per
gossip-carrying message** without UI changes"*, and *"evidence of a targeted
split view in a 12,000-client deployment within about **5 minutes** when only
**20% of clients participate** and gossip is attached to roughly **5% of
messages**."*

And its own stated limit, which is the TOFU limit again:

> "MINGLE inherits the **Trust-on-First-Use (TOFU)** assumption standard in E2EE
> messengers: **equivocation that begins at registration evades immediate
> detection**, though the append-only log ensures it remains retroactively
> exposable once any cross-partition gossip event occurs."

**Caveat that must not be laundered:** MINGLE distributes the *audit* of a key
transparency log across the communication graph. It **presupposes the log**. It
is evidence that the *auditor* can be dissolved into the message stream — not
that the *log* can. This distinction matters and the paper is clear about it.
Also: a 2026 eprint preprint with simulation results, one prototype, no
deployment. **[R]** on any claim beyond what the abstract states.

## Verdict on falsifier #1 — as evidence, not as a design call

Stated at exactly the scope the evidence supports:

1. **FALSE as written for the self-facing relying party.** A locally-held,
   locally-verified rotation link needs no registry, because the ordering and
   completeness questions are answerable from local storage. No surveyed system
   contradicts this; Signal's storage asymmetry and Keybase's local replay
   corroborate the shape.
2. **TRUE for a third-party relying party** — but **not specifically true of
   backup**. The registry requirement attaches to *any* succession design in a
   multi-party system, whether the link is minted at backup time, at rotation
   time, or by guardian quorum. It is not a cost that backup introduces; it is a
   cost the third-party half was always going to pay. **The ore's claim that
   backup can mint the primitive is orthogonal to whether third parties can later
   consume it.**
3. **The gap is narrower than "needs the island's registry."** The evidence shows
   at least four ways to buy ordering/completeness, only one of which is a
   server-side registry: a hash chain the subject carries themself (Nostr #158,
   Keybase), an external timestamp anchor plus a waiting period (Nostr #829: OTS
   + 60 days), a transparency log plus in-band gossip (MINGLE), or a registry
   (did:plc, Matrix, Keybase's server). What Cast must price is **which property
   is actually needed at which call site**, not whether "a registry" is needed in
   general.

**What would still kill the ore** and was NOT falsified by this research:
falsifier #2 (one call site is not a design) and falsifier #3 (the export
security loss) — see Q4, where the evidence against #3 is stronger than
`CRUCIBLE.md` anticipated.

---

# Q2 — PRIOR ART ON A SUBJECT'S OWN MULTI-KEY IDENTITY

## The comparison table

| Mechanism | Who attests | Artifact or session? | Offline-verifiable? | Needs registry/log? | Names a successor? | Status |
|---|---|---|---|---|---|---|
| Matrix cross-signing (MSK/SSK/USK) | MSK → SSK → device | durable signed JSON | signatures yes; distribution no | **yes** (homeserver, no log) | n/a — MSK is the identity | shipped 2020 |
| Keybase sigchain `sibkey` | existing sibkey **+** `reverse_sig` by the new key | durable hash-linked log | correctness yes; freshness no | **yes** (+ blockchain anchor) | n/a — chain is the identity | shipped, frozen 2020 |
| Signal safety number | nobody | a displayed hash | n/a | no | **no** | shipped |
| Signal Quick Restore / linking | — (private key *transported*) | live QR session | no | no | n/a | shipped 2025 |
| Signal key transparency | the ledger | log inclusion proof | no | **yes** | **no** (consistency only) | shipped 2026 |
| Nostr PR #158 hash chain | outgoing key | durable event | **yes** | **no** | yes | **CLOSED** |
| Nostr PR #829 (1776/1777) | outgoing key + OpenTimestamps | durable event | partly | yes (OTS + relay completeness) | yes | OPEN, stale |
| Nostr PR #2137 (360/361/362) | an intermediate migration key | durable event | **no** (needs completeness) | **yes** (relay cartel) | yes | OPEN, no consensus |
| did:plc rotation key | a higher-priority key | durable signed op | signature yes, **ordering no** | **yes** (plc.directory) | n/a — DID is stable | **shipped, live** |
| PGP revocation cert (sigclass 0x20) | outgoing key | durable, **~120 bytes** | **yes** (proved by live experiment) | no | **no** | shipped 2014, automatic |
| PGP transition statement | outgoing key + humans | durable, human-readable | by a human | no | in prose only | **pure convention** |
| `draft-ietf-openpgp-replacementkey-08` | **both, mutually** | durable artifact | **yes** | no | **yes, machine-readable** | WG draft, 2 alpha impls, **nothing deployed** |
| PGP subkey (0x18 + embedded 0x19) | primary key **+** subkey counter-sig | durable artifact | yes | no | n/a — identity stable | shipped, universal |
| SSH `hostkeys-prove-00` | **both** (channel + possession) | **live session only** | **no** | no | yes, implicitly | shipped 6.8, default-on 8.5 |
| SSH user keys | — | — | — | — | **none exists** | confirmed absent |
| age | — | — | — | — | **none exists** | out of scope by design |
| MLS (RFC 9420) | group members, in-band | message stream | **yes** within the group | no (DS untrusted) | n/a | RFC, shipping |

## Matrix cross-signing — the closest prior art, and its price

**Structure** [V], verbatim from the spec source
(https://spec.matrix.org/latest/client-server-api/#cross-signing):

> "Each user has three ed25519 key pairs used for cross-signing (cross-signing
> keys):
> - a **master signing key** (MSK)… that serves as the user's identity in
>   cross-signing and signs their user-signing and self-signing keys;
> - a **user-signing key** (USK) — only visible to the user that it belongs to —
>   that signs other users' master signing keys; and
> - a **self-signing key** (SSK) that signs the user's own device keys."

The four-line trust predicate [V]:

> "Alice can trust Bob's device if: Alice's device is using a master signing key
> that has signed her user-signing key, Alice's user-signing key has signed Bob's
> master signing key, Bob's master signing key has signed Bob's self-signing key,
> and Bob's self-signing key has signed Bob's device key."

**Key-as-identity is literal** [V]: *"Verification methods can be used to verify
a user's master signing key by treating its public key… as the device ID."* And
*"Servers therefore must ensure that device IDs will not collide with
cross-signing public keys."*

**The homeserver's role.** Upload is `POST /_matrix/client/v3/keys/device_signing/upload`;
UIA is required **except** when no MSK exists yet or the request contains no new
keys [V] — *"This allows clients to freely upload one set of keys, but not
modify/overwrite keys if they already exist."* **So the anti-rotation control is
server-enforced UIA, not cryptography.** Distribution is `POST /keys/query`, and
this sentence is the one that matters [V]:

> "…along with **the signatures uploaded via `/keys/signatures/upload` that the
> requesting user is allowed to see.**"

**The homeserver filters the signature set per requester.** It cannot forge
(Ed25519 over Canonical JSON) but it can **omit, delay, and equivocate**, with no
log and no rollback detection. That gap is a known open spec issue, not a
misreading: matrix-spec **#2075, "Transparency logs for public identity keys"**
— open, labelled `improvement`, proposing *"a public, append-only, directory,
containing all public user identity keys"*, citing WhatsApp's `akd`. **[R]** (I
read the rendered issue page.) **Scope note:** the "server can omit undetected"
claim is a negative established over four spec files
(`end_to_end_encryption.md`, `secrets.md`, `cross_signing.yaml`, `keys.yaml`,
`cross_signing_key.yaml`) read in full — corroborated by #2075 asking for exactly
the missing mechanism, but **it is still a negative and should be phrased as
"the spec defines no transparency log," not "Matrix cannot detect equivocation."**

**SSSS — "4S" — the recovery layer.** [V] Encrypted secrets live in account data:
*"When secrets are stored on the server, they are stored in the user's
account-data, using an event type equal to the secret's identifier."* The
cross-signing private keys are among them: `m.cross_signing.master`,
`m.cross_signing.user_signing`, `m.cross_signing.self_signing`, base64'd then
encrypted.

Only one algorithm exists, `m.secret_storage.v1.aes-hmac-sha2` [V]:
HKDF-SHA-256 with a 32-zero-byte salt and **the secret name as `info`** (free
domain separation, worth noting), 32-byte AES-CTR key + 32-byte MAC key, 16-byte
IV with bit 63 cleared "to work around differences in AES-CTR implementations",
HMAC-SHA-256 over the raw ciphertext.

**Passphrase derivation, and the number** [V]:
> "Currently, the only algorithm defined is `m.pbkdf2`."
> "The key is generated using **PBKDF2 with SHA-512**… the number of iterations
> given in the `iterations` parameter."

**The spec sets NO minimum iteration count.** The worked example shows `100000`,
but that is an example. A lazy or hostile client can write `iterations: 1` and
every other client honours it. [V, verified by reading the whole module.]

**The key-check trick is elegant and worth knowing** [V]: same HKDF with the
**empty string** as `info`, encrypt 32 zero bytes, store only `iv` and `mac`,
discard the ciphertext; "the MAC should match if the key is correct." **But its
failure mode is the one this repo's global CLAUDE.md warns about**, verbatim:

> "Note, however, that **these properties are optional. If they are not present,
> clients must assume that the key is valid.**"

An instrument whose *absent* value equals its *success* value cannot report its
own absence.

**The recovery key format** [V] (spec appendices): prefix bytes `0x8B 0x01`, raw
key, one XOR parity byte, base58 with the Bitcoin alphabet, space every 4 chars.
32 raw bytes → 35 → ~48 base58 characters.

**Terminology is officially a mess and the spec admits it** [V]:
> "The backup decryption key was previously referred to as a 'recovery key'.
> However, this conflicted with common practice in client user interfaces…
> **The term 'recovery key' is no longer used in this specification.**"

**Backup relation** [V]: the megolm backup private key is *itself a secret stored
in SSSS* under `m.megolm_backup.v1`. So one string unlocks both identity and
history: **recovery key → {cross-signing private keys, backup key} → messages.**

**A frozen bug in the backup MAC** [V], verbatim warning box:
> "Step 5 was intended to pass the raw encrypted data, but **due to a bug in
> libolm, all implementations have since passed an empty string instead.**"
The backup MAC authenticates nothing. The spec froze the bug as the contract.

## Keybase sigchain — the cleanest device-addition primitive found

**The `sibkey` link carries TWO signatures** [V] https://book.keybase.io/docs/server:

> ```
> { "type": "sibkey", "sibkey": { "kid": "01204…", "reverse_sig": "g6Rib…" } }
> ```
> "**`reverse_sig` is a signature of the link by the new sibkey itself, made with
> the `reverse_sig` field set to null, and makes sure that a user can't claim
> another user's key as their own.**"

Outer: signed by an existing provisioned device. Inner: proof of possession by
the new key. **Both directions.** This is the same shape as OpenPGP's 0x18/0x19
subkey pair and SSH's advertise+prove pair — see the cross-cutting finding below.

**Revocation does not invalidate the past** [V]:
> "**Since every link is checked against the state of the account at that point in
> the sigchain, old links remain valid even if their signing keys are revoked
> later.** Revoking a key doesn't affect your identity proofs, other keys, or
> followers."

That sentence is the direct answer to the `carriedRecord` problem class: a
lifecycle-aware chain makes historical signatures stay valid by construction,
rather than needing a "set of known keys" bolted on.

**Deliberate anti-PGP framing** [V]:
> "This is different from PGP, which has a 'master key' that you're expected to
> keep tucked away in a fireproof safe — because if you misplace a device that has
> a copy of it, your only option is to revoke the whole key and start from
> scratch."

**The paper key is not a special recovery artifact — it is just another sibkey**
[V] https://book.keybase.io/account:
> "**A paper key is a long string of randomly-generated words that's linked to
> your account the same way a device is.**"
> "When you add a new device or paper key, **your existing device vouches for the
> new one.**"

Contrast Matrix, where the recovery key is a *different kind of thing* (a
symmetric key wrapping private keys) from the identity keys it protects. Keybase
has one primitive; Matrix has two, and the second is where its UX failures
cluster (below).

**Provisioning channel** [V] (https://book.keybase.io/docs/crypto/key-exchange):
8 or 9 BIP-39 words (88/99 bits), `scrypt(N, r=8, p=1)` with **N=2¹⁷ on desktop,
N=2¹⁰ on mobile** *"since higher values crash older phones"* — a real, published
data point on mobile KDF ceilings. Messages are NaCl SecretBox'd and bounced off
Keybase's own servers: *"the Keybase server can control the channel, but with the
end-hosts authenticating and encrypting, this design decision does not present a
security risk."*

**Losing everything including the paper key: total loss.** [R] — reset starts a
new sigchain under the same username, old content is permanently lost, teams can
be left ownerless. I could not find a first-party Keybase page stating this;
flagged as a gap. Known rough edges [R]: keybase-issues #2410, #2759, #3893
(paper-key reset failures, `ERROR eldest called on user with existing eldest KID`).

**Post-Zoom**: acquisition 2020-05-07 [R]; commit activity collapsed [R]; the
Keybase Book's footer reads "(C) Keybase — 2022". **There is no first-party
engineering post-mortem of the design.** Commentary exists; a retrospective by
the designers does not.

## Signal — no succession mechanism exists, and this is verified three ways

**[V]**, with the instrument named each time:

1. `libsignal/rust/protocol/src/identity_key.rs` read in full. The only
   key-attests-key primitive is `sign_alternate_identity` / `verify_alternate_identity`
   — **ACI signs PNI, same account, same instant.** Not old-signs-new. *The
   primitive Signal would need for succession exists in their codebase, deployed
   for a different purpose.*
2. Code search for `previousIdentityKey` across libsignal / Signal-Android /
   Signal-iOS → **zero hits.** (Coverage caveat: GitHub code search indexes the
   default branch only.)
3. `keys.proto` has `SetPreKey`, `GetPreKeys`, `CheckIdentityKeys` — **no
   "change my identity key, signed by my old key" RPC.** The ACI identity key is
   authenticated by **phone-number possession**, never by the prior key.

**Signal's continuity mechanism is private-key transport, not attestation** [V]
— both linked-device provisioning and 2025 Quick Restore move
`aciIdentityKeyPrivate` verbatim over a QR-bootstrapped encrypted channel:

```proto
message RegistrationProvisionMessage {
  bytes aciIdentityKeyPublic = 10;
  bytes aciIdentityKeyPrivate = 11;    // the old phone hands over the private key
}
```

**What actually happens per path** [V] from client source — more nuanced than the
folklore:

| Path | ACI identity key | Safety number changes? |
|---|---|---|
| Fresh install + re-registration | **regenerated** | **yes** |
| Restore from Signal Secure Backups (recovery key, no old phone) | **regenerated** | **yes** |
| Quick Restore (new phone scans QR on old phone) | carried over | no |
| Same-platform device transfer | carried over | no |
| Android legacy on-device backup restore | carried over | no |
| Linking a Desktop/iPad | shared, not new | no |

Signal's support article was updated to hedge exactly this [V, updated
2026-07-28]: *"…**but these actions don't always result in a safety number
change.**"*

**The structural coupling worth carrying forward: the only recovery path that
survives a lost phone is the only path that burns the key.** [V] Secure Backups
(2025, $1.99/mo, 64-char recovery key, *"all of your text messages and the last
45 days of media"*) is the sole cross-platform/lost-phone route — and
`Backup.proto`'s `AccountData` has **no `aciIdentityKey`** field, while
`EnterBackupKeyFragment.kt` calls `registerWithBackupKey(…, aciIdentityKeyPair =
null, …)` → fresh randomness. The identity key sits entirely outside the Account
Entropy Pool → MasterKey → SVR derivation tree [V]. **Nothing a user can
memorize or write down brings it back, by design.**

**One-directional alarm** [V for the format]: `Backup.proto`'s `Contact` message
*does* carry `identityKey` and `identityState`. So after a restore **you** see no
changes for your contacts, while **they all** see a change for you.

**Published rationale.** A Signal-authored rationale for the *absence of
succession* — **[U], could not confirm one exists** (searched signal.org/blog,
support.signal.org, community.signalusers.org, GitHub). What Signal *has*
published treats key discontinuity as a given rather than a defended choice
[V, moxie0 2017-01-13, https://signal.org/blog/there-is-no-whatsapp-backdoor/]:

> "**Every time someone gets a new device, or even just reinstalls the app, their
> identity key pair will change. This is something any public key cryptography
> system has to deal with.**"

And the blocking-warnings rationale [V]:
> "**The choice to make these notifications 'blocking' would in some ways make
> things worse. That would leak information to the server about who has enabled
> safety number change notifications and who hasn't, effectively telling the
> server who it could MITM transparently and who it couldn't**"

**Signal's answer to key churn was to make fingerprints per-conversation and
ephemeral, not to make keys durable.** [V] https://signal.org/blog/safety-number-updates/:
> "**People's Signal keys change every time they get a new phone or reinstall the
> app.** This caused problems when Signal users would post their fingerprints in
> a few places online and then forget to update them… When their contacts verified
> against these stale fingerprints, they would initially conclude that their
> communication was being intercepted, and then eventually, that **the whole
> fingerprint thing is just unreliable. Both are extremely undesirable outcomes.**"

## Nostr — status corrected

**NIP-26: struck through, still present, `unrecommended`.** [V] I fetched
`https://raw.githubusercontent.com/nostr-protocol/nips/master/README.md` and
grepped. Line 47, verbatim including strikethrough:

```
- ~~[NIP-26: Delegated Event Signing](26.md) --- **unrecommended**: adds unnecessary burden for little gain~~
```

It sits in a cohort of 13 struck-through NIPs. **NIP-06 is struck through too**
[V]: *"`unrecommended`: prefer a single nsec"* — **Nostr actively rejected
HD-derivation from a mnemonic as a key-management layer.**

**NIP-41: NOT MERGED, and the brief's "kind 1776" belongs to an older draft.**
[V] `41.md` on master returns **HTTP 404**; NIP-41 does not appear in the README
index at all. Four distinct attempts, via `gh pr view`:

| PR | Title | Author | State | Created | Last update | Kinds |
|---|---|---|---|---|---|---|
| #158 | NIP-41: Key Invalidation | fiatjaf / RubenSomsen | **CLOSED** | 2023-01-08 | 2023-11-16 | kind 13 |
| #829 | NIP-41: simple account migration | pablof7z | **OPEN** | 2023-10-18 | 2026-03-04 | **1776 / 1777** |
| #2114 | NIP D8 Key Rotation | staab | **OPEN** | 2025-11-07 | 2026-03-04 | — |
| **#2137** | **Key migration** (current) | staab | **OPEN** | 2025-11-25 | **2026-03-04** | **360 / 361 / 362** |

**PR #158 (CLOSED) is the only registry-free design in the whole corpus.** [V] A
pre-generated chain of 256 keys, each committing to the next:
```
A = A' + hash(A'||B)
```
Publish a kind-13 from `B` revealing `A'`; anyone verifies `hash(A'||B) + A' = A`
**from that one event alone**. Its own framing: *"The invalidation is
**unambiguous**… **Only the owner of the root key is able to figure out the next
key.**"* And its own statement of the attack that kills the naive version:

> "the attacker who has `a` could publish an [event] with a **lower `created_at`
> value** pointing people to a new key `X`… And for any reader only seeing these
> two events **it becomes at least very hard to decide which one, `X` or `B`, is
> the actual new key**"

It was closed.

**PR #2137 (current) states its own fatal trade-off** [V]:
> "If a key is leaked before a `migration` event is published, the attacker will be
> able to migrate to their own key, **locking the original user permanently out of
> their account. This is the key trade-off of this NIP.**"
> "**The worst case scenario occurs when an attacker gets key material and the
> user hasn't yet published a precommit… This is worse than the status quo**,
> since currently users retain the ability to spam an identity."

And it deliberately refuses to link the identities [V]:
> "Migration is only used to signal to clients that users should update their
> follow lists…, **NOT establish a live link between an old key and a new key**…
> This means that mentions etc are not maintained, **messages are lost**, etc.,
> but implementation is much less onerous."

**The best idea in that thread** [V, staab 2025-12-02, conceded by fiatjaf as
*"That's a good argument"*] — why an intermediate single-use migration key beats
pre-signing to a named successor:

> "This means that the user has to generate the next key eagerly and store it
> securely, which **exposes the successor key to the same failure case as the
> primary key**. The migration key allows for **generating a successor key on
> demand without naming it in advance**, allowing people to mess up and still
> recover. We could shard the successor key and share it, but then **we're
> exposing a general-purpose key to whatever risks the backup solution has
> forever, instead of just the migration key which becomes obsolete once used.**"

**The time-lock UX objection** [V, staab]:
> "**The waiting period creates poor UX, where someone's account is in limbo for a
> pretty long time.** This is at least annoying to users who want to migrate and
> forget about it, but **especially bad if an attacker has their key and they
> can't dissociate themselves immediately.**"

**Social attestation, directly relevant to an island model** [V, pablof7z
2025-11-28]:
> "How do followers attest to 'I verified out-of-band the person really changed
> pubkeys'? I think it'd be valuable to have this as an **explicit action**… if my
> key is compromised and I roll onto the new one I would call [people] that I'm
> close with to get them to attest and **give a clear social weight to that
> migration event.**"

**The implementation-risk objection** [V, vitorpamplona 2025-12-02]:
> "in the same way that we tell people to never put their nsecs in any client,
> **we should tell users to never do any migration function in a regular client.**"
> "So many things can go wrong here: Clients not checking OTS or checking
> incorrectly · Clients not storing migration information correctly and leaking
> access to the other keys · **Clients trying to migrate all the account info from
> one key to another, establishing a link in some other way** · …"

**Lost nsec today: nothing exists.** [R] Generate a new keypair, post from it,
rebuild the follower graph by hand. The ecosystem's whole answer is prevention —
NIP-07 extensions, NIP-46 remote signing ("bunkers"), NIP-49 `ncryptsec`
encrypted key backup. NIP-49 [V] is scrypt(password, 16-byte salt, log_n) over
the raw 32-byte private key — **that is backup, not succession.**

**NIP-05** [V] is `final`: a kind-0 `nip05` field → `https://<domain>/.well-known/nostr.json?name=<local>`.
**Repointing that JSON at a new pubkey is, de facto, the only working migration
mechanism Nostr has today** — at the cost of the domain owner becoming the
authority. (Spec mechanics [V]; the "de facto migration path" characterisation is
the researcher's reading, **[U]**.)

## did:plc — recovery bought with a directory, priced explicitly

**Structure** [V] https://atproto.com/specs/did + the did-method-plc spec:
> "Control over a `did:plc` identity rests in a set of reconfigurable **rotation
> key pairs**… with each operation **referencing a prior version of the identity
> state by hash**… **the hash of this initial [genesis] object is what defines the
> DID itself**."

`rotationKeys`: *"priority-ordered list… must include at least 1 key and at most
5 keys… **not included in DID document.**"* Only secp256k1 and P-256. And:
*"**Best practice is to maintain separation between rotation keys and atproto
signing keys.**"*

**The 72-hour window, verbatim and confirmed** [V]:
> "Keys are listed in the `rotationKeys` field of operations in **order of
> descending authority**.
>
> The PLC server provides a **72hr window during which a higher authority rotation
> key can 'rewrite' history, clobbering any operations (or chain of operations)
> signed by a lower-authority rotation key.**
>
> …The PLC server will accept this recovery operation as long as:
> - **it is submitted within 72hrs of the to-be-invalidated operation**
> - **the key used for the signature has a lower index in the `rotationKeys` array
>   than the key that signed the to-be-invalidated operation**"

**This is structurally different from everything else in the survey.** It is not
"old key attests new key." It is **"a colder key can undo a warmer key's actions,
for three days."** The recovery capability is held *in advance* and *offline*, and
it operates by *rollback*, not by *attestation*.

**Centralisation, on the record** [V]: *"**We expect to evolve the system… into
something less centralized - likely a permissioned DID consortium.**"* Governance
moved 2025-09-19 [V] https://atproto.com/blog/plc-directory-org — an independent
**Swiss Association** to operate the directory, because *"Switzerland provides a
credibly neutral and stable global home."*

**did:web is the registry-free alternative and the spec prices it** [V]:
> "[did:web] is inherently tied to the domain name used, and **does not provide a
> mechanism for migration or recovering from loss of control of the domain name**"

**The fork, stated plainly: did:plc gives recovery at the cost of a directory;
did:web gives no directory at the cost of no recovery.**

**Permanent privacy cost** [V]:
> "The full history of DID operations and updates, including timestamps, is
> **permanently publicly accessible. This is true even after DID deactivation.**"
> "**if two individuals cross-share rotation keys as a trusted backup, that
> information is public.** If device-local recovery or signing keys are uniquely
> shared by two identifiers, that would indicate that **those identities may
> actually be the same person.**"

**Adversarial migration** [R] (David Buchanan,
da.vidbuchanan.co.uk/blog/adversarial-pds-migration.html): published guides cover
only the cooperative case; the defence is enrolling a backup rotation key at
*higher priority* than any key the PDS holds, **in advance**. His warning: *"If
someone social-engineered you into installing a malicious key with top priority,
that's a bad situation to be in (similar badness-level to disclosing the
'recovery phrase' of a cryptocurrency wallet)."*

## PGP, SSH, age

### The pre-generated revocation certificate — the strongest analogue to "sign your succession while alive"

**GnuPG does it automatically at key creation** [V] `man gpg` (2.2.41):
> "**In addition to the key a revocation certificate is created and stored in the
> 'openpgp-revocs.d' directory**"

And the FILES section, which is the whole design lesson in one paragraph [V]:
> "It is suggested to backup those certificates and if the primary private key is
> not stored on the disk to move them to an external storage device. **Anyone who
> can access these files is able to revoke the corresponding key.** You may want
> to print them out."

**The pre-generated cert is a bearer capability.** Introduced in 2.1.0-beta751,
2014-07-03 [V, GnuPG NEWS].

**CONFIRMED self-contained and offline-verifiable — by live experiment** [V]. A
throwaway ed25519 key's revocation cert was imported into a second, clean keyring
holding only the public key, with no secret key and no network:
```
gpg: key C1C245F7DBB51633: "Revoke Test <rt@example.invalid>" revocation certificate imported
pub   ed25519 2026-09-16 [SC] [revoked: 2026-09-16]
```
The cryptographic payload is **one signature packet, 120 bytes**, sigclass 0x20.

**And the finding that kills the naive "one artifact does both" idea** [V] — the
live packet dump shows the revocation reason as:
```
hashed subpkt 29 len 1 (revocation reason 0x00 ())
```
**`0x00` — "No reason specified". At generation time GnuPG cannot know why you
will eventually revoke, so a pre-generated certificate structurally cannot name a
successor.** The kill-switch-in-advance and the succession-pointer are mutually
exclusive in the same artifact. This is corroborated from the other direction by
`draft-ietf-openpgp-replacementkey-08` §4 [V]: *"If a replacement or deprecated
primary key is unknown, then a Replacement Key subpacket SHOULD NOT be
included."*

**Distribution is where PGP actually failed, not verification.** GnuPG's entire
documented answer [V]: *"the revoked key needs to be published, which is best
done by sending the key to a keyserver… and by exporting it to a file which is
then send to frequent communication partners."*

**SKS certificate flooding, June 2019** [R]:
> "The OpenPGP specification puts no limitation on how many signatures can be
> attached to a certificate… **If you fetch a poisoned certificate from the
> keyserver network, you will break your GnuPG installation. Poisoned
> certificates cannot be deleted from the keyserver network.**"

**The defect was not the flooding — it was an unauthenticated, append-only,
permanent write channel that let any third party attach unbounded data to
anyone's certificate.** `sks-keyservers.net` has **zero A records as of
2026-09-16** [V, measured]; the commonly-cited 2021-06-21 shutdown date is **[U]**
— could not confirm from a primary source, because the site is gone.

**keys.openpgp.org's fix, and the rule that matters** [V]:
> "**Any non-identity information will be stored and freely redistributed**, if it
> passes a cryptographic integrity check… It also includes… **revocation status**."
> "The identity information in an OpenPGP key is **only distributed with
> consent.**"

**Revocation status propagates without consent; identity does not.** A deliberate
choice: the kill switch must travel even when the identity does not.

And the third-party-signature rule [V]: *"**The killer reason is spam.
Third-party signatures are a mechanism to attach arbitrary data to anyone's
key**… Therefore, by default, keys.openpgp.org doesn't publish third-party
certifications."* **One rule: only the key holder can cause data to be attached
to their own key.** The cost, stated plainly: it kills the Web of Trust as a
distributed artifact.

A live interoperability defect worth naming [V]: *"**In March 2020 the GnuPG team
rejected the patch, and updated the issue status to 'Wontfix'. This means that
unpatched versions of GnuPG cannot receive updates from keys.openpgp.org for keys
that don't have any verified email address.**"* — the kill switch is published and
the relying party's tool declines to read it.

### Transition statements — pure convention, and the IETF says so

[V] `draft-ietf-openpgp-replacementkey-08` §1:
> "In the past some key owners have created key transition documents, which are
> signed, human-readable statements stating that a newer primary key should be
> preferred by their correspondents. **It is desirable that this process be
> automated through a standardised machine-readable mechanism.**"

**Debian's actual rules** [V] https://keyring.debian.org/replacing_keys.html:

*Old key still usable:* "Key Y must be signed by key X. Key Y must be signed by
at least 2 keys which are part of the active Debian keyring. The request for
replacement should be signed by key X…"

*Old key compromised or lost:* "Key Y must be signed by two active Debian
developers… **If the reason for replacement is 'key X is compromised or no longer
valid' then the request for replacement must be accompanied by a revocation
certificate for key X.**"

**The design insight: when the old key can still sign, succession is proved by
the outgoing key; when it cannot, succession falls back to human vouching by two
other trusted parties.** That fallback is the part no cryptographic mechanism
provides.

**Caveat, honoured:** Debian mandates only the **old** key's signature on the
request (plus keyring-member certifications on the new key). The "signed by
BOTH" formulation is broader community convention that Debian's page does not
literally require. **Do not overstate it.**

**No subpacket exists for it today** [V] RFC 9580 §5.2.3.31: subpacket 29 codes
are `0 No reason specified · 1 Key is superseded · 2 compromised · 3 retired · 32
User ID no longer valid`, plus a human-readable UTF-8 string. **You can write a
successor fingerprint into that string but nothing parses it.**

The semantic distinction is load-bearing [V]:
> "If a key has been revoked because of a compromise, all signatures created by
> that key are suspect. However, if it was merely superseded or retired, **old
> signatures are still valid.**"

### `draft-ietf-openpgp-replacementkey-08` — the standards effort, and its shape

[V] D. Shaw & A. Gallagher, **29 May 2026**, Standards Track, *Updates: 9580 (if
approved)*. WG-adopted.

> "**The 0x01 bit of the class octet is the 'backward reference(s)' bit.** When
> set, this means that the target key(s) identified by the packet are the primary
> keys for which the current primary key is the replacement… Otherwise, the
> subpacket represents a **forward reference**."

**The bidirectionality is the key idea — it is the dual-signed transition
statement made machine-readable.** A forward reference in the old key's
revocation ("I am replaced by K_new") plus a backward reference in the new key's
direct self-signature ("I replace K_old") together form an identity-equivalence
binding. **Neither half alone suffices.**

Binding rule [V] §5.3: *"if a Replacement Key subpacket is included in a Key
Revocation signature, then the Reason For Revocation subpacket **MUST indicate
'Key is superseded'**… A receiving implementation MUST ignore any Replacement Key
subpacket present in a Key Revocation signature with a Reason for Revocation that
is not 'Key is superseded'."*

**Status, precisely** [V] Appendix D: **two implementations, both alpha, both
tracking `-07`, both "Coverage: wire formats" only** (ProtonMail/go-crypto PR
#311, rPGP PR #725), both "Implementation experience: TBC". **Nothing is
deployed. GnuPG is not listed.** The subpacket code point is **100 (TEMPORARY,
permanent code point TBC)** — do not cite 100 as final.

### OpenPGP subkeys — the mutual-attestation pattern, shipped since 2007

[V] RFC 9580 §5.2.1.8:
> "0x18 Subkey Binding Signature — This signature is a statement by the top-level
> signing key, indicating that it owns the subkey… **A signature that binds a
> signing subkey MUST have an Embedded Signature subpacket in this binding
> signature that contains a 0x19 signature made by the signing subkey on the
> primary key and subkey.**"

**Primary claims the subkey; subkey counter-claims the primary, embedded inside
the primary's own signature.** Without it, anyone could bind someone else's
signing subkey to their own primary. Encryption subkeys need only 0x18.

**Rotation without identity change — demonstrated live** [V]: `gpg
--quick-add-key <fpr> cv25519 encr never` left the primary fingerprint
byte-identical; the certificate simply grew by a public-subkey packet and a
0x18 signature.

**How a relying party learns: by re-fetching and merging. There is no push, no
notification, no in-band signal** [V]. The new packets verify under the
already-trusted primary, so the subkey is accepted **with no new trust
decision** — trust in the primary is amortised across every future subkey.
**OpenPGP's succession is pull-based and latency-unbounded; SSH's is push-based
but requires a live session. Neither is both.**

### SSH user keys — succession confirmed ABSENT

[V] `man sshd` (OpenSSH 10.3p1), `AUTHORIZED_KEYS FILE FORMAT` read in full,
every option keyword enumerated. The only lifecycle option is:
> "`expiry-time="timespec"` — Specifies a time after which the key will not be
> accepted."

**An expiry, not a succession. It cannot name a replacement and nothing
propagates.** `@revoked` does **not** apply here — verified by section-boundary
check rather than assumed: `AUTHORIZED_KEYS` starts line 207, `SSH_KNOWN_HOSTS`
starts line 389, and all `@revoked` hits fall at lines 399–434.

**The asymmetry is deliberate:** the server is a single well-known party that can
push; the user is a diffuse set of `authorized_keys` entries nobody enumerates.

**SSH certificates dissolve the problem rather than solve it** [V]: the relying
party pins the CA, not the leaf. The cost is a new trusted third party, and **the
CA key becomes the thing that can never rotate gracefully.** Note the
interaction: `UpdateHostKeys` explicitly **refuses** to operate with a
certificate host key — the two mechanisms are mutually exclusive by design.

**KRLs** [V] are SSH's closest analogue to a PGP revocation cert:
self-contained, offline-distributable, offline-verifiable, *"as little as one bit
per certificate"*, usable *"without having the complete original certificate on
hand."* But a KRL is **a deny-list with no successor pointer, and SSH specifies
no fetch mechanism at all.**

### age — no rotation story, by design

[V] **verified negative over the complete spec text**, not a sample: the age spec
(https://github.com/C2SP/C2SP/blob/main/age.md, 492 lines) contains **zero**
case-insensitive occurrences of "rotate", "rotation", "revoke", "revocation",
"successor", "expire", or "replace". The README (325 lines) has no
key-management section. [R] Issue #136 ("Changing recipients of existing
encrypted files") closed as not planned; **[U]** — no maintainer quote retrieved,
do not attribute one.

**This is a positive finding, not a gap.** An age recipient is a raw X25519
public key with a checksum — there is nothing to attach a revocation or successor
pointer *to*. **If a system needs succession, age is the wrong layer; it needs an
identity layer above it.**

---

# Q3 — BACKUP ARTIFACT FORMS AND THEIR REAL FAILURE MODES

## The arithmetic first, because it reframes the question

Two facts about a 32-byte Ed25519 seed, both [V]:

- **BIP-39 fits it exactly.** The spec (https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
  — note the path is repo-root, `bip-0039/` holds only wordlists) gives
  `CS = ENT/32`, `MS = (ENT+CS)/11`. At ENT=256: CS=8, MS=**24 words**, zero
  padding. Checksum rule verbatim: the checksum is *"the first ENT / 32 bits of
  its SHA256 hash"*. Wordlist = 2048 words (verified by counting
  `english.txt`), *"Words can be uniquely determined by typing the first 4
  characters"*.
- **A single static QR is ~100× oversized for it.** Version-40 byte-mode capacity
  [V]: L=2953, M=2331, Q=1663, **H=1273 bytes**. A 32-byte seed plus an encrypted
  envelope is ~100 bytes → roughly version 6–10 at level H. **Animated QR is a
  solution to a problem this payload does not have.**

**So every hard problem in this space is about the human and the platform, not
the encoding.** The real question a backup design answers is not *which artifact*
but *which custodian*: the user's memory, the user's paper, Apple's HSM cluster,
Google Play services, a passkey authenticator, or a set of the user's friends.

## BIP-39 — and its documented silent failure

**The passphrase trap, verbatim** [V]:
> "**every passphrase generates a valid seed (and thus a deterministic wallet)
> but only the correct one will make the desired wallet available.**"

There is **no verification of the passphrase at all**. A typo in the "25th word"
does not error — it produces a different, perfectly valid, empty wallet. This is
the canonical instrument-that-cannot-report-its-own-failure in the backup space.

**A derivation asymmetry that matters** [V]: BIP-39's own mnemonic→seed path is
PBKDF2-HMAC-SHA512, 2048 iterations, salt `"mnemonic"+passphrase`, output 64
bytes — **lossy** for a 32-byte seed. Using BIP-39 as an *encoding of the raw
entropy* (24 words ↔ 32 bytes, bijective, 1-in-256 typo detection) is a different
operation from using it as a *seed derivation function*. Conflating them is a
real, easy bug.

Other documented problems: non-English wordlists are *"strongly discouraged"* for
compatibility [V]; several words appear in both English and French lists [R]; the
checksum tells you *that* the phrase is wrong, never *which word*.

**And the bearer-instrument problem, stated by SLIP-39's own motivation** [V]:
> "when the asset itself is of significant and liquidable value, there is a
> substantial risk of the backup holder absconding with the asset."

## SLIP-39 — sound spec, thin adoption

[V] https://github.com/satoshilabs/slips/blob/master/slip-0039.md. 128-bit →
20 words/share; **256-bit → 33 words per share**, and you need several. Two-level
groups-of-groups; 30-bit RS1024 checksum *"guarantee[s] detection of any three or
fewer errors"*. Nice touch: *"the random identifier and the iteration exponent
transform into the first two words… so the user can immediately tell whether the
correct shares are being combined."* Same silent-passphrase property as BIP-39.
**Incompatible with BIP-39** — different wordlist, *"the two are not compatible"*.

**Adoption is the finding.** Trezor's own FAQ [V]: *"supported by software wallets
such as Rabby, Electrum, Sparrow, BlueWallet, and Wasabi, and by the Keystone
hardware wallet."* **Ledger and Coldcard do not support it** [R]. Seven-plus
years on it is essentially a Trezor standard with a software-wallet tail.

## Passphrase-wrapped blob — parameters and the two traps

**OWASP current Argon2id recommendations, verbatim** [V]
(https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html):
> "m=47104 (46 MiB), t=1, p=1" · "m=19456 (19 MiB), t=2, p=1" ·
> "m=12288 (12 MiB), t=3, p=1" · "m=9216 (9 MiB), t=4, p=1" ·
> "m=7168 (7 MiB), t=5, p=1"

scrypt [V]: *"N=2^17 (128 MiB), r=8, p=1"* through *"N=2^13 (8 MiB), r=8, p=10"*.
PBKDF2 for reference [V]: *"PBKDF2-HMAC-SHA256: 600,000 iterations"*.

**Important framing:** OWASP's numbers are tuned for a server verifying many
logins per second — the opposite of a once-per-lifetime backup unwrap on one
device with the user already waiting. The binding constraint on mid-range Android
is **memory, not time** (low-memory killer). **Realistic parameters on real
hardware: [U], unmeasured. No number is invented here.** Corroborating data point
from Keybase [V]: their mobile KEX uses `scrypt` N=2¹⁰ vs N=2¹⁷ on desktop
*"since higher values crash older phones."*

**Three design decisions from `age` worth knowing** [V]
(https://github.com/C2SP/C2SP/blob/main/age.md):
- Domain-separated salt: `S = "age-encryption.org/v1/scrypt" || salt`.
- *"An scrypt stanza, if present, MUST be the only stanza in the header."* —
  prevents a weak-passphrase recipient being silently bolted onto a strong-key file.
- *"The identity implementation SHOULD apply an upper limit to the work factor,
  and it MUST check that the body length is exactly 32 bytes before attempting to
  decrypt it, **to mitigate partitioning oracle attacks**."*

That last one is the sharpest item in the section: a hostile blob can carry an
absurd work factor (DoS), and a variable-length body enables a partitioning
oracle letting an attacker test many passphrase guesses per query. Both are
non-obvious and both bite a hand-rolled implementation.

**BIP-38 is the cautionary tale** [V]: scrypt N=16384, r=8, p=8; header status
reads **`Comments-Summary: Unanimously Discourage for implementation`**. It failed
not because the crypto was wrong but because **parameters baked into a wire
format cannot be upgraded after the artifacts are printed.** Any blob must carry
its KDF parameters *in* it and support re-wrapping.

## QR / animated QR

Capacities above. Error correction [V]: L restores 7% of data bytes, M 15%,
Q 25%, H 30%.

**BC-UR** [V] (https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)
— worth understanding for its ideas even though multi-part is unnecessary here.
Motivation: *"Developers of cryptocurrency wallets currently all have their own
bespoke ways of breaking a binary message into several parts."* Format
`ur:<type>/<seqNum>-<seqLen>/<fragment>`. **Bytewords** encode into the QR
**alphanumeric** charset explicitly to *"Use the alphanumeric QR code mode for
efficiency"* — 5.5 bits/char vs 8, ~45% denser. CRC-32 of the whole message in
every part *"to tie them together"*. Fountain codes make the animation
loop-order-independent so a scanner can join mid-stream.

**What breaks** [R/reasoning]: autofocus hunting at close range; screen
auto-dim and OLED PWM beating against rolling shutter; frame rates above ~5–8 fps
outrunning the decode loop; reflections. And the deep one — **a QR is a bearer
token in the visual channel**, readable by any camera in the room, any
screen-recorder, any shoulder, and (see Q4) any gallery-scanning malware.
**[U]** on measured animated-QR failure rates; no published study found.

## iCloud Keychain / Android Block Store — the platform custodians

### iCloud Keychain

**E2EE, quoted** [V] https://support.apple.com/guide/security/icloud-keychain-security-overview-sec1c89c6f3b/web:
> "Keychain items are transferred from device to device, traveling through Apple
> servers, but are **encrypted end-to-end so that Apple and other devices can't
> read their contents.**"

**The escrow design** [V] https://support.apple.com/guide/security/escrow-security-for-icloud-keychain-sec3e341e75d/web:
> "The HSM cluster verifies that a user knows their iCloud security code using the
> **Secure Remote Password (SRP)** protocol" — and *"the code itself isn't sent to
> Apple."*
> "The escrow service allows only **10 attempts** to authenticate and retrieve an
> escrow record." … **"After the 10th failed attempt, the HSM cluster destroys the
> escrow record and the keychain is lost forever."**
> "These policies are coded in the HSM firmware. **The administrative access cards
> that permit the firmware to be changed have been destroyed.**"

**[U] on "device passcode":** Apple's escrow page frames the secret as the
**iCloud Security Code**, not the device passcode. The equivalence on modern iOS
is widely reported but **is not in the document**. Do not quote Apple as saying
"device passcode".

**`kSecAttrSynchronizable` constraints, quoted** [V]
https://developer.apple.com/documentation/security/ksecattrsynchronizable:
> "Items stored or obtained using the `kSecAttrSynchronizable` key **cannot
> specify SecAccess-based access control with `kSecAttrAccess`**."
> "…may not also specify a `kSecAttrAccessible` value that is incompatible with
> syncing (namely, those whose names end with `ThisDeviceOnly`)."
> "**Updating or deleting items using the `kSecAttrSynchronizable` key affects all
> copies of the item, not just the one on your local device.**"
> "Starting in iOS 14, macOS 11, and watchOS 7, the keychain synchronizes
> passwords, certificates, and cryptographic keys."

### Android Block Store

[V] https://developer.android.com/identity/block-store (the
`developers.google.com/identity/blockstore/android` URL 301-redirects here).

> "The Block Store API allows your app to store data that it can later retrieve to
> re-authenticate users on a new device."

**Size limits — the real numbers** [V]:
> "Block Store allows developers to save and restore up to **16 byte arrays**."
> "You can store this token using a unique key pair value that has a **maximum 4kb
> per entry**."

**E2EE is conditional** [V]:
> "In order for end-to-end encryption to be made available, the device must be
> running **Android 9 or higher, and the user must have set a screen lock** (PIN,
> pattern, or password)."
There is an `isEndToEndEncryptionAvailable()` check. **A user with no screen lock
gets a cloud backup Google can read.**

**The deletion footgun** [V] — nasty, and per-call rather than per-key:
> "If `storeBytes` is called with `shouldBackupToCloud` unset or set as false,
> then this device's bytes previously backed up to cloud **will be deleted from
> the cloud upon next periodic sync.**"

Also note *"Block Store will **periodically** backup to cloud"* — the write is not
synchronously durable; a device lost shortly after enrolment may have nothing
there.

**The biggest real-world failure mode** [R]: restore only happens during the
**new-device setup flow**. A user who skips it, or installs the app a week later,
gets nothing.

### Why the classic Android architecture silently fails

[V] https://developer.android.com/privacy-and-security/keystore:
> "**Key material never enters the application process.**"
> "When this feature is enabled for a key, **its key material is never exposed
> outside of secure hardware.**"

The Keystore docs do not literally say "keys are not backed up" [V — checked, that
sentence is not there], but it follows inescapably. **So "encrypt the seed with a
Keystore key and let Auto Backup carry the ciphertext" restores a ciphertext whose
key no longer exists anywhere in the universe.** The backup *succeeds*, the file
*is there*, and it is permanently undecryptable. Same trap for iOS items marked
`ThisDeviceOnly` or Secure-Enclave-protected. This corroborates `CRUCIBLE.md`'s
grounded note about Android auto-backup restoring undecryptable ciphertext.

Auto Backup itself [V]: covers shared prefs, internal storage, databases;
**25 MB** cap (*"the system calls `onQuotaExceeded()` and doesn't back up data"*);
E2EE on Android 9+ with a screen lock.

## Printed paper

**No published survival-rate study found. [U] — no number is invented here.**

The closest real empirical work is **Jameson Lopp's metal seed storage stress
tests** (six rounds, https://blog.lopp.net/metal-bitcoin-seed-storage-stress-tests-round-vi/)
[V on methodology]: **~2000 °F for 10 minutes** then water quench; *"submerged in
muriatic acid for 12+ hours"*; a **20-ton hydraulic press**. Multi-plate designs
commonly failed via **seized fasteners** — the plates survived, the screws welded
shut. Top performers *"each runs over €100 per device."*

**Lopp's rounds contain no paper control arm** [V] — which is itself the finding.
The genre assumes paper fails and never measures it.

**The failure mode that actually matters is not decay, it is non-use** — see the
CHI 2025 data below.

## What modern wallets actually do — the hallucination-prone section, handled carefully

### Published data on loss — what exists, and what does not

**CHI 2025 — the real peer-reviewed source.** Eleshin, Sun, Ye, Das, Hong, *"Of
Secrets and Seedphrases: Conceptual Misunderstandings and Security Challenges for
Seed Phrase Management among Cryptocurrency Users"*, DOI 10.1145/3706598.3713209.
Method [V via dblp/abstract]: interviews with **20** participants + survey of
**643**. Headline [V, from the abstract]: only **43.4%** could correctly recognise
an image of a seed phrase, and participants **conceptually conflated passwords
and seed phrases**, expecting them to be user-chosen and resettable.

**[U] — ACM DL returned 403 to both HTML and PDF.** The storage-practice numbers
circulating in secondary coverage ("only a quarter store on paper", "15% have
tested recovery", "22% shared their seed phrase for emergency recovery") **could
not be confirmed against the paper.** Treat as REPORTED-not-verified.

**The conflation finding is the one that should drive any design: users do not
model a seed phrase as *the key*. They model it as *a password* — resettable,
choosable, support-recoverable. Every part of that model is false for a sovereign
key, and no warning copy fixes a wrong ontology.**

**Oobit survey, April 2026** [V on the reporting, via agilitypr.com] — 1,000 US
crypto holders via CloudResearch Connect: *"35% of crypto holders have lost access
to a wallet or account"*, *"Nearly 1 in 3 (31%) of those never recovered their
funds"*, causes *"forgotten passwords (33%)"*, *"lost recovery or seed phrases
(21%)"*. **Caveat: vendor-commissioned, PR-wire, self-reported, US-only. Directional only.**

**Matrix/Element recovery-key loss rates: none published.** [V by search] Element's
analytics are opt-in and unpublished on this metric. The nearest real data is
adjacent-service, from the **PoPETs 2025 SoK** (*"SoK: Web Authentication and
Recovery in the Age of End-to-End Encryption"*,
https://petsymposium.org/popets/2025/popets-2025-0113.pdf, read directly),
quoting Holtervennhoff et al.'s survey of **281 Tutanota users**:

> "Approximately **12%** of users surveyed believed Tutanota could help them regain
> access in case of recovery code loss, and **only 14.8%** of users saved the
> recovery code in more than one location."

with the authors' own caveat that this population "is not representative… we may
anticipate user misconceptions to be **even higher** in a service targeted at a
mass audience." And the SoK's structural verdict, which any recovery-key design
should be made to answer:

> "The majority of service providers rely on asking the user to manually store a
> recovery key even as more usable variations are feasible, **a design choice that
> arguably makes end users less likely to enable E2EE backups and ultimately
> undermines [E2EE].**"

> "the expectation that users will handle retaining their own decryption keys…, **a
> PGP-era approach still the predominant strategy in use today**, may be a fair
> assumption with the risk assessment of E2EE messaging backups but **does not
> pass muster** with general cloud storage or authentication credential backups."

**Signal verification-ceremony data** [V, PDFs read directly]:
- *"When SIGNAL hits the Fan"* (EuroUSEC 2016): *"**21 of 28 participants failed
  to compare encryption keys**… **The majority of these users however believed
  they succeeded while in reality they failed.**"*
- Vaziripour et al. (SOUPS 2017): success *"increases from 14% to 79%"* between
  phases; *"the time required… is undesirably long"* — >3 min to *find*, >7.5 min
  to complete.
- Vaziripour et al. (SOUPS 2018): *"**a 25% discovery rate** for the
  authentication ceremony"* in unmodified Signal; redesign lifted completion
  30%→90%, median 7 min→2 min, but *"**many users are still unsure or confused
  about the purpose**"*, and *"a third of participants indicated that they would
  only want to use it… when they were sending sensitive information."*

**Headline: in unmodified Signal, 25% could even find the verification screen and
30% completed it.**

### The industry's actual direction

- **Coinbase Wallet** [R]: encrypted private-key backup to the user's *own* Google
  Drive / iCloud, AES-256-GCM, user-chosen password, Coinbase never holds it.
  Structurally: a passphrase-wrapped blob parked in consumer cloud. *"If you lose
  your password, you won't be able to access your funds."*
- **MetaMask** [R, from MetaMask's own posts]: **August 2025 social login** — the
  SRP is *"generated under the hood"*, recovered via a Google/Apple account +
  password; **2026 Embedded Wallets** — onboarding with Google, email, or SMS, no
  seed phrase, reported two-layer threshold cryptography. **MetaMask is the wallet
  that taught the world the seed phrase. It moving away is the strongest available
  evidence that the artifact lost on user-experience grounds, not cryptographic
  ones.**
- **MPC/TSS — and a distinction that is usually blurred** [R]:
  - **Zengo**: 2-of-2 threshold signatures via DKG; the key is genuinely **never
    whole**.
  - **Web3Auth/tKey**: Shamir 2-of-3 (device / OAuth-gated network / recovery).
    *"the Web3Auth Infrastructure only has access to one share."* **But in the
    plain non-MPC tKey variants the key IS reassembled client-side.**
  - **Privy**: 3 shares, key **reconstructed inside a TEE**, used, *"immediately
    wiped"*. **Privy's key does become whole, briefly.** Materially different from
    Zengo; should not be described as "never whole."
  - **Coinbase WaaS**: **[U]**, not researched. Do not characterise it.
- **Social recovery** — Vitalik, Jan 2021, https://vitalik.eth.limo/general/2021/01/11/recovery.html
  [V], and the sentence that matters most here:
  > a mnemonic backup introduces *"a **new** vector for theft: if you have the
  > standard hardware wallet + mnemonic backup combo, then someone stealing
  > **either** your hardware wallet + PIN **or** your mnemonic backup can steal
  > your funds."*
  > and *"maintaining a mnemonic phrase and not accidentally throwing it away is
  > itself a non-trivial mental effort."*

  Argent [R]: guardians can **only rotate the owner key, never sign
  transactions**, with a security delay the original signer can cancel. **The
  exact delay is [U]** — secondary sources gave 36h, 48h and 5 days
  inconsistently and Argent's pages 403'd. Do not cite a number.

  **The transferable idea, independent of blockchain: the recovery credential is
  not the key; guardians rotate *which* key is authoritative. That requires an
  identity that can outlive its current key.**

### Passkey / WebAuthn PRF — the newest mechanism, and its support is genuinely messy

**Spec** [V] https://w3c.github.io/webauthn/#prf-extension — the PRF extension
lets an RP derive symmetric key material from a credential; it is the
WebAuthn-level surface over CTAP2's `hmac-secret`. Chromium's Intent to Ship
[V]: *"The PRF extension to WebAuthn allows a pseudo-random function (i.e. HMAC),
stored on the security key, to be evaluated when getting a credential."*

Support caveats, each honoured:
- Chromium's Intent [V]: *"Support on Windows depends on having a recent version
  of Windows. **Not every security key supports the underlying hmac_secret
  functionality.**"* and *"Some passkey providers on Android 14 may not support
  it."* **It names no shipping milestone** — **[U]** on which Chrome version.
- [R] Google Password Manager passkeys: strongest support. iOS 18 / Safari added
  PRF for iCloud Keychain passkeys with early-18.x bugs fixed by 18.4. Chrome 147
  PRF-on-create for Windows Hello.
- **[U], and this is the important one:** WebAuthn L3 defines `eval` at
  `create()`, but **many authenticators cannot evaluate PRF during registration**
  and require a follow-up `get()`. Any design must assume a possible second
  ceremony immediately after creation.
- **[R] A capability signal that lies:** an Apple developer forum thread reports
  Apple returning `prf: {enabled: true}` *without* the underlying `hmac-secret`.
  **Probe by deriving and comparing, never by reading the flag.**
- **`largeBlob`** [U]: the commonly-cited "1 KB" limit **could not be found in the
  spec or Yubico's docs**. Do not cite it as a spec number. The distinction that
  matters: **largeBlob stores your ciphertext; PRF derives your key.**

### Why the industry moved — the synthesis

Not a cryptographic break. Three forces, in order of weight:

1. **Users cannot hold the concept** (CHI 2025) — the artifact fails at the
   *ontology* layer, below anything UX copy can reach.
2. **A mnemonic is simultaneously the only loss-protection and a second theft
   vector** (Vitalik). Copies reduce loss and increase theft; hiding reduces theft
   and increases loss. **There is no good setting of that dial**, which is why the
   industry stopped turning it and changed the mechanism.
3. **Onboarding drop-off** at the seed-phrase step — widely claimed at 60–90%,
   **[U], found only in vendor marketing; no peer-reviewed figure.**

**The structural convergence:** the secret is **split** (Shamir/TSS), or **wrapped
by a credential the platform already manages and syncs** (passkey PRF, iCloud
Keychain, Block Store), or **made rotatable behind an account abstraction**
(social recovery). The one thing everybody abandoned is *handing the user 24 words
and hoping*.

---

# Q4 — THE HONEST SECURITY TRADEOFF

`CRUCIBLE.md` bets the temper lands hardest on falsifier #3. **The evidence says
that bet is correct, and there is a primary source that argues it in exactly this
case.**

## The canonical literature, and it lands directly on signing keys

Abelson, Anderson, Bellovin, Benaloh, Blaze, Diffie, Gilmore, Neumann, Rivest,
Schiller, Schneier, *The Risks of Key Recovery, Key Escrow, and Trusted
Third-Party Encryption*, 27 May 1997 [V, PDF read]
https://www.schneier.com/wp-content/uploads/2016/02/paper-key-escrow.pdf

**§2.2, "Authentication vs. Confidentiality Keys", verbatim:**

> "some key recovery schemes are designed to archive authentication and signature
> keys along with confidentiality keys. Such schemes **destroy the absolute
> non-repudiation property** that makes binding commitments possible. Furthermore,
> **there are simply no legitimate uses for authentication or signature key
> recovery.**"

> "It has been claimed that non-availability of a signature key can be a serious
> problem for the owner… But common practice allows for the **revocation** of lost
> keys, and the issuance of new keys with the same rights and privileges as the
> old ones. **Recovering lost signature and authentication keys is simply never
> required.**"

And §2.1: *"Key recoverability, to the extent it has a private-sector application
at all, is useful only for **stored data**."*

Plus the general finding: *"All key-recovery systems require the existence of a
**highly sensitive and highly-available secret key or collection of keys** that
must be maintained in a secure manner over an extended time period."*

**This is the strongest single argument against the ore, and it must be put in
front of the temper without softening.**

**The counter-argument — reported, not endorsed, because it is the research's own
reading rather than a source's:** the 1997 authors' escape hatch is *"revocation
and the issuance of new keys with the same rights and privileges."* That
presupposes a working revocation-and-reissue infrastructure. In a
sovereign-identity system with no central directory, re-issuance costs the user
their social graph, their history's attributability, and their name. **Whether
that escape hatch is available is a factual question about aiko's specific
architecture, and it is the hinge of the whole tradeoff.** If re-issuance is
cheap, the literature says don't build export. If it is not, a design choosing
recoverability is overriding a 29-year-old consensus and owes an explicit
statement of that. [The framing is the researcher's; the quotes are [V].]

The 2015 successor, *Keys Under Doormats* (Journal of Cybersecurity 1(1)),
restates the argument for the modern era:
https://www.schneier.com/wp-content/uploads/2016/02/paper-keys-under-doormats.pdf

## How messaging apps actually resolve it — two opposite, principled answers

**WhatsApp: recoverability, bought with an HSM.** [V, whitepaper PDF read —
*Security of End-To-End Encrypted Backups*, dated **2026-05-01** in the copy
read; source page https://www.whatsapp.com/security/]:

> "An encrypted version of the key is stored in the HSM Backup Key Vault… **The
> HSM Backup Key Vault is responsible for enforcing password verification attempts
> and rendering the key permanently inaccessible after a certain number of
> unsuccessful attempts.**"
>
> "the users have a choice to use a **64-digit encryption key** instead of a
> password… **in this case the key is not sent to the HSM Backup Key Vault**."
>
> "At the heart of the key K registration… is the **OPAQUE protocol**… allows the
> record to be secured with a password, **without disclosing the actual
> password**."
>
> "The cryptographic strength of K… is 256 bits, i.e. 32 bytes."

And WhatsApp's own operational caveat: *"we recommend that users who opt in to
end-to-end encrypted backups **also deselect WhatsApp from the apps that are
included in their device-level backups**"* — the platform backup is an
exfiltration path they had to tell users to close by hand.

**Signal: secrecy, no recovery.** [V] https://signal.org/blog/introducing-secure-backups/:
> "**Losing it means losing access to your backup permanently, and Signal cannot
> help you recover it.**"

**There is no third option that is both recoverable and has no escrow surface.
That is the entire design space.**

## What a user-facing export actually opens — grounded in real incidents

**Gallery-OCR malware hunting recovery phrases. This is real and it is recent.**
[V, Kaspersky Securelist primary]:
- **SparkCat** (Feb 2025, https://securelist.com/sparkcat-stealer-in-app-store-and-google-play/115385/):
  a malicious SDK on **both Google Play and the App Store** — *"the first time a
  stealer had been found in Apple's App Store."* Android infected apps had
  *"more than 242,000 downloads."* Active since March 2024. It decrypted and
  launched an **OCR plug-in built on Google's ML Kit**, scanned the gallery, and
  uploaded images matching multilingual keywords for "mnemonic"/"助记词".
- **SparkKitty** (June 2025, https://securelist.com/sparkkitty-ios-android-malware/116793/):
  successor, *"active since at least February 2024"*, shipped inside an iOS crypto
  tracker app; Apple removed it 2025-06-25. Most variants **exfiltrate the entire
  gallery indiscriminately**.
- A further variant reported 2026 [R].

**Design consequence:** the *screenshot* of an export screen is the asset the
malware harvests, and users screenshot recovery material by default. **A QR-code
export is arguably worse than text here** — OCR-resistant image data still sits in
the gallery and a QR is trivially machine-readable.

**Android accessibility-service abuse defeats every UI-level gate you can build.**
[V, ThreatFabric primary]: Cerberus — *"After users grant Cerberus the
accessibility service privilege, it abuses this by granting itself additional
permissions… without requiring any user interaction."* Octo — live screen
streaming plus remote actions, **with a black-screen overlay to hide the
operation from the victim**. Anatsa (2025 wave, ~90,000 users via a fake PDF app
on Play), Crocodilus (2025). Google Play policy restricts the API [V] — it *"cannot
be used to… work around Android built-in platform security controls"* — **but
policy does not stop sideloaded malware.** Accessibility can read the export text
off-screen, dismiss the warning dialog, and tap "Reveal".

**Clipboard is a system-wide bus.** [V] ClipBanker *"replaces cryptocurrency
addresses in the clipboard with the attacker's own"*. A "Copy to clipboard"
affordance on an export screen puts a 32-byte secret where any app can read it.

**The social-engineering second-order effect — the most important item in Q4.**
Ledger's 2020 breach (~1M emails, https://haveibeenpwned.com/Breach/Ledger)
became multi-year phishing feedstock escalating to **physical mail on branded
stationery with a QR code asking for the 24-word phrase** [R] and **fake Nano
devices mailed to victims' homes** [R]. Coinbase, May 2025 [V, CNBC + Coinbase
blog + SEC 8-K]: attackers **bribed outsourced support agents** to export customer
data; ~70,000 customers, $20M ransom refused, up to $400M remediation.

> **The existence of an export feature is what makes "read me your recovery key" a
> *plausible* support request. Before the feature exists, the scam has no script.**

**Coerced export.** [R] Jameson Lopp's public dataset
(https://github.com/jlopp/physical-bitcoin-attacks) — >260 recorded physical
attacks since 2014; 2025 widely reported as a record year (~70 vs ~41 in 2024,
+169%); ~25% home invasions, ~23% kidnappings. **The counts are REPORTED; the
dataset was not re-counted.**

**Legally compelled export.** [V, statute] UK RIPA 2000 Part III §49 notices
compel disclosure of keys or plaintext; §53 makes knowing failure an offence
carrying **up to 2 years (5 for national-security/CSAM cases)**.
https://www.legislation.gov.uk/ukpga/2000/23/part/III/crossheading/offences/enacted
**An exportable key changes the user's legal posture: a key that cannot be
exported makes compliance impossible; a key that can be exported makes refusal an
offence.** [U] on US border-search/compelled-decryption doctrine — not researched.

## Mitigations — what they guarantee, and what they do not

**Two very different things are called "a biometric gate", and the difference is
cryptographic:**

1. **`LAContext.evaluatePolicy` (what `local_auth` does)** [V]: *"You then receive
   an asynchronous callback, which provides an indication of authentication
   success or failure."* **It returns a boolean.** A UI assertion, not a
   cryptographic one. A hooked binary or an accessibility-driven flow routes
   around it.
2. **`kSecAccessControlBiometryCurrentSet`** [V]: *"Constraint to access an item
   with Touch ID for currently enrolled fingers… **The item is invalidated if
   fingers are added or removed for Touch ID, or if the user re-enrolls for Face
   ID.**"* Contrast `biometryAny` [V]: *"The item is **still accessible** by Touch
   ID if fingers are added or removed"* — i.e. `biometryAny` does **not** protect
   against an attacker who knows the passcode and enrolls their own face.
3. Android `setUserAuthenticationRequired(true)` [V]: *"The key will become
   **irreversibly invalidated** once the secure lock screen is disabled… it is also
   irreversibly invalidated once a new biometric is enrolled or once no more
   biometrics are enrolled, unless `setInvalidatedByBiometricEnrollment(boolean)`
   is used."*

**What none of them guarantee:** neither stops a coerced user (**the wrench attack
defeats biometrics *faster* than a password** — the attacker needs only your
face and the phone). Neither stops accessibility malware driving the legitimate
UI *after* the user authenticates. And the strong variants create a
**recoverability hazard**: the key is destroyed on biometric re-enrollment or
lock-screen change — **exactly the availability failure an export feature exists
to prevent.**

**Screenshot blocking is asymmetric between platforms** [V]:
- Android `FLAG_SECURE`: *"treat the content of the window as secure, preventing
  it from appearing in screenshots or from being viewed on non-secure displays."*
- **iOS has no public equivalent.** Apple ships only *detection*: `UIScreen.isCaptured`
  — *"Observe this property and optionally take an appropriate action in your app
  to prevent the capture of your content"* — plus
  `userDidTakeScreenshotNotification`, which fires *after* the shot. The
  widely-used blocking technique is the **undocumented `UITextField.isSecureTextEntry`
  layer trick**, not an API contract. **Scope note: this is a negative verified by
  absence-of-API-in-docs plus an unanswered Apple forum thread — weaker than a
  positive, and worth a second instrument if it becomes load-bearing.**

**Time delays have strong first-party precedent.** **Apple Stolen Device
Protection** is the closest analogue [V] https://support.apple.com/en-us/120340:
certain actions require Face ID/Touch ID **with no passcode fallback**, and
critical changes carry a **one-hour Security Delay** requiring biometric auth
**twice — once before and once after the delay**. Exchange analogues [R]: Coinbase
24-hour withdrawal hold after password reset; Binance 24–48h that *cannot be
lifted early*; Crypto.com 24h on new withdrawal addresses.

> **The delay's value is that it converts a silent theft into a race the
> legitimate user can win — but only if the notification channel is one the
> attacker does not also control.**

**Duress/decoy credentials: a plausibility mechanism, not a cryptographic one.**
[R] Trezor's passphrase model has no "wrong" passphrase, so every passphrase opens
*a* wallet. **Trezor's own blog publishes the counter-case** ("3 reasons why you
maybe shouldn't"). Criticisms found [R, community-grade]: deniability fails
against a well-informed attacker and **escalates the coercion**; Trezor Suite
always shows "+ Passphrase Wallet" so the *existence* of hidden wallets is public;
a decoy with no plausible transaction history is not plausible; Monero GUI has an
open issue that its passphrase provides **no** plausible deniability
(monero-project/monero-gui#2186). **Treat any duress proposal as needing its own
threat model, not as a free add-on.**

**Passphrase re-entry before export**: universal, but **[U] — no published
effectiveness data found.** Its honest value is as a *deliberation* gate, not an
attacker barrier: an attacker who coerced or phished the user has the passphrase
too.

**Notification-on-export**: **[U]** as an isolated measure; structurally identical
to the exchange holds above, and worthless without a channel the user sees.

**Platform guidance is unambiguous and points the other way.** [V] Both Apple and
Google design toward **non-extractable** keys (Secure Enclave / StrongBox).
**An exportable 32-byte seed stored as *data* in `flutter_secure_storage` is
already a deliberate step down from that model; an export UI is a second step.**
That is a real, nameable tradeoff, not a nitpick.

---

# Q5 — FLUTTER / DART: AVAILABILITY AND MATURITY

**No recommendation is made here.** All metadata [V], read from pub.dev's own API
(`/api/packages/<name>`, `/score`) on **2026-09-16**. None of the listed packages
carry pub.dev's `isDiscontinued` flag.

## Crypto / KDF

| Package | Publisher | Latest | Published | Points | Likes | 30d downloads |
|---|---|---|---|---|---|---|
| `cryptography` | `dint.dev` | 2.9.0 | 2025-11-21 | 130/160 | 314 | 741,736 |
| `cryptography_flutter` | `dint.dev` | 2.3.4 | 2025-11-21 | 160/160 | 37 | 59,220 |
| `cryptography_plus` | `emz-hanauer.com` | 3.0.0 | 2026-03-02 | 130/160 | 13 | 25,152 |
| `pointycastle` | `bouncycastle.org` | 4.0.0 | 2025-02-19 | 140/160 | 415 | 3,503,034 |
| `argon2` | *(none)* | 1.0.1 | 2021-06-18 | 120/160 | 19 | 17,696 |
| `dargon2` | `tmthecoder.dev` | 3.2.1 | 2022-07-08 | 70/160 | 9 | 437 |
| `dargon2_flutter` | `tmthecoder.dev` | 3.3.0 | 2023-06-18 | 150/160 | 13 | 1,725 |

**`cryptography` algorithm coverage** [V, by reading
`lib/src/cryptography/algorithms.dart` on master]: **Argon2id YES**
(`abstract class Argon2id extends KdfAlgorithm`), **PBKDF2 YES**, **HKDF YES**,
**Ed25519 YES**. **scrypt NO** — verified negatively via the GitHub recursive tree
API; no `scrypt` file anywhere in the repo.

**The load-bearing maturity finding:** `cryptography_flutter` accelerates **only
Ed25519 and PBKDF2** via platform APIs — its native files are
`flutter_ed25519.dart`, `flutter_pbkdf2.dart`, `background_pbkdf2.dart`. **There
is no `flutter_argon2.dart`.** Argon2id in this ecosystem is **pure Dart only**
(`lib/src/dart/argon2.dart`). The repo ships `test/benchmark/argon2.dart`,
implying the authors knew it needs benchmarking. **[U] — no timing measured.
Whether pure-Dart Argon2id is usable interactively on a mid-range phone is the one
cheap decisive measurement this whole area needs, and it determines whether the
ecosystem forces `pointycastle` / an FFI binding / natively-accelerated PBKDF2
instead.**

**"`cryptography` went unmaintained" — was true, is now stale.** [V] The
`cryptography_plus` fork README states: *"Repository was moved to
emz-hanauer/dart-cryptography **due to lack of maintenance**"* (fork first
released 2024-10-24). **But upstream resumed**: `dint-dev/cryptography` last
pushed 2025-11-21 publishing v2.9.0 that day, not archived, 188 stars. The fork is
more recently pushed but has ~3% of upstream's downloads.

**`pointycastle` is the maintained heavyweight** [V]: published by
`bouncycastle.org`, 3.5M downloads/month, and it has **both**
`lib/key_derivators/scrypt.dart` and `lib/key_derivators/argon2.dart` (two impls:
`argon2_native_int_impl.dart`, `argon2_register64_impl.dart`), plus PBKDF2, HKDF,
ConcatKDF. Latest 4.0.0 is 2025-02-19.

**`argon2` / `dargon2` / `dargon2_flutter` are effectively dormant** — last
publishes 2021, 2022, 2023. `dargon2` uses FFI to the reference C library (so it
would be fast) but nothing has shipped in 3–4 years.

## BIP-39

| Package | Publisher | Latest | Published | Points | Likes | 30d dl |
|---|---|---|---|---|---|---|
| `bip39` (anicdh) | none | 1.0.6 | **2021-03-23** | 120/160 | 57 | 43,229 |
| `bip39_mnemonic` | `ethicnology.com` | 4.1.0 | **2026-08-02** | 160/160 | 13 | 12,409 |

**A supply-chain finding, not a nitpick** [V]: `bip39` is popular by inertia,
unpublished for **5½ years**, has **no verified publisher**, and its GitHub repo
`anicdh/bip39` **returned 404** from the API — likely deleted or renamed.
`bip39_mnemonic` is the actively maintained one (160/160, verified publisher,
published six weeks ago).

## QR

| Package | Publisher | Latest | Published | Points | Likes | 30d dl | Repo last push |
|---|---|---|---|---|---|---|---|
| `qr_flutter` (generate) | `theyakka.com` | 4.1.0 | 2023-05-14 | 150/160 | 2,336 | 1,883,503 | 2024-06-28 |
| `mobile_scanner` (scan) | `steenbakker.dev` | 7.4.2 | **2026-09-14** | 160/160 | 2,301 | 1,431,779 | active |
| `qr_code_scanner` (scan) | none | 1.0.1 | 2022-08-15 | **60/160** | 2,147 | 324,696 | 2024-07-31 |

**`qr_code_scanner` is self-declared dead and names its own successor** [V,
README first line]:
> "# Project in Maintenance Mode Only
> Since the underlying frameworks of this package, zxing for android and
> MTBBarcodescanner for iOS are both **not longer maintaned**, this plugin is no
> longer up to date… I am developing a new plugin **[mobile_scanner]**"

**Note the instrument failure:** pub.dev's `isDiscontinued` flag is still `false`.
Only the README carries the truth. `mobile_scanner` is by the same maintainer as
`flutter_secure_storage`. `qr_flutter` is enormously used but stagnant (last
publish May 2023, repo last pushed June 2024, 51 open issues).

## Android Block Store from Flutter

**Not "none" — but close enough to be a finding.** [V]

| Package | Publisher | Latest | Published | Points | Likes | 30d dl |
|---|---|---|---|---|---|---|
| `play_services_block_store` | `c-wolf.dev` | 0.8.0 | 2025-06-16 | 140/160 | **1** | **193** |
| `flutter_block_store` | `saddamnur.xyz` | 0.0.2 | 2023-07-08 | 130/160 | **3** | **64** |
| `android_restore_credentials` | `wunderbytes.eu` | 0.1.0 | 2026-09-03 | 160/160 | 5 | 77 |

**There is no first-party or community-consensus Block Store plugin.** The most
serious attempt is pre-1.0, single-maintainer, **1 like, 193 downloads/month**.
`android_restore_credentials` is the adjacent *Credential Manager Restore
Credentials* API rather than Block Store proper, at 0.1.0 with one published
version. **Any of these is effectively a "you will be maintaining a fork"
dependency.**

## `flutter_secure_storage` — iCloud sync, access control, and a mutual exclusion

Publisher `steenbakker.dev`, **latest 11.1.1, published 2026-09-11**, 160/160,
4,488 likes, **4,156,821 downloads/month**. Actively maintained (repo moved from
`mogol` to `juliansteenbakker`). **This repo's `pubspec.yaml` pins `^10.3.1` — one
major behind.**

**Yes, it exposes `kSecAttrSynchronizable`** [V, verified three ways: Dart source,
published API docs for 11.1.1, and the native Swift]. From
`flutter_secure_storage/lib/options/apple_options.dart`:
```dart
/// `kSecAttrSynchronizable`: **Shared**.
/// Indicates whether the keychain item should be synchronized with iCloud.
/// `true` enables synchronization, `false` disables it.
final bool synchronizable;
```
Constructor default `false`. **The README never mentions it** [V, checked] — the
option is API-real and native-wired but documentation-invisible.

It also exposes access control and the Secure Enclave [V]:
```dart
enum AccessControlFlag {
  devicePasscode, biometryAny, biometryCurrentSet, userPresence,
  watch, or, and, applicationPassword, privateKeyUsage,
}
```
plus `List<AccessControlFlag> accessControlFlags` and `bool useSecureEnclave`.

**The finding that matters most for an export design** [V, the plugin's own Swift
comment]:
```swift
// Without flags, skip SecAccessControl so kSecAttrSynchronizable is not silently dropped by the Security framework.
guard let flagString = params.accessControlFlags, !flagString.isEmpty else { return nil }
```
**You cannot have both iCloud sync and biometric access control on the same
keychain item** — attaching a `SecAccessControl` causes the Security framework to
silently drop `kSecAttrSynchronizable`. Corroborated by Apple's own doc, quoted in
Q3.

**Android side** [V, README]: v10.0.0 changed default ciphers to RSA-OAEP +
AES-GCM and added `AndroidOptions.biometric(enforceBiometrics: …)` —
*"Requires API 28+ for biometric enforcement"*; `biometricType:
AndroidBiometricType.strongBiometricOnly` restricts to **Class 3 biometrics only,
rejecting PIN/pattern/password**. Min SDK now 23.

## Screenshot blocking

| Package | Publisher | Latest | Published | Points | Likes | 30d dl | Repo last push |
|---|---|---|---|---|---|---|---|
| `no_screenshot` | `flutterplaza.com` | 2.0.1 | 2026-08-08 | 160/160 | 289 | 114,704 | **2026-09-15** |
| `screen_protector` | `inteniquetic.com` | 1.5.3 | 2026-07-14 | 150/160 | 324 | 111,381 | 2026-07-14 |
| `flutter_windowmanager` | `adaptant.io` | **0.2.0** | **2021-08-26** | 160/160 | 368 | **3,840** | **2023-08-20** |

`flutter_windowmanager` is **abandoned** — last publish five years ago, repo
untouched since Aug 2023, downloads collapsed to 3,840/mo against 114k for
`no_screenshot` **despite having more likes** (368 vs 289): the classic signature
of a package people starred years ago and migrated off.

**`no_screenshot`'s iOS ✅ is the undocumented trick, verified** [V, its own iOS
source]: *"Temporarily lift screenshot prevention so the overlay image is
[visible] (secure text field would show a blank screen)"*. **So that checkmark is
a behavioural claim about an Apple implementation detail, not an API guarantee.**
It can break in any iOS release.

## Biometric gate

`local_auth`, publisher **`flutter.dev`** (first-party), **latest 3.0.2,
published 2026-07-09**, 160/160, 3,376 likes, 1,343,183 downloads/month [V].

**It returns a boolean** (see Q4). What actually gates key material is
`flutter_secure_storage`'s `accessControlFlags`/`useSecureEnclave` on Apple and
`AndroidOptions.biometric(enforceBiometrics: true)` on Android — with the two
caveats already named: mutually exclusive with iCloud sync, and
`biometryCurrentSet` / Android enrollment-invalidation **destroy** the item on
biometric re-enrollment or lock-screen removal.

---

# CONSTRAINTS + OTHERS' FAILURE MODES

> Handed to the movement that must find what breaks. Each item is a thing that is
> hard, or a thing that bit someone real.

## C1. A signature can never carry ordering or completeness

Authenticity is free and offline. "No earlier competing claim exists" is a
statement about **absence** and no signature can make it. Every surveyed system
that needed it bought it from somewhere: a hash chain, a Merkle tree, a blockchain
anchor, a timestamp plus a waiting period, a relay cartel, or a directory. **A
registry-less protocol (Nostr) reinvented the registry and called it a trusted
relay set — its own draft says "the entire network MUST use the same set."**

## C2. Adding succession can make the *pre-compromise* case strictly worse

Verbatim from Nostr PR #2137's author [V]: *"the attacker can execute the
migration flow himself… **This is worse than the status quo**, since currently
users retain the ability to spam an identity."* Any pre-commit not yet published
is a window in which an attacker gains a **permanent lockout capability they did
not previously have**. This is the sharpest self-reported failure mode in the
corpus, and it comes from a designer arguing *for* his own proposal.

## C3. One-way announcement is the recurring bug — succession needs mutual attestation

Found independently three times:
- OpenPGP 0x18 subkey binding **MUST** embed a 0x19 counter-signature by the
  subkey (2007).
- Keybase's `sibkey` link carries `reverse_sig` *"so that a user can't claim
  another user's key as their own."*
- SSH's draft §5.2: *"**MUST not record new host keys without verifying private
  key possession proofs**… allows an attack where a malicious server advertises a
  host key for a different legitimate server."*
- And `draft-ietf-openpgp-replacementkey` rediscovers the same shape for whole
  primary keys with its forward/backward reference bit.

**Any design that lets one party *announce* a successor without the successor
*proving possession* has this hole.**

## C4. A pre-generated kill-switch structurally cannot name a successor

Proved in a live packet dump [V]: GnuPG's auto-generated revocation cert carries
reason code **`0x00` — "No reason specified"** — because at generation time the
successor does not exist. Corroborated from the standards side:
`draft-ietf-openpgp-replacementkey-08` §4 — *"If a replacement… is unknown, then a
Replacement Key subpacket SHOULD NOT be included."* **The kill switch and the
succession pointer are mutually exclusive in one artifact.**

## C5. Users model a seed phrase as a password, not as a key

CHI 2025: **43.4%** could correctly recognise an image of a seed phrase; users
expected it to be user-chosen and resettable. **This is an ontology failure, below
anything UX copy can reach.** Corroborated by the PoPETs 2025 SoK's judgement that
manual recovery-key storage *"arguably makes end users less likely to enable E2EE
backups and ultimately undermines [E2EE]."*

## C6. Verification ceremonies are not performed, and failure is invisible to the user

Measured, repeatedly: **21 of 28** Signal participants failed to compare keys and
*"the majority of these users however believed they succeeded while in reality
they failed"*; **25%** discovery rate for the ceremony in unmodified Signal, 30%
completion; >7.5 min to complete when found.

## C7. A recovery artifact stored in exactly one place is the norm, not the exception

Tutanota survey (n=281): **only 14.8%** saved the recovery code in more than one
location, and **12%** believed the provider could help them recover.

## C8. Matrix's specific bitten-by list

- **Chronic UTD/UISI** (element-meta#245, open since 2022-04-28, `S-Major`,
  `Z-Chronic`). Keys go only to devices logged in *at send time*; once the sender
  logs out the message is **permanently** undecryptable.
- **A reset is scorched earth, not a re-key** — it deletes the key backup and
  forces every contact to re-verify.
- **"Identity has changed" is incomprehensible.** Verbatim from a reporter: *"the
  message talks about a person's identity having changed. The identity of the real
  life person surely has not changed"* and *"the message says 'might' but what
  does that mean?"* — `X-Needs-Design`, no maintainer reply.
- **Self-referential banner bug**: after resetting, Element Web shows *you* the
  "this user has reset their identity" banner about **yourself**.
- **Terminology collision**: Security Key / Recovery Key / Security Phrase, with
  an open meta issue about it. The spec itself retired the term "recovery key".
- **A checker whose absent value means valid**: SSSS's key-check properties are
  optional, and *"If they are not present, clients must assume that the key is
  valid."*
- **A frozen bug as the contract**: the megolm backup MAC passes an empty string
  due to a libolm bug; *"all implementations have since passed an empty string."*
- **No iteration-count floor** in SSSS's PBKDF2; a client can write `iterations: 1`.

## C9. The platform backup paths silently produce undecryptable data

Android Keystore key material *"never enters the application process"* → a
Keystore-wrapped ciphertext carried by Auto Backup **restores successfully and is
permanently undecryptable**. Same for iOS `ThisDeviceOnly` / Secure Enclave items.
**The backup-exists check passes and the restore fails.**

## C10. Block Store's specific footguns

- **Per-call, not per-key**: *"If `storeBytes` is called with `shouldBackupToCloud`
  unset or set as false, then this device's bytes previously backed up to cloud
  **will be deleted from the cloud** upon next periodic sync."*
- **Conditional E2EE**: requires Android 9+ **and a screen lock**. Without one,
  the cloud copy is Google-readable.
- **"Periodically"** — not synchronously durable.
- **Restore only fires during new-device setup** [R]; a user who installs the app
  later gets nothing.

## C11. iCloud sync and biometric access control are mutually exclusive

Apple: synchronizable items *"cannot specify SecAccess-based access control"* and
cannot use `…ThisDeviceOnly` accessibility. `flutter_secure_storage`'s own Swift
comment names the failure as **silent**. Also: *"Updating or deleting items using
the `kSecAttrSynchronizable` key affects all copies of the item."*

## C12. iOS cannot block screenshots; only detect them, after the fact

And the leading Flutter plugin's iOS ✅ rests on an **undocumented
`isSecureTextEntry` layer trick**, verified in its own source. **Scope note: the
"no public API" claim is a negative verified by docs-absence plus an unanswered
Apple forum thread.**

## C13. UI-level gates do not survive accessibility-service malware

Octo demonstrates remote control **with a black-screen overlay hiding the
operation from the victim**. Any "reveal + confirm + warn" flow is driveable by
malware that already has the accessibility grant.

## C14. Gallery-OCR malware specifically hunts recovery phrases, on both stores

SparkCat (242,000+ Android downloads; **first stealer found in Apple's App
Store**) and SparkKitty. The screenshot is the asset. **A QR export is not safer
here — it is machine-readable by construction.**

## C15. The export feature writes the social-engineering script

The Ledger-breach mail campaigns and the Coinbase bribed-support-agent breach are
the shape. **Before an export feature exists, "read me your recovery key" is not a
plausible support request.**

## C16. The 1997 consensus says signature-key recovery has no legitimate use

*"there are simply no legitimate uses for authentication or signature key
recovery"* and *"Recovering lost signature and authentication keys is simply never
required"* — on the premise that revocation-and-reissue is available. **The design
must either show that premise holds, or say out loud that it is overriding this.**

## C17. Biometric hardening and recoverability pull in opposite directions

`biometryCurrentSet` and Android's default enrollment-invalidation **irreversibly
destroy** the protected item on biometric re-enrollment or lock-screen change —
manufacturing the exact availability failure the backup exists to prevent.

## C18. Dart/Flutter ecosystem constraints

- **No native Argon2 acceleration** in `cryptography_flutter`; only Ed25519 and
  PBKDF2. Pure-Dart Argon2id performance on a mid-range phone is **unmeasured**.
- **No scrypt** in `cryptography` at all (verified negatively over the repo tree);
  `pointycastle` has both.
- **`bip39` (the popular one) is unmaintained since 2021, has no verified
  publisher, and its GitHub repo 404s.**
- **No credible Block Store plugin** — the best has 1 like and 193 downloads/month.
- **`qr_code_scanner` is dead but pub.dev's discontinued flag says `false`** — the
  automated signal misses it; only the README carries the truth.
- **Keybase's mobile scrypt ceiling**: N=2¹⁰ on mobile vs 2¹⁷ desktop *"since
  higher values crash older phones."*

## C19. BIP-39's passphrase fails silently, by spec

*"every passphrase generates a valid seed… but only the correct one will make the
desired wallet available."* A typo produces a valid, empty, different identity
with no error. And the checksum localises nothing — it says *that* the phrase is
wrong, never *which word*.

## C20. Parameters baked into a printed artifact cannot be upgraded

BIP-38's epitaph: `Comments-Summary: Unanimously Discourage for implementation`.
Its scrypt parameters were a 2012 browser-performance compromise and both halves
aged badly. **Whatever ships must carry its KDF parameters inside the blob and
support re-wrapping.**

## C21. Partitioning-oracle and work-factor DoS on any passphrase-wrapped blob

age's spec: *"MUST check that the body length is exactly 32 bytes before
attempting to decrypt it, **to mitigate partitioning oracle attacks**"*, and
*"SHOULD apply an upper limit to the work factor."* Both bite hand-rolled
implementations.

## C22. Time-locks are a real UX cost, named by the people proposing them

staab: *"**The waiting period creates poor UX, where someone's account is in limbo
for a pretty long time**… especially bad if an attacker has their key and they
can't dissociate themselves immediately."*

## C23. A rotation-key backup shared with a friend is publicly linkable

did:plc, verbatim: *"**if two individuals cross-share rotation keys as a trusted
backup, that information is public.** If device-local recovery or signing keys are
uniquely shared by two identifiers, that would indicate that **those identities
may actually be the same person**."* And the whole operation history is
*"permanently publicly accessible… even after DID deactivation."*

## C24. Distribution, not verification, is where PGP actually died

SKS: an unauthenticated, append-only, permanent write channel letting any third
party attach unbounded data to anyone's certificate. *"Poisoned certificates
cannot be deleted from the keyserver network."* And the kill switch can be
published while the relying party's tool declines to read it — GnuPG marked the
keys.openpgp.org compatibility patch **Wontfix** in March 2020.

## C25. Implementation risk is a first-class objection in this space

vitorpamplona, on Nostr migration: *"in the same way that we tell people to never
put their nsecs in any client, **we should tell users to never do any migration
function in a regular client**"*, enumerating: clients not checking timestamps
correctly, clients leaking access to other keys, *"clients trying to migrate all
the account info from one key to another, **establishing a link in some other
way**"*.

---

# SOLUTION SPACE

> Handed to the movement that must build something. These are mechanisms prior art
> actually used, with what each buys and what it costs. **No recommendation for
> aiko is made here.**

## S1. Mutual (bidirectional) attestation — the universal shape of a sound succession

Three shipped instances of one pattern:
- **OpenPGP 0x18/0x19** (2007, universal): primary signs subkey; the binding
  signature **MUST** embed a counter-signature by the subkey over both keys.
- **Keybase `reverse_sig`**: the sigchain link is signed by an existing device
  **and** by the new key with `reverse_sig` nulled.
- **SSH advertise + `hostkeys-prove-00`**: the server advertises, the client
  demands a fresh possession proof per key before recording it.

And the in-flight standardisation of it for whole primary keys:
`draft-ietf-openpgp-replacementkey-08`'s **forward reference** (in the old key's
revocation: "I am replaced by K_new") plus **backward reference** (in the new
key's direct self-signature: "I replace K_old"). *Neither half alone suffices.*

**Buys:** immunity to a third party claiming someone else's key as their
successor. **Costs:** both keys must be present at the moment the pair is minted —
which is exactly the property a backup ceremony has and a loss event does not.

## S2. Hash-chained self-certifying log the subject carries

- **Keybase sigchain**: `prev` (hash of previous link) + `seqno` + `eldest_kid`.
  *"the server can't create links on its own or omit links without invalidating
  the whole sigchain."* Revocation does **not** invalidate past links: *"old links
  remain valid even if their signing keys are revoked later"* — the direct answer
  to the "historical messages render as foreign" problem class.
- **did:plc**: each operation references the prior state **by hash**, and the DID
  *is* the hash of its genesis operation. Full offline validation procedure
  published.
- **Nostr PR #158** (closed): 256 pre-generated keys where `A = A' + hash(A'||B)`.
  **The only fully registry-free design in the corpus**, verifiable from a single
  event.

**Buys:** anti-rollback within one subject's history, offline. **Costs:** says
nothing about what *other* people were shown (see S3).

## S3. Buying the equivocation bit — four different prices

| Mechanism | What it buys | Price |
|---|---|---|
| Merkle tree + server-signed roots (Keybase) | forks become **permanent and detectable by comparing notes** | a server, plus users who compare |
| Blockchain anchor (Keybase: Bitcoin '14→Stellar '20, ~hourly) | removes the need to compare notes | an external chain, ~1h staleness |
| Timestamp anchor + waiting period (Nostr #829: OTS + **60 days**) | ordering, with a window for the real owner to out-claim | **60 days of limbo** |
| In-band gossip on ordinary messages (MINGLE, 2026) | distributes the audit across the communication graph | **119 bytes/message**, ~5 min to evidence at 20% participation / 5% of messages; **still presupposes a log** |

## S4. Priority-ordered keys with a bounded rollback window — the did:plc shape

Not "old attests new" but **"a colder key can undo a warmer key's actions, for 72
hours."** `rotationKeys` is a priority-ordered list of 1–5 keys, *"not included in
the DID document"*, and recovery is: sign a new op pointing at the fork-point CID,
within 72h, with a **lower-index** key.

**Buys:** recovery held in advance, offline, usable even when the warm key is
compromised. **Costs:** a directory to enforce the window; permanent public
linkability of shared rotation keys; and the spec's own recommendation that users
*"include a self-controlled PLC rotation key"* means the user still holds
something.

## S5. The intermediate single-use migration key

The best idea in the Nostr thread [V, staab, conceded by fiatjaf]:

> "The migration key allows for **generating a successor key on demand without
> naming it in advance**, allowing people to mess up and still recover… we're
> exposing a general-purpose key to whatever risks the backup solution has
> forever, **instead of just the migration key which becomes obsolete once used.**"

**Buys:** the pre-commitment does not require choosing the successor in advance,
and the pre-committed secret is single-use and disposable rather than a
general-purpose identity key sitting in a backup for a decade. **This is the
direct answer to C4** (a pre-generated kill switch cannot name a successor).

## S6. Recovery-credential-as-ordinary-credential (Keybase's paper key)

*"A paper key is a long string of randomly-generated words that's linked to your
account **the same way a device is**."* One primitive, one code path, one
revocation path.

**Buys:** no separate recovery subsystem to get wrong — structurally avoids
Matrix's whole terminology-and-reset failure cluster. **Costs:** the artifact is
still a bearer word list the user must store (C7).

## S7. Private-key transport over a device-to-device channel (Signal's actual answer)

Signal does not attest succession; it **moves the private key**. Linked-device
provisioning and 2025 Quick Restore both carry `aciIdentityKeyPrivate` verbatim
over a QR-bootstrapped encrypted channel. Keybase's KEX does the same for the
per-user key seed, over a channel keyed by 8–9 BIP-39 words
(`scrypt` N=2¹⁷ desktop / **2¹⁰ mobile**), shown as text or QR, bounced off the
vendor's own servers with end-host authentication.

**Buys:** zero new cryptographic machinery; no succession concept needed at all;
no third-party verification problem. **Costs:** requires **both devices** and
(for Signal) the **same platform**; useless in the lost-phone case — which is
precisely why Signal's only lost-phone path re-keys.

## S8. Succession proven over a channel the outgoing key authenticated (SSH)

No artifact at all. The outgoing key authenticates the transport; the successor is
advertised over it; the client demands a session-bound possession proof; and only
then writes it down. Signed payload = context string ‖ **session identifier** ‖
hostkey. Graceful rotation = *"a server may offer multiple keys of the same type
for a period… before removing the deprecated key."*

**Buys:** unforgeable, unreplayable, self-delivering, no distribution problem.
**Costs:** cannot be pre-generated, transferred, or archived; requires a live
session; ceiling is *"Keys learned though this mechanism can never be more
trustworthy than the key used to establish the SSH transport session."*

## S9. In-band validation with an untrusted delivery service (MLS)

Members verify Add/Remove/Update/Commit themselves; *"the DS is only expected to
reliably deliver messages"*; the confirmed transcript hash binds each epoch to the
full history and the confirmation tag *"confirms that the members of the group
have arrived at the same state."*

**Buys:** membership succession verified from the message stream with no server
validation. **Costs:** MLS still assumes a trusted Authentication Service for
identity→key binding, and the spec does not address a DS showing different group
states to different members.

## S10. Social attestation as an explicit, signed act

Two independent instances:
- **Debian's rule** for the lost/compromised case: *"Key Y must be signed by two
  active Debian developers whose keys are in the active keyring"* + a revocation
  certificate for X where possible. **When the old key can still sign, succession
  is proved by the outgoing key; when it cannot, it falls back to human vouching.**
- **pablof7z's proposal**: *"I would call [people] that I'm close with to get them
  to attest and **give a clear social weight to that migration event**."*
- **Guardian models** (Vitalik/Argent/Safe): guardians can **only rotate the owner
  key, never sign transactions**, with a delay the original signer can cancel.

**Buys:** the only mechanism that works when the outgoing key is gone. **Costs:**
a human protocol; Argent's exact delay is **[U]**; and *"no messaging system has
shipped social-graph recovery at scale"* (per island Design 06, cited in
`CRUCIBLE.md`).

## S11. Backup artifact forms, with their real numbers

| Form | Fit for 32 bytes | Notable property |
|---|---|---|
| BIP-39 as an **encoding of raw entropy** | **exact: 24 words, 8 checksum bits, bijective** | ubiquitous; 4-char prefix uniqueness; do NOT route through PBKDF2 or the passphrase (C19) |
| SLIP-39 Shamir | 33 words **per share** | sound spec, **Trezor-only ecosystem in practice** |
| Passphrase-wrapped blob | ~100 bytes | must carry its own KDF params (C20); copy age's domain-separated salt, single-stanza rule, work-factor cap and fixed-body-length check (C21) |
| **Single static QR** | **~100× headroom at level H** | animated QR is unnecessary at this payload |
| iCloud Keychain (`synchronizable`) | trivial | E2EE; HSM escrow, SRP, **10 attempts then destroyed**; **mutually exclusive with access-control flags** (C11) |
| Android Block Store | 16 arrays × 4 KB | E2EE **only** with Android 9+ and a screen lock; per-call deletion footgun; **no credible Flutter plugin** |
| Passkey WebAuthn **PRF** | derives 32 bytes exactly | the newest and most on-point mechanism; support is **messy** and the capability flag can lie — probe by deriving |
| Printed paper / metal | trivial | no survival data exists; Lopp's tests are metal-only with **no paper control arm** |

## S12. Rate-limiting and delay, with shipped first-party precedent

**Apple Stolen Device Protection** is the structural template [V]: biometric **with
no passcode fallback** for sensitive actions, plus a **one-hour Security Delay
requiring biometric auth twice — once before and once after**. WhatsApp's HSM
vault is the same idea in hardware: *"rendering the key permanently inaccessible
after a certain number of unsuccessful attempts"*, with **OPAQUE** so the password
never reaches the server. Apple's escrow: **10 attempts, then destroyed forever**,
with the firmware-change access cards *"destroyed"*.

**The mechanism that makes a delay work is a notification channel the attacker
does not control.**

## S13. The publication asymmetry keys.openpgp.org chose

Two rules worth knowing as a pair [V]:
- *"**Any non-identity information will be stored and freely redistributed**… It
  also includes… **revocation status**."*
- *"The identity information in an OpenPGP key is **only distributed with
  consent**."*
- and *"by default, keys.openpgp.org doesn't publish third-party certifications"*
  except those the key holder *"marked as 'attested certifications'"*.

**The kill switch travels without consent; identity does not; and only the key
holder can cause data to be attached to their own key.** The last rule is the
direct fix for the SKS flooding class (C24), and its cost is stated plainly: it
kills the Web of Trust as a distributed artifact.

## S14. Domain separation and key-check primitives worth stealing verbatim

- **Matrix SSSS**: HKDF-SHA-256 with **the secret name as `info`** — per-secret
  domain separation for free.
- **Matrix's key-check**: same HKDF with the **empty string** as `info`, encrypt
  32 zero bytes, keep only `iv`+`mac`, discard the ciphertext. *Verifies the
  recovery key without touching a real secret.* **But make it mandatory — Matrix's
  own optionality is C8's instrument failure.**
- **age**: `S = "age-encryption.org/v1/scrypt" || salt`.
- **SSH**: the literal context string `"hostkeys-prove-00@openssh.com"` as the
  first signed field, so a succession proof can never be replayed as a transport
  authentication.
- **BC-UR**: CRC-32 of the whole message in every part; Bytewords into the QR
  alphanumeric charset for ~45% density.

## S15. Graceful overlap rather than a cutover

SSH: *"a server may offer **multiple keys of the same type for a period** (to give
clients an opportunity to learn them using this extension) before removing the
deprecated key."* WKD: *"**To ease distribution of revoked keys, a server may
return revoked keys in addition to a new key.** The keys are returned by a single
request as concatenated key blocks."* Keybase: revoked keys' past links stay valid.

**Every system that survives rotation treats the key set as overlapping-in-time,
never as a single current value.** That is the same conclusion
`key-continuity/DESIGN.md` reached independently.

---

# OPEN QUESTIONS THE DESIGN MUST ANSWER

**On the ore itself**

1. **Which relying party is this for?** The self-facing verdict
   (`carriedRecord()` on the subject's own history) and the third-party verdict
   have *different* requirements — the former needs no registry, the latter needs
   ordering and completeness from somewhere. A design that does not separate them
   will price the wrong thing. (Q1.)
2. **What is the actual cost of re-issuance in aiko?** The 1997 paper's whole
   escape hatch is "revoke and re-issue with the same rights and privileges." If
   that is cheap here, the literature says do not build key recovery at all. If it
   is expensive — the user loses their graph, their name, their history's
   attributability — then this design is deliberately overriding a 29-year
   consensus and **owes an explicit statement of that with the failure scenario
   and severity named**, not a silent absorption.
3. **Does ADR-0004's "identity = key" foreclose the account-abstraction options?**
   Every social-recovery and guardian design (S10) requires an identity that can
   outlive its current key. If identity *is* the key, those are structurally
   unavailable — and that is a real, nameable cost of ADR-0004 that belongs
   surfaced, not buried.
4. **Does the succession link ever need to leave the device?** If it does not, C1
   does not bite. If it does, which of S3's four prices is being paid, and by
   whom?
5. **Is the pre-compromise case made worse?** (C2.) In a design where a
   pre-committed link exists, what stops an attacker who steals the seed from
   executing the succession themselves and locking the owner out **permanently**?
   Nostr's answer is "nothing, and that's the trade-off." What is aiko's?

**On the mechanism**

6. **Does the new key prove possession, or is it merely announced?** (C3.) If
   announced only, what is the mitigation for the advertise-someone-else's-key
   attack SSH's draft §5.2 spells out?
7. **Is the pre-generated artifact a kill switch or a succession pointer?** It
   cannot be both (C4). If both are wanted, that is two artifacts with two
   lifecycles.
8. **Who is the custodian?** Q3's real finding is that every artifact form is
   technically trivial for 32 bytes, and the whole decision is *which custodian*:
   user memory, user paper, Apple's HSM cluster, Google Play services, a passkey
   authenticator, or the user's friends. **Name the custodian before naming the
   format.**
9. **What does the design print when it is wrong in the way it cannot see?**
   Matrix's SSSS key-check is optional and absent-means-valid; the Android
   Keystore backup path reports success and restores undecryptable bytes; BIP-39's
   passphrase has no wrong answer. **Every one of those is an instrument that
   answers the question incorrectly instead of leaving a gap.** What is this
   design's equivalent, and where is the answer written down for the next reader?

**On the tradeoff**

10. **Is the export gate cryptographic or cosmetic?** `local_auth` returns a
    boolean; only `SecAccessControl` / `setUserAuthenticationRequired` bind key
    material — and those **irreversibly destroy the item** on biometric
    re-enrollment (C17), manufacturing the exact failure backup exists to prevent.
    Which side of that is chosen, and is the resulting failure mode stated?
11. **What is the answer to "a support agent asked me for my recovery key"?**
    (C15.) The feature writes the script for its own social-engineering attack.
12. **Does the design assume the export screen is private?** SparkCat and
    accessibility-service malware say it is not, on both platforms, and iOS cannot
    block screenshots (C12, C13, C14).
13. **What does the user see, on their hardware, when a restored key makes their
    own history render as foreign?** Element's "identity has changed" copy is the
    published failure of exactly this message, with a `X-Needs-Design` ticket and
    no maintainer reply.

**Measurements that should precede the design, not follow it**

14. **Pure-Dart Argon2id on a real mid-range phone** — unmeasured, and it
    determines whether `cryptography`'s Argon2id is usable at all or whether the
    ecosystem forces `pointycastle` / FFI / natively-accelerated PBKDF2. Keybase's
    N=2¹⁰-on-mobile datum suggests the ceiling is lower than intuition. (C18.)
15. **Does `flutter_secure_storage`'s `synchronizable` actually round-trip through
    iCloud on this repo's pinned `^10.3.1`?** The option is documentation-invisible
    and mutually exclusive with access-control flags. Verify against a live build,
    not the README.

**Cross-tab, per this repo's CLAUDE.md**

16. **Does the island's Design 05 (guardian-quorum social recovery, k-of-n +
    time-locked veto) overlap or conflict with anything minted here?** The loss
    case is the island's; the have-it case is the app's. The boundary must be
    stated, not assumed — and per the repo directive, a conflict is a **finding to
    surface**, not one to tie-break.
17. **Do `pop-identity-binding/TEMPER.md`'s binding prescriptions reach any
    admission path designed here?** (PoP the only writer that sets `proven`;
    write-once/monotonic; a dedicated route rather than overloading
    `POST /v1/keys`; every roster read surface returning
    `state: asserted|proven`.)

---

## Instrument coverage and honest gaps

Negatives established, with their instrument named:
- **age has no rotation story** — grepped the complete 492-line spec and the
  325-line README for rotate/revoke/successor/expire/replace. Complete coverage.
- **SSH user keys have no succession** — `AUTHORIZED_KEYS FILE FORMAT` read in
  full; `@revoked` ruled out by section-boundary line numbers, not assumption.
- **`cryptography` has no scrypt** — GitHub recursive tree API over the whole repo.
- **Signal has no succession primitive** — three instruments (source file read in
  full, code search, proto enumeration), with the code-search coverage caveat
  stated.
- **Matrix defines no transparency log** — four spec files read in full, plus an
  open spec issue requesting exactly the missing mechanism. **Phrase as "the spec
  defines no log", not "Matrix cannot detect equivocation."**

Gaps that must not be laundered into certainty:
- CHI 2025 storage-practice percentages (ACM DL 403'd; only n and the 43.4% figure
  are verified).
- Realistic Argon2id/scrypt parameters on a mid-range phone — **no measurement
  taken, no number invented**.
- Whether Apple's escrow secret is the device passcode or the iCloud Security Code
  — Apple's text says the latter.
- `largeBlob`'s byte limit — the commonly-cited 1 KB was not found in any spec.
- Which Chrome milestone shipped WebAuthn PRF.
- Argent's exact time-lock (36h / 48h / 5 days reported inconsistently).
- Wrench-attack counts (Lopp's dataset not re-counted).
- SKS shutdown date (domain measured dead 2026-09-16; date unverified).
- `draft-miller-sshm-hostkey-update-02` / WG adoption.
- Debian's dual-signature requirement — only the **old** key's signature is
  literally mandated on the page.
- A Signal-authored rationale for the *absence* of succession — could not confirm
  one exists.
- Any first-party Keybase engineering post-mortem — could not find one; the Book
  is frozen at 2022.
- Any measured paper-backup survival rate or animated-QR scan failure rate — these
  appear not to exist publicly.
- Coinbase WaaS architecture — not researched.
- US border-search / compelled-decryption doctrine — not researched.
