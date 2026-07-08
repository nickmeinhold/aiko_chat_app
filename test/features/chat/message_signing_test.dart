import 'dart:convert';
import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

SignedPayload _fixture(Uint8List pub) => SignedPayload(
      rawPublicKey: pub,
      channelId: 'chan-1',
      clientMsgId: 'tmp-abc',
      signedAtMs: 1720000000000,
      body: 'hello world',
      replyTo: null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SovereignKeyStore', () {
    setUp(installSecureStorageMock);

    test('mints a 32-byte Ed25519 key on first use', () async {
      final key = await SovereignKeyStore().loadOrCreate();
      expect(key.rawPublicKey.length, 32);
      expect(key.keyVersion, 1);
    });

    test('loadOrCreate is stable across a fresh store instance (restart proxy)',
        () async {
      final first = await SovereignKeyStore().loadOrCreate();
      final second = await SovereignKeyStore().loadOrCreate(); // new instance, same storage
      expect(second.rawPublicKey, first.rawPublicKey);
    });

    test('clear() wipes — a subsequent load mints a NEW key', () async {
      final store = SovereignKeyStore();
      final before = await store.loadOrCreate();
      await store.clear();
      final after = await store.loadOrCreate();
      expect(after.rawPublicKey, isNot(before.rawPublicKey));
    });
  });

  group('signingBytes (the pinned canonical serialization)', () {
    test('length-prefixing makes field boundaries unambiguous', () {
      final pub = Uint8List(32);
      // "ab"+"c" must not collide with "a"+"bc" in the channel/client slots.
      final a = signingBytes(SignedPayload(
          rawPublicKey: pub,
          channelId: 'ab',
          clientMsgId: 'c',
          signedAtMs: 0,
          body: 'x'));
      final b = signingBytes(SignedPayload(
          rawPublicKey: pub,
          channelId: 'a',
          clientMsgId: 'bc',
          signedAtMs: 0,
          body: 'x'));
      expect(a, isNot(b));
    });

    test('binds the domain tag (alg) in-bytes', () {
      final bytes = signingBytes(_fixture(Uint8List(32)));
      expect(utf8.decode(bytes.sublist(4, 4 + kSigningDomainTag.length)),
          kSigningDomainTag);
    });

    // GOLDEN VECTOR (CI gate): a fixed key + payload → known signingBytes hex.
    // Deterministic by construction; if this changes, the wire contract broke
    // and every future verifier diverges. See SIGNING-SPEC.md.
    test('golden: signingBytes hex is stable for the spec fixture', () {
      final pub = Uint8List.fromList(List.generate(32, (i) => i)); // 00..1f
      final hex = _hex(signingBytes(_fixture(pub)));
      expect(
        hex,
        '0000001561696b6f636861743a6d73673a76313a4564445341'
        '00000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
        '000000066368616e2d31'
        '00000007746d702d616263'
        '0000019077fd3000' // u64_be(1720000000000)
        '0000000b68656c6c6f20776f726c64'
        '00000000',
      );
    });
  });

  group('sign / verify', () {
    setUp(installSecureStorageMock);

    test('round-trips: a signature verifies against its payload', () async {
      final key = await SovereignKeyStore().loadOrCreate();
      final p = _fixture(key.rawPublicKey);
      final s = await sign(key, p);
      expect(s.sig.length, 64);
      expect(await verifySignature(key.rawPublicKey, s.sig, p), isTrue);
    });

    test('tamper: a flipped body byte fails verification', () async {
      final key = await SovereignKeyStore().loadOrCreate();
      final p = _fixture(key.rawPublicKey);
      final s = await sign(key, p);
      final tampered = SignedPayload(
          rawPublicKey: p.rawPublicKey,
          channelId: p.channelId,
          clientMsgId: p.clientMsgId,
          signedAtMs: p.signedAtMs,
          body: 'hello worlD'); // one byte
      expect(await verifySignature(key.rawPublicKey, s.sig, tampered), isFalse);
    });

    test('tamper: a different channel fails (no cross-channel replay)', () async {
      final key = await SovereignKeyStore().loadOrCreate();
      final p = _fixture(key.rawPublicKey);
      final s = await sign(key, p);
      final otherChannel = SignedPayload(
          rawPublicKey: p.rawPublicKey,
          channelId: 'chan-2',
          clientMsgId: p.clientMsgId,
          signedAtMs: p.signedAtMs,
          body: p.body);
      expect(
          await verifySignature(key.rawPublicKey, s.sig, otherChannel), isFalse);
    });

    test('tamper: a substituted public key fails verification', () async {
      final key = await SovereignKeyStore().loadOrCreate();
      final p = _fixture(key.rawPublicKey);
      final s = await sign(key, p);
      final wrongPub = Uint8List(32); // all-zero, not the signer
      final substituted = SignedPayload(
          rawPublicKey: wrongPub,
          channelId: p.channelId,
          clientMsgId: p.clientMsgId,
          signedAtMs: p.signedAtMs,
          body: p.body);
      expect(await verifySignature(wrongPub, s.sig, substituted), isFalse);
    });

    // Cage-match consensus (Carnot + Tesla): sign() must slam the door on a
    // payload whose pubkey isn't the signing key's — else self-verify passes but
    // the persisted pubkey can't verify (wrong-forever history).
    test('sign REJECTS a payload pubkey != the signing key', () async {
      final key = await SovereignKeyStore().loadOrCreate();
      final wrongPub = Uint8List(32); // valid length, wrong key
      final p = _fixture(wrongPub);
      expect(() => sign(key, p), throwsArgumentError);
    });
  });

  group('domain-bounds validation (cage-match: Carnot — fail loud at the boundary)', () {
    SignedPayload payload({
      Uint8List? pub,
      String channelId = 'c',
      String clientMsgId = 'm',
      int signedAtMs = 1,
      String? replyTo,
    }) =>
        SignedPayload(
            rawPublicKey: pub ?? Uint8List(32),
            channelId: channelId,
            clientMsgId: clientMsgId,
            signedAtMs: signedAtMs,
            body: 'b',
            replyTo: replyTo);

    test('a non-32-byte public key is rejected', () {
      expect(() => signingBytes(payload(pub: Uint8List(31))), throwsArgumentError);
    });
    test('an empty channelId / clientMsgId is rejected', () {
      expect(() => signingBytes(payload(channelId: '')), throwsArgumentError);
      expect(() => signingBytes(payload(clientMsgId: '')), throwsArgumentError);
    });
    test('a negative signedAtMs is rejected', () {
      expect(() => signingBytes(payload(signedAtMs: -1)), throwsArgumentError);
    });
    test('an empty-string replyTo is rejected (absent != present-empty)', () {
      expect(() => signingBytes(payload(replyTo: '')), throwsArgumentError);
    });
    test('a null replyTo is allowed', () {
      expect(signingBytes(payload(replyTo: null)), isNotNull);
    });
  });
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
