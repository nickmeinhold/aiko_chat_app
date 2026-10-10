# 🜂 RESEARCH — the passkey IS the identity root

> Movement 2 (Heat) of the `passkey-rooted-identity` forge. Brief: `CRUCIBLE.md`.
> Every claim is marked **[V]** (verified, source URL given), **[R]** (reported by a
> credible secondary source, not confirmed at primary), or **[U]** (unverified — do not
> build on it without measuring).
>
> **Prior pass honoured.** `key-backup-and-known-keys/RESEARCH.md:1324-1365` already did
> the PRF spec/support sweep and `:2154` already recorded *"the capability flag can lie —
> probe by deriving."* That is not repeated below. §7 states exactly what is new.

---

## 1. VERDICTS ON THE FALSIFIERS

| # | Falsifier | Verdict |
|---|---|---|
| **F1** | PRF is not deterministic for the same credential across devices | **SURVIVES — but only on the on-device path, and the exception is load-bearing.** Synced-passkey PRF is identical across devices of the same ecosystem [V]. The **hybrid / cross-device QR (caBLE) path provably returned a DIFFERENT value for the same credential and same salt** — Apple confirmed it as a bug, claimed fixed in iOS 18.4 / macOS 15.4, and it is **still being reported** [V]. So: portable *within* an iCloud-Keychain or GPM ecosystem, **silently divergent across ecosystems**. |
| **F2** | The app cannot use one shared RP-ID across both islands | **SURVIVES, cleanly — and more cheaply than the brief assumed.** Related Origin Requests are **unnecessary for native apps**: Associated Domains (iOS) and Digital Asset Links (Android) already map one app to one RP-ID independent of which server it talks to [V]. One RP-ID (`aikochat.org`) covers both islands. Cost is not architectural; it is a **named cross-repo config change plus forced re-registration of all existing credentials** (§2 C5/C6). |
| **F3** *(new, found here, not in the brief)* | The app's locked passkey packages cannot request PRF at all | **SLAG-BLOCKING-BUT-CHEAP.** `pubspec.lock` pins `passkeys_platform_interface` **2.6.0**, `passkeys_darwin` **0.4.0**, `passkeys_android` **2.12.0** — **zero occurrences of `prf` in any of the three** [V, grepped]. PRF landed in flutter-passkeys PR #263, shipped in `2.9.0` / `0.4.3+3` / `2.13.1` [V, CHANGELOGs]. A dependency bump is a hard prerequisite; nothing about the candidate is measurable until it lands. |
| **F4** *(new, found here — the one that actually hurts)* | The WebAuthn L3 spec co-editor has publicly argued against exactly this composition | **UNRESOLVED, AND IT IS A DESIGN QUESTION, NOT A FACT QUESTION.** Tim Cappalli, W3C WebAuthn L3 co-editor, published *"Please, please, please stop using passkeys for encrypting user data"* on **2026-02-27** [V]. His distinction is precise and it cuts *against* the candidate and *for* the vault products (§4, §5). This is not refutable by measurement; it has to be answered by design. |

### The one experiment that settles F1 on real hardware

Sources settle the *same-ecosystem* case. They do **not** settle it for *this app's* native
`ASAuthorization` / Credential Manager path, which no cited source tested. Measure it:

1. Bump the three passkey packages (F3). Register one credential with
   `extensions.prf.eval.first = SHA-256("aiko-sovereign-v1")`, RP-ID pinned, on **handset A**.
2. Record `clientExtensionResults.prf.results.first` — 32 bytes, hex.
3. Wait for iCloud Keychain sync. On **handset B (same Apple ID, passkey synced, NOT scanning
   a QR code)** run an *assertion* with the identical salt. Record the 32 bytes.
4. **Compare byte-for-byte.** Equal ⇒ F1 survives for the shipped path.
5. **Then deliberately run the failing arm:** assert the same credential from a *Mac or
   Android device via the QR/hybrid flow* and compare again. If it differs, you have
   reproduced the Apple bug on current OS builds and C5 below is live, not historical.
6. Repeat 1–4 on Android/GPM. iOS↔Android is **not** the same ecosystem — that crossing is
   the hybrid path, i.e. arm 5, not arm 4.

Note the asymmetry this design has to survive: **a wrong answer here is silent.** A diverged
master produces a valid Ed25519 key that signs valid messages under a different public key.
Nothing errors. The user becomes a second person.

