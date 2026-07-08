import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The device's sovereign Ed25519 signing key — the phone-as-self identity the
/// federation north-star rests on (Design 06/08). Distinct from the JWT
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
  static const _kSeed = 'aiko_sov_private_seed';
  static const _kPublic = 'aiko_sov_public_key';
  static const _keyVersion = 1;

  static final Ed25519 _ed25519 = Ed25519();

  final FlutterSecureStorage _storage;

  SovereignKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  /// Load the persisted device key, generating + persisting one on first use.
  /// Idempotent: the same device always resolves to the same key until [clear].
  Future<SovereignKey> loadOrCreate() async {
    final storedSeed = await _storage.read(key: _kSeed);
    if (storedSeed != null) {
      final keyPair = await _ed25519.newKeyPairFromSeed(base64Decode(storedSeed));
      final pub = await keyPair.extractPublicKey();
      return SovereignKey(
        keyPair: keyPair,
        rawPublicKey: Uint8List.fromList(pub.bytes),
        keyVersion: _keyVersion,
      );
    }
    // First use on this device: mint + persist.
    final keyPair = await _ed25519.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();
    await _storage.write(key: _kSeed, value: base64Encode(seed));
    await _storage.write(key: _kPublic, value: base64Encode(pub.bytes));
    return SovereignKey(
      keyPair: keyPair,
      rawPublicKey: Uint8List.fromList(pub.bytes),
      keyVersion: _keyVersion,
    );
  }

  /// Wipe the device key. A subsequent [loadOrCreate] mints a fresh identity —
  /// which, pre-federation, reads as a NEW author (no recovery; named-deferred).
  Future<void> clear() async {
    await _storage.delete(key: _kSeed);
    await _storage.delete(key: _kPublic);
  }
}
