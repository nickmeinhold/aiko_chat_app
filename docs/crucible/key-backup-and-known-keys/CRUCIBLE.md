# 🜂 CRUCIBLE — in-app key backup, and the rotation-link it can mint

> Movement 1 (Ore) + consent gate. Candidate **pre-selected by Nick** 2026-09-16:
> *"we need a way to back up your key, via the app."* Ore was not scouted; it was
> given. This document grounds it, states the heat honestly, and names the
> falsifier.

## Scout-memory check — REQUIRED READING FIRED, AND IT CHANGED THE PICK

`docs/crucible/key-continuity/DESIGN.md` **already exists** (19KB, committed
2026-08-20, `f1e2534`, task #2299 / PR #107). It has no `CRUCIBLE.md`, no
`RESEARCH.md`, and **no `TEMPER.md`** — an un-tempered design standing on this
exact ground.

**It already contains the thing this session independently "discovered":**

> *"a pin store keyed by `user_id → single pubkey` is the wrong data model. The
> real world is `user_id → a rotating, multi-holder SET of keys with lifecycle
> state"*

So the known-keys-set observation is a **rediscovery, four weeks late**, and this
bundle must not present it as new. What it adds is the *site*: that design pins
**other senders'** keys; Nick's ask is about the **subject's own**. Same data
model, two call sites — and the self-facing site has a property the other lacks,
which is the actual ore (below).

**A prior strike binds by its prescribed shape.** `key-continuity/DESIGN.md`
recommends **Arm B — wait**, gating continuity on #17 (multi-device identity) and
#21 (rotation semantics), with one qualified exception (silent-TOFU-only pin
store, no UI, no island call). Nick's decision does not overrule that
recommendation — it overrules a *different* one (`pop-identity-binding/RESEARCH.md`
and `SovereignKeyStore.clear()`'s "no recovery; named-deferred"). Whether it also
reaches Arm B is precisely what this forge must settle, not assume. **Surfacing
the conflict, not tie-breaking it.**

## The ore

**A backup is the one key event where the outgoing key is in your hand.**

`key-continuity/DESIGN.md` §2 says continuity cannot ship because a pin cannot
distinguish a legit key change from an attack, and that this is *"genuinely gated"*
on #17/#21. The primitive it says #21 must define:

> *"a rotation is accepted into the set **silently** only when it arrives with a
> link the app can verify **without the island** — a new-key record signed by an
> in-set outgoing key (the 'rotation link' #21 must define)"*

That primitive is **unavailable in the loss case** — a lost key cannot sign
anything, which is why the island reaches for guardian-quorum social recovery
(island Design 05, k-of-n with time-locked veto). It is **trivially available in
the backup case**: the device performing the export is holding the private seed at
that moment and can sign the attestation on the spot.

**So the gating may be inverted.** Backup is not downstream of the rotation
lifecycle waiting for it to land — backup is the ceremony that *mints the first
rotation link*, using a key that is present, with the user physically there. The
heavy machinery (guardians, quorum, veto) exists for the case where you have
**lost** the key; it has been absorbing the much lighter case where you still
**have** it.

*Oh, of course:* **you can't sign your own succession after you're dead — so sign
it while you're alive.** A backup taken in advance is a will, not a séance.

## Why this thrills me, and what it actually changes

- It converts an accepted, documented defeat ("lose the device, lose the identity
  — no prior art solves this") into a bounded, present-tense ceremony.
- It gives `keyVersion` its first consumer. That field is carried on the wire and
  persisted in typed drift columns and is read as a discriminator by **nothing**
  in `lib/`. A reserved slot with no consumer is a design that never landed.
- It unblocks the self-facing half of a design that has been parked on two
  cross-repo tasks since August, without touching either.
- The human task it removes is real and currently un-removable: today Nick's only
  key backup is an *encrypted Finder backup of the whole phone*, an out-of-app
  workaround with no Android equivalent (Keystore master keys are non-extractable
  by construction, so an Android auto-backup restores undecryptable ciphertext).

## The falsifier — what would prove this ore is slag

**If a rotation link is only useful when OTHER people's clients can verify it,
then the self-facing case bootstraps nothing and this is just an export button.**

Concretely, the ore dies if any of these hold:
1. A self-signed new-key attestation is worthless to a third party without an
   island-side registry to distribute it — i.e. the link must be island-carried,
   so it is gated on the island's work after all and #17/#21 remain the true gate.
2. `carriedRecord`'s self-facing verdict is the *only* consumer a known-keys set
   would ever have, making the "set" a one-call-site generalisation — real, but
   not worth a design.
3. Making an extractable identity key deliberately *more* extractable is a net
   security loss that exceeds the continuity gain (the T2 tradeoff in
   `sovereign_key_store.dart` is that the seed is already extractable by a
   privileged attacker; an export UI lowers that bar to a social-engineering one).

(3) is the one I'd bet the temper lands hardest on, and it should.

## Grounded facts (measured in source 2026-09-16, not recalled)

- Seed: 32 bytes at `aiko_sov_private_seed`, `FlutterSecureStorage`
  (`lib/services/sovereign_key_store.dart`). No export/backup/recovery surface
  anywhere in the app.
- `carriedRecord()` (`lib/features/chat/domain/carried_record.dart`) takes
  `required Uint8List subjectPublicKey` — **singular**;
  `carried_record_screen.dart:64` passes `myKey.rawPublicKey`, this device's live
  current key.
- `CarriedRecordVerdict.foreignKey` renders as *"Signed by a different key — not
  this device"*; its docstring admits it cannot separate *"another device of yours
  (multi-device is not yet supported)"* from *"another person"*.
- `keyVersion`: written, transported, persisted; **no discriminator read** in
  `lib/`.
- No pubkey→account registration call exists in the app; `origin_envelope.dart`
  states the binding is *"peer PR B"*, unlanded. Island-side `signing_keys` +
  `POST/GET/DELETE /v1/keys` **do** exist (per `pop-identity-binding/DESIGN.md`) —
  the app simply never calls them.
- iOS keychain default is `KeychainAccessibility.unlocked`
  (= `kSecAttrAccessibleWhenUnlocked`, NOT ThisDeviceOnly) — verified in
  flutter_secure_storage 9.2.4 source, so encrypted-Finder-backup eligible.

## Cross-tab bearing (per repo CLAUDE.md)

- **Island Design 05** — guardian-quorum social recovery, k-of-n + time-locked
  veto. The *loss* case. Must not be duplicated or contradicted here.
- **Island Design 06** (identity and trust) — names Recovery as one of three core
  questions; records that *"no messaging system has shipped social-graph recovery
  at scale"* and that **key loss rate is unmeasured**.
- **App `pop-identity-binding/TEMPER.md`** — unanimous RECAST, ore survived.
  Binding prescriptions that touch this: PoP must be the **only** writer that sets
  `proven` (write-once/monotonic); a dedicated route rather than overloading
  `POST /v1/keys`; **every roster read surface must return `state:
  asserted|proven`**. Any key-admission path designed here inherits those.

## Scores

| Axis | Score | Evidence (not affect) |
|---|---|---|
| Aliveness | 3 | Inverts a recorded gating decision; gives a reserved-and-unconsumed wire field its first consumer. |
| Impact | 3 | Nick asked for it directly today; it closes a documented "no recovery" defeat and removes a workaround that has no Android equivalent. |

Product 9. No zero on either axis.

## Consent

Gate crossed: Nick named the candidate explicitly and said "yes please! crucible!"
(2026-09-16 15:50 +07). Output location: `docs/crucible/key-backup-and-known-keys/`
— a named proposal dir, since the ore spans `lib/services/`,
`lib/features/chat/domain/`, and a cross-repo contract.