---

## 2. CONSTRAINTS → forward to the next movement

- **C1 — Derive only on the on-device path; refuse over hybrid.** The hybrid divergence is a
  real, Apple-acknowledged defect with a partial fix and live re-reports [V]. A design that
  derives the identity root must detect and **refuse** a hybrid ceremony rather than derive
  from it. `authenticatorAttachment` is the available discriminator (`"platform"` vs
  `"cross-platform"`) — that it is *sufficient* is **[U]** and must be measured.
- **C2 — Never trust `prf: {enabled: true}`.** Already recorded at
  `key-backup-and-known-keys/RESEARCH.md:2154`. New corroboration: *"In the same session,
  Chrome reported `extension:prf` as supported with Bitwarden, Dashlane and Proton Pass
  active, and the registration then returned no PRF result for Bitwarden and Dashlane…
  The flag describes what the client will forward, not what comes back."* [R, Corbado].
- **C3 — `create()` and `get()` PRF are separate capabilities.** *"Create and get are
  separate capabilities. A manager can ship exactly one of them."* [R, Corbado]. iOS 18+
  does expose both natively — `ASAuthorizationPublicKeyCredentialPRFRegistrationInput` and
  `…PRFAssertionInput` [V, Apple docs] — and iCloud Keychain and GPM are both reported to
  return the first PRF output during `create()` [R]. So for the two providers this app cares
  about, **no second biometric prompt is required at registration**; for any other provider,
  assume one is. Design for a possible immediate follow-up assertion; do not depend on it.
- **C4 — A third-party credential manager can silently have no PRF.** Bitwarden and Dashlane
  returned none while advertising support [R]. This app's ingress is the OS sheet, so a user
  with a third-party provider as default is a real, unhandled branch.
- **C5 — Cross-ecosystem portability is NOT delivered.** iPhone→Android is the hybrid path.
  The island's own record already prices the UX half of this: *"Cross-device onboarding (QR
  hybrid) 52–76% completion vs 79–98% same-device, and it deposits nothing locally — an
  iOS→Android switcher re-scans every login until FIDO Credential Exchange matures"*
  [V, `../../../aiko-chat-island/docs/design/04-passkey-first-identity.html` §4]. The candidate
  must not be sold as ecosystem-portable identity. It is **ecosystem-scoped** identity.
- **C6 — A shared RP-ID is a cross-repo change the island currently REJECTS AT BOOT.**
  Verified in the peer repo: `expected_rp_id=settings.passkey_rp_id` and
  `_expected_origins() → [f"https://{settings.passkey_rp_id}", *passkey_extra_origins]`
  (`../../../aiko-chat-island/src/aiko_gateway/domain/passkey_service.py:74,169,199,218`), and a
  boot invariant asserts `passkey_rp_id` is the serving host **or a registrable parent of
  it**, with an explicit test that a *sibling* domain raises
  (`tests/test_config.py:386-419`, `test_prod_passkey_rp_id_sibling_domain_raises`) [V].
  `aikochat.org` is a registrable parent of neither `chat.imagineering.cc` nor
  `chat.enspyr.co`. **That invariant encodes a browser assumption — that the ceremony
  originates on the island's own host — which is false for a native app.** Relaxing it is a
  deliberate island-tab decision, not an app-side workaround. Flag it to the island tab.
- **C7 — Each island stops serving its own well-known; `aikochat.org` starts.** Today each
  island serves `{"webcredentials": {"apps": [passkey_ios_app_id]}}` and its own
  `assetlinks.json` from `rest/well_known.py:23,52` [V]. A shared RP-ID moves both files to
  `https://aikochat.org/.well-known/` — a domain the app already owns and serves statically
  (`reference_aikochat_org_static_site`). The app's `webcredentials:` entitlement changes
  from two island hosts to `webcredentials:aikochat.org`
  (`ios/Runner/Runner.entitlements:7-8`) [V]. Android's origin is
  `android:apk-key-hash:<b64url-sha256>`, which must be in `passkey_extra_origins` on both
  islands [V, config.py:559-562]. **Two relations are required in assetlinks**
  (`reference_android_passkey_assetlinks_two_relations`).
