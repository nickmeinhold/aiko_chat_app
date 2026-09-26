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

  /// Single-flight guard within one instance: the private seed is the identity,
  /// so two concurrent first-use calls minting two keypairs would ORPHAN one
  /// (cage-match: Tesla). It collapses concurrent callers of the SAME instance.
  /// It is not a cross-account gate, and nothing here needs one any more — see
  /// [_discardLegacySeed].
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
  ///   44 signed messages, 19 author pubkeys, and the unscoped seed shared by
  ///   exactly ONE pair of accounts — both of them the same person's.
  ///
  /// Adoption existed to preserve authorship continuity. The corpus it was
  /// protecting is 44 messages on a pre-launch app, and the one ambiguous case is
  /// answerable by asking its owner. So the seed is discarded and every account
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
      // The next load tries again — and unlike the version this replaced, that
      // promise is true: no memo sits between a caller and this call.
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
    _inflight = null;
    final uid = userId;
    if (uid != null && uid.isNotEmpty) {
      await _storage.delete(key: _seedKeyFor(uid));
    }
  }
}
