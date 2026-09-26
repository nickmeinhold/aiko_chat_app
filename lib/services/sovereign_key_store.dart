import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// This ACCOUNT's sovereign Ed25519 signing key on this device — the
/// phone-as-self identity the federation north-star rests on (Design 06/08). Distinct from the JWT
/// ([SecureTokenStore]): the JWT lets the gateway *assert* who you are; this key
/// lets a message *prove* who authored it, independent of any gateway.
///
/// SOFTWARE key by necessity, not laziness: iOS Secure Enclave and Android
/// StrongBox are NIST P-256-only and cannot hold an Ed25519 key, so every
/// comparable messenger (Signal/WhatsApp/Matrix) stores its Curve25519/Ed25519
/// identity key in software too. The 32-byte private seed lives in
/// [FlutterSecureStorage] (Keychain / Keystore) — encrypted-at-rest and
/// sandbox-isolated from other apps, but extractable by a *privileged* attacker
/// (root/jailbreak/in-process). Named tradeoff [T2]; see
/// `docs/crucible/sovereign-message-signing/{DESIGN,RESEARCH,TEMPER}.md`.
class SovereignKey {
  /// The loaded Ed25519 keypair — the signing capability.
  final SimpleKeyPair keyPair;

  /// The raw 32-byte Ed25519 public key. This is what goes INTO the signed bytes
  /// (key-substitution defence) and, later, onto the wire as a Multikey. Raw here
  /// on purpose — the wire encoding (Multikey vs base64url) is a separate,
  /// still-open decision and must not leak into what we sign.
  final Uint8List rawPublicKey;

  /// THE ACCOUNT THIS KEY BELONGS TO, so a foreign key is DETECTABLE.
  ///
  /// Kelvin and Tesla both landed on the same hole in #4831 round 1: the store is
  /// rebuilt when the user id changes, but a caller that awaited the OLD store's
  /// in-flight load receives the previous account's key, and nothing on the
  /// returned object said whose it was — so no consumer could tell. Null for the
  /// no-session ephemeral key. Stamping it does not prevent the race; it makes the
  /// race's product identifiable, which is what a consumer needs to fail closed.
  final String? userId;

  /// Envelope key version. `1` today. A future rotation/revocation lifecycle
  /// (federation) can distinguish active/retired/compromised keys by bumping
  /// this; the slot is reserved now so that migration is additive, not a break.
  final int keyVersion;

  const SovereignKey({
    required this.keyPair,
    required this.rawPublicKey,
    this.userId,
    this.keyVersion = 1,
  });
}

/// Durable, encrypted store for the sovereign signing key. Mirrors
/// [SecureTokenStore]: an optional injected [FlutterSecureStorage] (real by
/// default, an in-memory fake in tests) and hardcoded key names.
class SovereignKeyStore {
  /// PER-ACCOUNT, and the scoping is the security property (#4831).
  ///
  /// This was a single unscoped name until 2026-09-26, and `clear()` had no
  /// caller, so the seed outlived a sign-out: two accounts used in turn on one
  /// handset signed with the SAME pubkey, and `origin.sender_pubkey` rides in
  /// every message to every recipient. That is a PUBLIC cross-account link,
  /// strictly worse than the island-side one in #4775 — it needs no database
  /// access, only an ordinary sign-out. Nobody decided it; it fell out of the
  /// storage name.
  ///
  /// Scoping by `user_id` gives both halves of what the rulings need at once:
  /// one account on two handsets still mints two keys (so per-message device
  /// attribution works), and two accounts on one handset no longer share one.
  /// STABLE WITHIN AN ACCOUNT, MEANINGLESS ACROSS IT — the same property
  /// #4775 needs, for the same reason.
  static const _kSeedPrefix = 'aiko_sov_private_seed_';
  static String _seedKeyFor(String userId) => '$_kSeedPrefix$userId';

  /// Ed25519 private seeds are exactly 32 bytes. A stored value of any other
  /// length is corruption, not a key — caught before it is written or used.
  static const _seedLengthBytes = 32;
  static const _kSeedCorruptScoped =
      'sovereign seed for this account is corrupt';
  static const _kSeedCorruptLegacy =
      'legacy sovereign seed is corrupt — NOT consumed, left on disk for repair';

  /// The pre-#4831 unscoped name. READ ONLY, and only to be adopted once —
  /// never written again. See [_adoptLegacySeed].
  static const _kLegacySeed = 'aiko_sov_private_seed';
  static const _keyVersion = 1;