- **C8 — Changing the RP-ID invalidates every existing credential, and under this candidate
  that means every existing IDENTITY.** A passkey minted for `chat.imagineering.cc` cannot
  be asserted for `aikochat.org`. Today that costs a re-registration. **Under this candidate
  it changes the derived master, i.e. the user becomes a new cryptographic person.** 56 users,
  217 signed messages. The migration question the #4831 arc just decided *not* to build
  machinery for arrives here again, on a different axis and with a worse blast radius.
- **C9 — SLIP-0010 buys nothing here; HKDF is sufficient and already vendored.** SLIP-0010
  for ed25519 supports **hardened derivation only and no public-key derivation**, using the
  hash output directly as the private key [V, slip-0010]. The candidate needs no BIP32
  interop, so the tree is pure private-side derivation and HKDF-SHA-512 with a domain-
  separated label is equivalent in strength and simpler. `cryptography` 2.9.0 — already a
  direct dependency — ships `Hkdf` (`lib/src/cryptography/algorithms.dart:1280`) [V].
  **No new dependency for the derivation tier.** Dart SLIP-0010 packages do exist
  (`ed25519_hd_key`, `slip_0010_ed25519`) [V, pub.dev] — they are simply not needed.
- **C10 — Key blinding is NOT implementable on today's Dart crypto stack.** Verified by
  inspection of the locked artifacts, not the docs:
  - `cryptography` 2.9.0 exposes `abstract class Ed25519 extends SignatureAlgorithm`
    (`algorithms.dart:1184`) — sign/verify only, no scalar or point API [V].
  - `pointycastle` 4.0.0 (transitive) contains **no ed25519 or edwards file at all**
    [V, `find` returned nothing].
  - `ed25519_edwards` on pub.dev publishes only `generateKey`, `newKeyFromSeed`, `public`,
    `seed`, `sign`, `verify`, `KeyPair`, `PrivateKey`, `PublicKey` — `ExtendedGroupElement`
    and the `Ge*` functions are internal, not public API [V, pub.dev API docs].
  - The one Dart package that *does* expose the curve, `edwards25519` 1.0.5 (a port of
    `filippo.io/edwards25519`), has **4 likes, an unverified uploader, and was last
    published ~20 months ago** [V, pub.dev]. That is not a foundation for a trust boundary.

  **So the blinding tier needs FFI.** The concrete primitives are libsodium's
  `crypto_scalarmult_ed25519_base_noclamp` and `crypto_core_ed25519_scalar_mul(z = x*y mod L)`
  [V, libsodium docs]. Whether any Dart binding exposes them is **[U]** — and the prior is
  poor: Node's `sodium-native` tracked *"Missing bindings for
  crypto_core_ed25519_scalar_mul"* as an open issue [V], so high-level bindings routinely
  omit the point-arithmetic family. Realistic path is a raw `dart:ffi`
  `DynamicLibrary.lookup` against a bundled libsodium, i.e. **hand-rolled curve arithmetic
  inside the signing trust boundary — which this repo's CLAUDE.md sends to `/cage-match` by
  rule.** Say it plainly: **the blinding tier is not buildable this month.** It must not be
  a prerequisite for the conventional core, exactly as `CRUCIBLE.md` already stipulated.
- **C11 — The primitive itself is real and specified, so the tier is deferred, not fantasy.**
  Tor `rend-spec` Appendix A `[KEYBLIND]` [V, spec.torproject.org/rend-spec/keyblinding-scheme.html];
  IETF CFRG `draft-irtf-cfrg-signature-key-blinding-02` [V]; and Eaton, Lehmann et al.,
  *Security Analysis of Signature Schemes with Key Blinding*, eprint 2023/380 — formal
  unforgeability **and unlinkability** proofs for EdDSA- and ECDSA-based schemes [V].
  Reference C implementation: Tor's `src/ext/ed25519/ref10/blinding.c` [V].
- **C12 — The island already decided there must be a fallback, and that decision binds this
  candidate.** Island Design 04 §1: *"no credible service ships auth with zero fallback…
  remove social OAuth, make the passkey the identity root, and add a thin recovery hatch
  that is NOT a federated identity"* [V]. Passkey-as-identity-root is **already the island's
  recorded direction** — which strengthens the candidate — but it arrives with a mandated
  recovery hatch, and §8 below shows why that hatch must be a **wrapper, not a second
  derivation**.

---

