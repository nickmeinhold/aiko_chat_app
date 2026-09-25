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

  /// Envelope key version. `1` today. A future rotation/revocation lifecycle
  /// (federation) can distinguish active/retired/compromised keys by bumping
  /// this; the slot is reserved now so that migration is additive, not a break.
  final int keyVersion;

  const SovereignKey({
    required this.keyPair,
    required this.rawPublicKey,
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

  /// The pre-#4831 unscoped name. READ ONLY, and only to be adopted once —
  /// never written again. See [_adoptLegacySeed].
  static const _kLegacySeed = 'aiko_sov_private_seed';
  static const _keyVersion = 1;

  static final Ed25519 _ed25519 = Ed25519();

  final FlutterSecureStorage _storage;

  /// Single-flight guard: the private seed is the identity, so two concurrent
  /// first-use calls minting two keypairs would ORPHAN one (cage-match: Tesla).
  /// Caching the in-flight future makes [loadOrCreate] idempotent within a store
  /// instance — every caller awaits the same generation. (The store is a
  /// singleton `Provider`, so this is the process-wide first-use gate.)
  Future<SovereignKey>? _inflight;

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
    if (uid == null) {
      final fresh = await _ed25519.newKeyPair();
      return _materialise(
        Uint8List.fromList(await fresh.extractPrivateKeyBytes()),
      );
    }

    final seedKey = _seedKeyFor(uid);
    final stored = await _storage.read(key: seedKey);
    if (stored != null) {
      // Covers the crash window in [_adoptLegacySeed] on THIS account's next
      // run: a legacy seed that survived its own deletion is swept here.
      await _sweepLegacySeed();
      return _materialise(base64Decode(stored));
    }

    final adopted = await _adoptLegacySeed(seedKey);
    if (adopted != null) return _materialise(adopted);

    // First use for this account on this device: mint + persist the 32-byte
    // seed. The public key is always DERIVED from the seed, never stored
    // separately — a second persisted artifact with no consistency contract is
    // dead weight and a drift hazard (cage-match: Carnot).
    final fresh = await _ed25519.newKeyPair();
    final seed = Uint8List.fromList(await fresh.extractPrivateKeyBytes());
    await _storage.write(key: seedKey, value: base64Encode(seed));
    return _materialise(seed);
  }

  /// ADOPT THE PRE-#4831 UNSCOPED SEED, ONCE, FOR THE FIRST ACCOUNT TO ASK.
  ///
  /// Every existing install has a seed under [_kLegacySeed] with signed history
  /// and a Carried Record behind it. Minting fresh would be the easy
  /// implementation and the wrong one: it orphans that authorship, because
  /// pubkey IS the author and nothing else claims those messages.
  ///
  /// **Why FIRST-to-ask, and where that is merely the best local answer.** On a
  /// single-account handset — overwhelmingly the common case — the first account
  /// to ask is the only account, and adoption is exact. On a handset that has
  /// held two accounts the legacy seed names both of them and NOTHING ON THIS
  /// DEVICE records which one owned it; the ambiguity is in the data, not in
  /// this policy. The island can settle it exactly (`GET /v1/keys` lists a
  /// user's registered pubkeys with first/last-seen, so "is this legacy pubkey
  /// already mine?" is answerable), at the cost of a network round trip on the
  /// signing path's first load. Deliberately NOT done here: see #4831.
  ///
  /// **The write precedes the delete and the order is load-bearing.** A crash
  /// between them leaves the identity safe under the scoped name and the legacy
  /// seed still on disk — a narrow window in which a DIFFERENT account could
  /// adopt it, closed by [_sweepLegacySeed] on this account's next load.
  /// Delete-then-write reads tidier and loses the identity outright on the same
  /// crash, which is permanent. A correlation window is recoverable; an orphaned
  /// authorship history is not.
  Future<Uint8List?> _adoptLegacySeed(String seedKey) async {
    final legacy = await _storage.read(key: _kLegacySeed);
    if (legacy == null) return null;
    await _storage.write(key: seedKey, value: legacy);
    await _storage.delete(key: _kLegacySeed);
    return base64Decode(legacy);
  }

  /// Best-effort removal of a legacy seed that outlived its adoption. Never
  /// throws into the signing path: failing to tidy is not failing to sign.
  Future<void> _sweepLegacySeed() async {
    try {
      await _storage.delete(key: _kLegacySeed);
    } catch (_) {
      // The next load tries again. A seed we cannot delete is not a seed we
      // are using.
    }
  }

  Future<SovereignKey> _materialise(Uint8List seed) async {
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    return SovereignKey(
      keyPair: keyPair,
      rawPublicKey: Uint8List.fromList(pub.bytes),
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
    if (uid != null) await _storage.delete(key: _seedKeyFor(uid));
  }
}