  static final Ed25519 _ed25519 = Ed25519();

  final FlutterSecureStorage _storage;

  /// Single-flight guard WITHIN ONE INSTANCE: the private seed is the identity,
  /// so two concurrent first-use calls minting two keypairs would ORPHAN one
  /// (cage-match: Tesla).
  ///
  /// **This is NOT the process-wide gate, and saying it was is what let the
  /// migration bug through.** The doc here used to read "the store is a singleton
  /// `Provider`, so this is the process-wide first-use gate" — true before #4831
  /// and made FALSE by #4831 itself, which replaced the one store with one store
  /// PER ACCOUNT. Tesla caught the fossil: the sentence kept asserting a
  /// guarantee the change had removed, and the adoption path was written trusting
  /// it. Cross-instance serialisation is [_durableGate]; this memo only collapses
  /// concurrent callers of the SAME instance.
  Future<SovereignKey>? _inflight;

  /// SERIALISATION OF THE DURABLE PATH, SCOPED TO THE STORAGE IT PROTECTS.
  ///
  /// [_inflight] cannot serialise two accounts, and the legacy slot is global, so
  /// read-check-write across two instances interleaves (Carnot + Tesla,
  /// independently). Dart is single-isolate, so chaining every durable section
  /// onto one future is a real mutex rather than an approximation of one.
  ///
  /// **KEYED ON THE STORAGE, NOT ON THE PROCESS, AND THAT IS THE FIX FOR MY OWN
  /// LAST ATTEMPT.** Round 2 of #4831 made this one `static Future<void>` — a
  /// process-wide chain — which wedged 4 tests and would have wedged PRODUCTION
  /// the same way: the contested resource is the KEYCHAIN, and putting the lock
  /// on the process instead meant anything that shared the process shared the
  /// lock. An [Expando] keyed on the storage object gives the granularity for
  /// free: in production every store holds `const FlutterSecureStorage()`, which
  /// Dart canonicalises to ONE instance, so the lock is process-wide exactly
  /// where it must be; a test with its own fake backing gets its own chain.
  static final Expando<Future<void>> _gates = Expando<Future<void>>(
    'sovereign seed durable gate',
  );

  /// How long a caller waits for the predecessor before going ahead anyway.
  ///
  /// **A DEAD HOLDER MUST NOT BE ABLE TO WEDGE SIGNING, and an unbounded chain
  /// lets it.** That is what actually broke: a widget test torn down mid-load
  /// left a section that never completed, and every later load queued behind it
  /// forever. My comment at the time said "failures do not poison the chain",
  /// which was true of a section that THROWS and said nothing about one that
  /// never finishes — the distinction the measurement found and the prose had
  /// not considered.
  ///
  /// The tradeoff is named rather than hidden: on timeout the section runs
  /// UNSERIALISED, so a concurrent adopt becomes possible again in that one
  /// pathological case. That is strictly better than the alternative, because
  /// [_legacyAlreadyClaimed] still refuses an already-claimed seed on every
  /// ordering except a true simultaneous read, whereas a wedged chain breaks
  /// signing for every account outright and never recovers.
  static const _gateTimeout = Duration(seconds: 5);

  /// Run [body] after the previously-enqueued section on this storage completes,
  /// or after [_gateTimeout], whichever comes first.
  Future<T> _serialised<T>(Future<T> Function() body) {
    final prior = _gates[_storage] ?? Future<void>.value();
    final done = Completer<void>();
    _gates[_storage] = done.future;
    return prior
        // Errors AND hangs both fall through to running the body: the previous
        // caller's failure is not this caller's, and its silence is not either.
        .timeout(_gateTimeout, onTimeout: () {})
        .catchError((_) {})
        .then((_) => body())
        .whenComplete(done.complete);
  }

  /// The account this store signs for. NULL means no session, and that is a
  /// first-class state rather than an error: [cacheProvider] already tolerates
  /// it with an ephemeral in-memory DB, and the repo can build before auth has
  /// answered. A null user gets an EPHEMERAL key that is never persisted — see
  /// [loadOrCreate]. Persisting one would re-create the unscoped seed under a
  /// new name, which is the defect this class just removed.
  final String? userId;