## 3. FAILURE MODES OTHERS ALREADY HIT → forward to the next movement

1. **Apple shipped a PRF that returned different bytes over hybrid than on-device — for
   months, silently.** Same credential `NxlQaXK64UAY0EsehesfFy9rt-0`, same salt, same RP-ID,
   two outputs: `nmKfLMSLd0vuV8xgAMQQ40rajzkSdHM_f3V4mq5UUqo` (platform) vs
   `HztucMbG6UQ5QOVhM17gwi3C7S1kxC7isCYfaS8zbNw` (hybrid). Apple engineer, accepted answer:
   *"Yes this was a bug. The PRF values returned over hybrid should match the ones returned
   locally for the same input. This issue should be fixed in the current iOS 18.4 and macOS
   15.4 betas."* [V, developer.apple.com/forums/thread/764730]
2. **The fix then orphaned the data encrypted under the buggy output, and Apple never
   answered the migration question.** Developers on that same thread asked how to recover
   data encrypted with the pre-18.4 hybrid value, how to detect affected users, and what to
   do during the transition. **No Apple response** [V]. A later report (Apple feedback
   **FB22434584**) claims reproduction on much newer builds [R]. *The platform's PRF is not a
   stable contract; it is an implementation that has already changed its output once and
   broke everyone who trusted it.*
3. **A second, adjacent Apple thread: PRF silently absent over hybrid.** Expected
   `true`, actual `false`, empty extension results; Apple's reply: *"This issue was partially
   fixed in Safari 18.2. As of that version, PRF is available again in hybrid, but it's
   returning a different value over hybrid than when invoked on-device. This remaining issue
   will be fixed soon."* Reporters said it persisted at Safari 18.4 / macOS 15.4
   [V, developer.apple.com/forums/thread/774112].
4. **Capability flags lied in production** for Bitwarden and Dashlane in one Chrome session
   [R, Corbado]. Reading the flag is a known-failed strategy, not a cautious one.
5. **The industry's own PRF advocate says don't do this.** Cappalli, 2026-02-27 [V]:
   *"When you overload a credential used for authentication by also using it for encryption,
   the 'blast radius' for losing that credential becomes immeasurably larger."* His
   supporting evidence is an interface argument, and it is the strongest part: he screenshots
   the deletion dialogs of **Apple Passwords, Google Password Manager and Bitwarden** and
   shows that none of them warn that deleting the passkey destroys data. *"please stop
   promoting and using passkeys to encrypt user data."*
6. **The one messenger-adjacent build that did exactly this ships no recovery story.**
   `bao-signer` (Nostr) derives a secp256k1 signing identity straight from PRF:
   `32-byte PRF seed ──sha256("bao:nostr:v1:"… + scalar check)──▶ Nostr keypair`. Its README
   *does not address passkey loss at all* — no recovery code, no backup, no fallback
   [V, github.com/baocommunity/bao-signer]. **The composition the bundle claims is unbuilt is
   in fact built — and the thing it did not solve is precisely the thing `CRUCIBLE.md`
   deferred.** See §6 on the "unbuilt" claim.
7. **PRF is device-bound on hardware authenticators.** A YubiKey's PRF output never leaves
   that key [R] — the hmac-secret `credRandom` is authenticator-resident. Any user who
   registers with a security key instead of a synced passkey gets a *non-portable* identity
   from the same code path, with no signal distinguishing them.

---

## 4. SOLUTION SPACE — how prior art solved it
> **⚠ WITHHELD from the next movement.** Spark must generate against §2 and §3 without
> reading this section. It is recorded here so the design pass can check itself later.

- **The universal pattern, and the candidate inverts it: every shipped product uses PRF to
  WRAP a key, never to BE the key.** Bitwarden, verified at primary: *"A **PRF public and
  private key pair** is generated by the Bitwarden client. The PRF public key encrypts your
  **account encryption key**"*, and *"The **PRF private key** is used to decrypt your
  PRF-encrypted account encryption key, resulting in your account encryption key"*
  [V, bitwarden.com/help/login-with-passkeys/]. The account key exists independently; PRF is
  one door into it. Note the trap: Bitwarden's *blog* phrasing — *"using the PRF salt as a
  basis for the HMAC-based Key Derivation Function (HKDF)"* — reads as derivation and is
  easy to cite wrongly. The help docs are the authority, and they describe **wrapping**.
