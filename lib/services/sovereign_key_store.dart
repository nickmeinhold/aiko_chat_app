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
  static String _seedKeyFor(String userId) => 'aiko_sov_private_seed_$userId';

  /// Ed25519 private seeds are exactly 32 bytes. A stored value of any other
  /// length is corruption, not a key — caught before it is written or used.
  static const _seedLengthBytes = 32;
  static const _kSeedCorrupt = 'sovereign seed for this account is corrupt';

  /// The pre-#4831 unscoped name. DELETED, never read for its value.
  /// See [_discardLegacySeed].
  static const _kLegacySeed = 'aiko_sov_private_seed';
  static const _keyVersion = 1;

  static final Ed25519 _ed25519 = Ed25519();

  final FlutterSecureStorage _storage;

  /// SINGLE MINT PER STORE INSTANCE — and that is LESS than it sounds, which is
  /// the whole reason this doc is long.
  ///
  /// It collapses concurrent callers of THIS object, which is what stops one
  /// `loadOrCreate` from minting twice. It is **not** single-mint-per-account, and
  /// for three review rounds the comment here claimed it was.
  ///
  /// **THE ACCEPTED RACE (Tesla, round 3).** `sovereignKeyStoreProvider` rebuilds a
  /// new store when the watched `userId` changes, and the old instance is not dead:
  /// `chatRepositoryProvider` captures it, awaits channels and DMs, and only then
  /// calls `loadOrCreate`. A sign-out-and-back-in inside that window leaves TWO
  /// live stores for the SAME account, each with an empty memo. Both read the
  /// scoped slot, both find null, both mint, both write. Last write owns the disk,
  /// so the session may sign with the seed that lost — an author the next cold
  /// start cannot find. Discarding rather than adopting the legacy seed is what
  /// makes it reachable: every scoped slot now starts empty, so every account's
  /// first load is a mint.
  ///
  /// **Accepted rather than fixed. Owner: #4831. Cost: one possibly-orphaned seed
  /// for one session, on a sign-out/sign-in landing inside one await window.**
  ///
  /// The reason is measured, three times. Keying the single-flight on the SLOT
  /// instead of the instance is the correct axis and it broke the suite every way
  /// it was tried, always the same way: production builds every store with
  /// `const FlutterSecureStorage()`, which Dart canonicalises to ONE object, so any
  /// process-shared map keyed off it is shared by every widget test in a file while
  /// the mock's backing resets per test. A round-2 attempt (one `static` future
  /// chain) wedged 4 tests and would have wedged production identically; a round-3
  /// attempt (an `Expando` of per-slot memos) broke 123. Each fix was worse than
  /// the finding it closed.
  ///
  /// So the defect being repaired here is the **overclaiming comment**, which is
  /// what would mislead the next maintainer. The race is named, priced and left.
  /// The real fix is to stop `chatRepositoryProvider` holding a store across its
  /// awaits — resolve the key from the same live snapshot that will own the repo —
  /// and that is a change to the provider graph, not to this class.
  ///
  /// Do NOT add a lock here. Three rounds say the lock is the wrong move; the
  /// coupling is instance-lifetime versus slot-lifetime, and it is owned upstream.
  Future<SovereignKey>? _inflight;

  /// The account this store signs for. NULL — or empty, which is the same state —
  /// means no session, and that is first-class rather than an error: the repo can
  /// build before auth answers, as `cacheProvider` already tolerates. It gets an
  /// EPHEMERAL key that is never persisted, because persisting one would put an
  /// unscoped seed back on disk under a new name.
  final String? userId;

  SovereignKeyStore({this.userId, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Load this account's persisted key, minting one on first use. Idempotent:
  /// the same (device, account) resolves to the same key until [clear].
  Future<SovereignKey> loadOrCreate() => _inflight ??= _guardedLoad();

  Future<SovereignKey> _guardedLoad() async {
    try {
      return await _loadOrCreate();
    } catch (_) {
      _evictMemo();
      rethrow;
    }
  }

  /// Drop the memoised load so a later call can retry. Caching a REJECTED future
  /// would mute signing until process death on one transient keychain error
  /// (cage-match Tesla R2) — and now that the memo is shared across instances,
  /// failing to evict would brick the account for every future store too.
  void _evictMemo() => _inflight = null;

  Future<SovereignKey> _loadOrCreate() async {
    final uid = userId;
    // An empty id is the same state as a null one. `_seedKeyFor('')` would be a
    // single shared slot every empty-id session resolved to — this class's own
    // defect under a new name. `carried_record_screen.dart` already reads
    // `userId.isEmpty` as "not known yet", so the value is reachable.
    if (uid == null || uid.isEmpty) {
      return _materialise(await _mintSeed(), null);
    }

    // Fire-and-forget, and it needs no ordering against anything below because
    // nothing reads those bytes. See [_discardLegacySeed].
    unawaited(_discardLegacySeed());

    final seedKey = _seedKeyFor(uid);
    final stored = await _storage.read(key: seedKey);
    if (stored != null) return _materialise(_decodeSeed(stored), uid);

    final seed = await _mintSeed();
    await _storage.write(key: seedKey, value: base64Encode(seed));
    return _materialise(seed, uid);
  }

  /// DELETE THE PRE-#4831 UNSCOPED SEED. Do not adopt it.
  ///
  /// **This replaces an entire migration design, and the reason is a number.**
  /// Two cage-match rounds and a four-family design temper produced twenty-three
  /// findings about *adopting* that seed — exclusivity, serialisation, decode
  /// ordering, quarantine, tombstones, island veto, offline first-launch. Every
  /// one of them lived in the adoption path. Then somebody asked whether this was
  /// overcomplicated, and the live island answered:
  ///
  ///   217 signed messages across BOTH live islands (173 on enspyr, 44 on
  ///   imagineering), 30 author pubkeys, and the unscoped seed shared by exactly
  ///   ONE pair of accounts — both of them the same person's.
  ///
  /// Adoption existed to preserve authorship continuity. The corpus it was
  /// protecting is 217 messages on a pre-launch app, and the one ambiguous case is
  /// answerable by asking its owner. (The first count said 44 — imagineering only,
  /// one island of two. The island tab checked the other rather than agreeing; the
  /// bigger, older corpus has NO sharing, so the dissolve got stronger.) So the seed is discarded and every account
  /// mints its own: nineteen pubkeys stop matching new signatures, and in exchange
  /// twenty-three findings become unreachable rather than fixed.
  ///
  /// The mistake was inherited and never priced. The island's `signing_keys` rows
  /// and persisted `origin.sender_pubkey` ARE immutable — so we read "adopt-then-
  /// scope is the only order that works" as a law. Immutability makes history
  /// unfixable; it does not make it valuable. Nothing measured what was at stake
  /// until the question was asked out loud.
  ///
  /// Unconditional, unvalidated, unordered, and failure-tolerant — the three
  /// properties that cost the most are all gone at once. We are not going to use
  /// these bytes, so they need not decode, need not be 32 bytes long, and need not
  /// be gone before anything else happens. A delete that fails is retried on the
  /// next load. Nothing can race it, because no other code path names this key.
  Future<void> _discardLegacySeed() async {
    try {
      await _storage.delete(key: _kLegacySeed);
    } catch (_) {
      // BEST-EFFORT PER STORE INSTANCE, not per call, and the distinction is one
      // Carnot has now had to make three times. `loadOrCreate` memoises its result
      // in `_inflight`, so a second call on THIS instance never re-enters
      // `_loadOrCreate` and never reaches here. A retry happens when the provider
      // rebuilds and constructs a new store — which is a different sentence from
      // "the next load tries again", and the version of this comment that said the
      // shorter thing was simply wrong. Nothing depends on the delete succeeding:
      // no code path reads this key for its value.
    }
  }

  Future<Uint8List> _mintSeed() async {
    final fresh = await _ed25519.newKeyPair();
    return Uint8List.fromList(await fresh.extractPrivateKeyBytes());
  }

  /// Decode a stored seed, or throw a NAMED error rather than a bare
  /// `FormatException`. Recovery policy (offer a new identity? refuse?) is an open
  /// question on #4831; a caller cannot even ask it while the failure arrives as a
  /// generic decode error from an unnamed layer.
  Uint8List _decodeSeed(String encoded) {
    Uint8List seed;
    try {
      seed = base64Decode(encoded);
    } catch (_) {
      throw StateError(_kSeedCorrupt);
    }
    if (seed.length != _seedLengthBytes) {
      throw StateError(_kSeedCorrupt);
    }
    return seed;
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
  /// — which, pre-federation, reads as a NEW author. Has no production caller;
  /// whether sign-out should call it is tracked on #4831, and is a question about
  /// ROTATION rather than correlation, which the scoping already takes.
  Future<void> clear() async {
    _evictMemo(); // shared across instances now, so this must clear the slot's memo
    final uid = userId;
    if (uid != null && uid.isNotEmpty) {
      await _storage.delete(key: _seedKeyFor(uid));
    }
  }
}