  SovereignKeyStore({this.userId, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Load this account's persisted key, generating + persisting one on first
  /// use. Idempotent: the same (device, account) always resolves to the same
  /// key until [clear].
  ///
  /// With a null [userId] the key is minted fresh and NEVER WRITTEN — an
  /// unsigned-in session can sign nothing durable, and a persisted unscoped
  /// seed is exactly the #4831 defect. It is still memoised, so the one
  /// process-wide gate below still holds for it.
  Future<SovereignKey> loadOrCreate() => _inflight ??= _guardedLoad();

  /// Caches only a SUCCESSFUL load. A failed first-use (secure-storage I/O error,
  /// seed corruption) EVICTS the cached future so a later call can retry — else a
  /// transient fault would permanently mute signing until process death
  /// (cage-match Tesla R2: don't cache a rejected Future forever).
  Future<SovereignKey> _guardedLoad() async {
    try {
      return await _loadOrCreate();
    } catch (_) {
      _inflight = null;
      rethrow;
    }
  }

  Future<SovereignKey> _loadOrCreate() async {
    final uid = userId;
    // NO SESSION: mint, never persist. Writing here would put an unscoped seed
    // back on disk under a new name and hand it to whoever signs in next —
    // the #4831 defect with extra steps.
    //
    // AN EMPTY ID IS THE SAME STATE AS A NULL ONE, and treating it otherwise was
    // a live hole (Maxwell, round 1): `_seedKeyFor('')` is a single shared name
    // that EVERY empty-id session resolves to, so two such accounts would sign
    // with one pubkey — this defect, re-created under a new name by the fix for
    // it. `carried_record_screen.dart` already reads `userId.isEmpty` as
    // "not known yet", which is this repo's own evidence the value is reachable.
    if (uid == null || uid.isEmpty) {
      return _materialise(await _mintSeed(), null);
    }

    // Everything below touches durable, SHARED state — the per-account slot and
    // the one global legacy slot — so it runs inside the process-wide gate. The
    // memo is per instance and cannot serialise two accounts.
    return _serialised(() => _loadOrCreateDurable(uid));
  }

  Future<SovereignKey> _loadOrCreateDurable(String uid) async {
    final seedKey = _seedKeyFor(uid);
    final stored = await _storage.read(key: seedKey);
    if (stored != null) {
      // Tidying only, and labelled as such. It used to be load-bearing — the
      // "narrow window" the adoption comment claimed it closed — which was a
      // misdiagnosis: a leftover NAME is recoverable, a leftover COPY is the
      // original cross-account link and this cannot un-write one. Exclusivity
      // now lives in [_legacyAlreadyClaimed], where a failure to delete costs
      // nothing (Tesla + Carnot, round 1).
      await _sweepLegacySeed();
      return _materialise(_decodeSeed(stored, _kSeedCorruptScoped), uid);
    }

    final adopted = await _adoptLegacySeed(seedKey);
    if (adopted != null) return _materialise(adopted, uid);

    // First use for this account on this device: mint + persist the 32-byte
    // seed. The public key is always DERIVED from the seed, never stored
    // separately — a second persisted artifact with no consistency contract is
    // dead weight and a drift hazard (cage-match: Carnot).
    final seed = await _mintSeed();
    await _storage.write(key: seedKey, value: base64Encode(seed));
    return _materialise(seed, uid);
  }

  Future<Uint8List> _mintSeed() async {
    final fresh = await _ed25519.newKeyPair();
    return Uint8List.fromList(await fresh.extractPrivateKeyBytes());
  }

  /// ADOPT THE PRE-#4831 UNSCOPED SEED — ONCE, AND ONLY IF NOBODY ELSE HAS.
  ///
  /// Every existing install has a seed under [_kLegacySeed] with signed history
  /// and a Carried Record behind it. Minting fresh would be the easy
  /// implementation and the wrong one: it orphans that authorship, because
  /// pubkey IS the author and nothing else claims those messages.
  ///
  /// **EXCLUSIVITY IS CHECKED, NOT ASSUMED, AND THAT IS THIS METHOD'S WHOLE
  /// POINT.** Round 1 of #4831's cage-match had this read the legacy slot, copy
  /// it to a scoped name, then delete the legacy name — and called a leftover
  /// legacy name a "narrow correlation window closed on the next load". Carnot
  /// and Tesla independently showed that is a misdiagnosis of the failure mode.
  /// Deleting the legacy NAME cannot un-write a scoped COPY, so:
  ///
  ///   Alice adopts. The write lands; the delete throws, or the process dies
  ///   between them. Bob signs in next — he has no scoped seed, so he takes the
  ///   ADOPT branch, not the sweep branch, and copies the same bytes under his
  ///   own name. Two accounts, one pubkey, durable and on the wire: exactly
  ///   #4831, re-created by #4831's migration.
  ///
  /// So the legacy value is adopted only when no scoped slot already holds it.
  /// If one does, this returns null and the caller MINTS — the duplicate becomes
  /// unconstructable rather than guarded, which is the structural fix rather
  /// than a third fence. Serialisation against a concurrent adopter is
  /// [_serialised]; this check alone is not atomic.
  ///
  /// **VALIDATE BEFORE COMMITTING.** The decode used to be the LAST statement,
  /// after the write and the delete, so a corrupt or wrong-length legacy value
  /// was copied to the scoped slot and the original DELETED before anything
  /// checked it — then it threw, and threw again on every cold start, with the
  /// only other copy gone and [clear] having no caller. The PR that introduced
  /// that argued write-before-delete on the grounds that an orphaned authorship
  /// history is unrecoverable, and then orphaned one through the check it never
  /// ran (Maxwell, round 1). Nothing is written until the bytes are known good.
  Future<Uint8List?> _adoptLegacySeed(String seedKey) async {
    final legacy = await _storage.read(key: _kLegacySeed);
    if (legacy == null) return null;

    // Decode FIRST. On failure both slots are left exactly as they were, so the
    // legacy seed survives for a later repair rather than being consumed by a
    // migration that could not use it.
    final seed = _decodeSeed(legacy, _kSeedCorruptLegacy);

    if (await _legacyAlreadyClaimed(legacy)) {
      // Somebody already owns this identity. Do NOT copy it — mint instead, and
      // clear the leftover name so the next account does not re-ask.
      await _sweepLegacySeed();
      return null;
    }

    await _storage.write(key: seedKey, value: legacy);
    await _storage.delete(key: _kLegacySeed);
    return seed;
  }

  /// Is this exact seed already persisted under some account's scoped slot?
  ///
  /// A `readAll` rather than a marker key, because the marker would be a second
  /// artifact with no consistency contract against the thing it describes — the
  /// drift hazard this file already refuses elsewhere. The scoped slots ARE the
  /// record of who has claimed what; ask them.
  Future<bool> _legacyAlreadyClaimed(String legacy) async {
    final all = await _storage.readAll();
    return all.entries.any(
      (e) =>
          e.key != _kLegacySeed &&
          e.key.startsWith(_kSeedPrefix) &&
          e.value == legacy,
    );
  }

  /// Decode a stored seed, or throw a NAMED error rather than a bare
  /// `FormatException`. Recovery policy (offer the user a new identity? refuse?)
  /// is an open question on #4831; a caller cannot even ask it while the failure
  /// arrives as a generic decode error from an unnamed layer.
  Uint8List _decodeSeed(String encoded, String where) {
    Uint8List seed;
    try {
      seed = base64Decode(encoded);
    } catch (_) {
      throw StateError(where);
    }
    if (seed.length != _seedLengthBytes) {
      throw StateError(where);
    }
    return seed;
  }

  /// Best-effort removal of a leftover legacy NAME. Never throws into the
  /// signing path, and — since round 1 — never load-bearing either: exclusivity
  /// is [_legacyAlreadyClaimed]. The old comment here promised "the next load
  /// tries again", which Carnot showed was false: `loadOrCreate` returns the
  /// memoised future, so within one instance the next load never reaches here.
  /// That promise is gone because nothing depends on it any more.
  Future<void> _sweepLegacySeed() async {
    try {
      await _storage.delete(key: _kLegacySeed);
    } catch (_) {
      // A leftover name costs nothing now; the claim check refuses it anyway.
    }
  }

  Future<SovereignKey> _materialise(Uint8List seed, String? owner) async {
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    return SovereignKey(
      keyPair: keyPair,
      rawPublicKey: Uint8List.fromList(pub.bytes),
      userId: owner,
      keyVersion: _keyVersion,
    );
  }

  /// Wipe THIS ACCOUNT's key. A subsequent [loadOrCreate] mints a fresh identity
  /// — which, pre-federation, reads as a NEW author (no recovery;
  /// named-deferred). Has no production caller, and whether sign-out SHOULD call
  /// it is a live question tracked separately in #4831: it trades correlation
  /// against losing authorship continuity on re-login, and scoping already takes
  /// the correlation half.
  Future<void> clear() async {
    _inflight =
        null; // so the next loadOrCreate re-mints rather than returning cache
    final uid = userId;
    if (uid != null && uid.isNotEmpty) {
      await _serialised(() => _storage.delete(key: _seedKeyFor(uid)));
    }
  }
}