- **The fallback is explicit and human-legible.** Bitwarden: *"your master password is
  required to unlock your vault, so it must be strong and memorable."* [V]
- **Cappalli names the exact property that makes wrapping legitimate and deriving not:**
  credential managers *"have robust mechanisms to protect your vault data with multiple
  methods, such as master passwords, per-device keys, recovery keys, and social recovery
  keys. Losing access to a passkey used to unlock your credential manager rarely leads to
  complete loss of your vault data."* [V] **The distinction is not PRF-vs-no-PRF. It is
  n=1-door vs n>1-doors.** A wrapped root with two independent wrappers is a *known-keys
  SET* — which is exactly the shape `project_in_app_key_backup_decided` already ruled for
  (Nick, 2026-09-16: *"a backup IS multi-device n=2, so the fix is a known-keys SET"*).
- **Cappalli's asks of an RP that uses PRF anyway** — upfront warning, support documentation
  explaining the PRF implementation, and registration in the Well-Known URL for Relying
  Party Passkey Endpoints [V]. A concrete, cheap conformance checklist.
- **Shared-RP-ID mechanics.** ROR: `application/json` at `https://{RP ID}/.well-known/webauthn`
  with an `origins` array; *"WebAuthn requires client implementations to support at least 5
  unique labels… treat that as the maximum"*; and *"app platforms have existing
  mechanisms — Digital Asset Links for Android and Associated Domains for Apple — making ROR
  unnecessary for native applications"* [V, passkeys.dev]. iOS's native origin is literally
  `https://<rpId>` [V, Corbado], which means the island's existing
  `expected_origin == f"https://{rp_id}"` check keeps working unchanged under a shared RP-ID
  on iOS; only Android needs `passkey_extra_origins`.
- **Hierarchical derivation, chosen against.** SLIP-0010's ed25519 profile is hardened-only
  with no public derivation [V]; HKDF with a domain label is the simpler equivalent (C9).
- **Blinding, the shape if it ever lands.** Tor derives a per-period blinded keypair
  `(a', A')` via SHA3-256 over the master public key, a seed, the basepoint and a period-
  derived blind factor, *"which boils down to regular Ed25519 with a derived key pair"*
  [V, Tor keyblinding-scheme]. The seed is the per-island scope; the recipient who is given
  the blind factor can link, everyone else cannot — which is the capability-per-recipient
  property the candidate wants.

---

## 5. THE INVERTED RISK, PRICED

The brief asks which failure mode is genuinely worse. The honest answer is that they are not
the same *kind* of risk, and the comparison the candidate makes is with the wrong baseline.

| | Today (minted per-install, device-local) | Candidate (derived from passkey) |
|---|---|---|
| **Who can destroy the identity** | the user, by losing the handset | the user, **plus Apple/Google** (account lockout, provider migration), **plus the credential-manager UI**, which offers deletion with no warning [V] |
| **Failure is visible** | yes — new install, new key, obvious | **no** — a diverged PRF yields a valid key and valid signatures under a new pubkey |
| **Recovery exists** | no (recorded: *"no recovery path exists at all"*) | **no, unless something other than the passkey also wraps the root** |
| **Failure rate** | high (every handset loss) | lower, but **correlated across the whole user base** — one platform regression moves everyone at once, as iOS 18.0–18.3 demonstrated [V] |

Two things follow, and they point in opposite directions, which is why this is the design's
real fork rather than a fact to look up:

- The candidate is a **genuine improvement in the common case** — it converts a certain loss
  (handset gone) into a rare one, and C4 in `federated-identity-anchor/TEMPER.md` is indeed
  dissolved on its own premise, exactly as `CRUCIBLE.md` argues. That argument holds.
- But it **adds a new custodian the user does not control and cannot audit**, converts a
  loud failure into a silent one, and correlates the residual risk across every user. That
  is a different shape of harm, not a smaller amount of the same one. And §7's 1997 escrow
  paper — already in the record at `key-backup-and-known-keys/RESEARCH.md` — says the thing
  worth re-reading here: for *signature* keys the answer to loss has always been
  **revocation and re-issue**, not recovery. An identity that can rotate does not need its
  root to be immortal.

Sharpest available framing, stated as a finding rather than a recommendation: **the
candidate's value comes from the passkey being one authoritative door to the root. Every
priced failure mode above comes from it being the ONLY door.** Those are separable.

---

## 6. THE "UNBUILT" CLAIM — REFUTED IN PART

The bundle claims the composition is unbuilt. Checked, and the claim needs narrowing:

- **Signal, Matrix/Element, Session, Keybase: no evidence of WebAuthn-PRF-rooted signing
  identity found** [U — absence of evidence across the searches run here, not a verified
  negative. Do not upgrade this to "verified none do."]
- **Nostr: built, and shipping.** `bao-signer` — *"turns a passkey into a Nostr identity — no
  seed phrases, no extensions, no custodial key storage"* — derives the secp256k1 signing key
  from the PRF seed with a domain-separated SHA-256 [V]. This is the candidate's exact
  architecture on a different curve and a different network.
- **Breez SDK** is reported to use WebAuthn PRF for wallet key material [R, gist comparison].
- **Bitwarden / 1Password / Proton**: PRF for vault unlock — and, as §4 shows, **wrapping,
  not deriving**. They are prior art *against* the candidate's construction, not for it.

**The honest version of the novelty claim:** deriving a signing identity from PRF is built
(Nostr). What is genuinely absent from the searched record is **per-island blinded child keys
turning cross-island linkage into a per-recipient capability** — the tier C10 says cannot be
built in Dart yet. `CRUCIBLE.md` was right that blinding and linkage-as-a-user-facing-object
are absent from `docs/`; it should not also claim the PRF-rooted-signing-identity composition
is unbuilt.

---

## 7. WHAT IS NEW HERE vs `key-backup-and-known-keys/RESEARCH.md`

That pass established: the PRF spec surface, Chromium's Intent-to-Ship language, the
iOS 18/18.4 milestones, `largeBlob` vs PRF, the "flag can lie / probe by deriving" rule
(`:1324-1365`, `:2154`), and the 1997 Abelson et al. escrow argument against recovering
*signature* keys. None of that is re-derived above. New in this pass:

1. **The hybrid-path divergence, with the two hex outputs and Apple's own confirmation** —
   the concrete mechanism by which F1 fails, which the earlier pass did not have. (§3.1–3.3)
2. **Apple silently changed PRF output once already and never answered the migration
   question** — evidence that PRF is not a stable contract. (§3.2)
3. **Tim Cappalli's 2026-02-27 warning**, post-dating the earlier pass, from the WebAuthn L3
   co-editor, aimed precisely at this composition — and the *reason* he exempts credential
   managers (n>1 doors), which is the design lever. (§4, F4)
4. **Bitwarden WRAPS, it does not DERIVE** — verified at the help docs, with the blog
   citation-trap flagged. The earlier pass listed PRF as a backup *form*; it did not record
   that every shipped product uses it as a wrapper. (§4)
5. **F3: the app's locked packages have no PRF at all** — repo-specific, verified by grep,
   and a prerequisite nobody had noticed. (§1)
6. **F2 answered, and answered cheaply** — ROR is unnecessary for native apps; the binding
   constraint is the island's boot invariant, located at file and line in the peer repo, plus
   forced re-registration (C6–C8). Tesla #4 flagged the axis; this is its resolution.
7. **C10: blinding is not implementable on today's Dart stack** — verified against the locked
   `cryptography` 2.9.0, `pointycastle` 4.0.0, `ed25519_edwards`, and `edwards25519`, with
   the libsodium FFI primitives named and the binding gap marked `[U]`.
8. **C9: HKDF beats SLIP-0010 here, with zero new dependencies** — `cryptography` 2.9.0
   already ships `Hkdf`.
9. **The cross-tab record already points the same way** — island Design 04 makes the passkey
   the identity root *with a mandated recovery hatch*, and prices QR-hybrid onboarding at
   52–76%. Read per CLAUDE.md's cross-tab directive; it both supports the candidate and
   constrains it. (C5, C12)
10. **Prior art found and the novelty claim narrowed** — `bao-signer`. (§6)

---

## 8. WHAT HEAT LEAVES ON THE ANVIL

Three questions Spark and Cast must answer, all of them now sharp rather than open:

1. **Given C1+C5, what does the app do when it cannot derive?** (hybrid ceremony, hardware
   key, third-party manager with no PRF, pre-bump build.) The answer cannot be "fail" —
   passkeys are the sole ingress.
2. **Given C8, what happens to 56 existing users when the RP-ID changes?** The #4831 arc just
   decided *not* to build seed-migration machinery for 217 messages. This candidate re-asks
   that question with the same corpus and a worse failure mode.
3. **Given F4+§5, is the root derived or wrapped?** Every shipped product wraps. Wrapping
   keeps C4's dissolution (the passkey still recovers the root) while removing the
   single-door failure — and it is the shape Nick already ruled for on 2026-09-16
   (*known-keys SET*). Deriving is simpler and has one fewer secret to store. **This is the
   fork, and it is not resolvable by more research.**

---

## Sources

- [W3C WebAuthn — PRF extension](https://w3c.github.io/webauthn/#prf-extension)
- [Apple Developer Forums 764730 — Different PRF output, platform vs cross-platform](https://developer.apple.com/forums/thread/764730)
- [Apple Developer Forums 774112 — PRF not supported in Safari cross-device flow](https://developer.apple.com/forums/thread/774112)
- [ASAuthorizationPublicKeyCredentialPRFAssertionInput](https://developer.apple.com/documentation/authenticationservices/asauthorizationpublickeycredentialprfassertioninput-swift.struct)
- [ASAuthorizationPublicKeyCredentialPRFRegistrationInput](https://developer.apple.com/documentation/authenticationservices/asauthorizationpublickeycredentialprfregistrationinput-swift.struct)
- [Tim Cappalli — Please, please, please stop using passkeys for encrypting user data (2026-02-27)](https://blog.timcappalli.me/p/passkeys-prf-warning/)
- [lilting.ch — WebAuthn PRF for encryption keys? The spec co-editor says don't](https://lilting.ch/en/articles/passkeys-prf-extension-encryption-risk)
- [Bitwarden — Log in with passkeys (help docs)](https://bitwarden.com/help/login-with-passkeys/)
- [Bitwarden — PRF WebAuthn and its role in passkeys (blog)](https://bitwarden.com/blog/prf-webauthn-and-its-role-in-passkeys/)
- [Corbado — Passkeys & WebAuthn PRF for End-to-End Encryption (2026)](https://www.corbado.com/blog/passkeys-prf-webauthn)
- [Corbado — WebAuthn origin validation in the context of native apps](https://www.corbado.com/blog/webauthn-origin-validation-native-apps)
- [passkeys.dev — Related Origin Requests](https://passkeys.dev/docs/advanced/related-origins/)
- [web.dev — Allow passkey reuse across your sites with Related Origin Requests](https://web.dev/articles/webauthn-related-origin-requests)
- [Yubico — PRF extension developer guide](https://developers.yubico.com/WebAuthn/Concepts/PRF_Extension/Developers_Guide_to_PRF.html)
- [Tor rend-spec Appendix A — signature scheme with key blinding](https://spec.torproject.org/rend-spec/keyblinding-scheme.html)
- [IETF CFRG — draft-irtf-cfrg-signature-key-blinding-02](https://www.ietf.org/archive/id/draft-irtf-cfrg-signature-key-blinding-02.html)
- [Eaton, Lehmann et al. — Security Analysis of Signature Schemes with Key Blinding (eprint 2023/380)](https://eprint.iacr.org/2023/380.pdf)
- [Tor source — src/ext/ed25519/ref10/blinding.c](https://fossies.org/linux/tor/src/ext/ed25519/ref10/blinding.c)
- [SLIP-0010](https://github.com/satoshilabs/slips/blob/master/slip-0010.md)
- [pub.dev — ed25519_edwards API docs](https://pub.dev/documentation/ed25519_edwards/latest/edwards25519/edwards25519-library.html)
- [pub.dev — edwards25519](https://pub.dev/packages/edwards25519)
- [pub.dev — ed25519_hd_key](https://pub.dev/packages/ed25519_hd_key)
- [libsodium — point*scalar multiplication](https://libsodium.gitbook.io/doc/advanced/scalar_multiplication)
- [libsodium — finite field arithmetic](https://libsodium.gitbook.io/doc/advanced/point-arithmetic)
- [sodium-native #153 — missing bindings for crypto_core_ed25519_scalar_mul](https://github.com/sodium-friends/sodium-native/issues/153)
- [bao-signer — passkey-first Nostr signing](https://github.com/baocommunity/bao-signer)
