import 'dart:convert';
import 'dart:typed_data';

import 'package:aiko_chat_app/features/chat/domain/message_signing.dart';
import 'package:aiko_chat_app/features/chat/domain/origin_envelope.dart';
import 'package:aiko_chat_app/services/sovereign_key_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_helpers.dart';

// The spec golden-vector fixture (SIGNING-SPEC.md), reused so the wire envelope
// is pinned to the SAME inputs as signingBytes.
final Uint8List _goldenPub = Uint8List.fromList(List.generate(32, (i) => i)); // 00..1f
const String _goldenCmid = 'tmp-abc';
const int _goldenTs = 1720000000000;

SignedPayload _fixture(Uint8List pub) => SignedPayload(
      rawPublicKey: pub,
      channelId: 'chan-1',
      clientMsgId: _goldenCmid,
      signedAtMs: _goldenTs,
      body: 'hello world',
      replyTo: null,
    );

/// A valid wire origin for the golden fixture, mutable per-test to build RED cases.
Map<String, dynamic> _validWire() => OriginEnvelope(
      keyVersion: 1,
      rawPublicKey: _goldenPub,
      clientMsgId: _goldenCmid,
      signedAtMs: _goldenTs,
      sig: Uint8List(64), // shape-valid; the sig isn't checked by validateOrigin
    ).toWire();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Multikey codec (mirrors the gateway decode_multikey)', () {
    test('round-trips: decode(encode(raw)) == raw', () {
      final mk = encodeMultikey(_goldenPub);
      expect(decodeMultikey(mk), _goldenPub);
    });

    // W3C did:key invariant: an ed25519 Multikey (0xed01 ‖ 32 bytes) always
    // base58btc-encodes to a `z6Mk…` prefix. This is the cross-implementation
    // anchor — the gateway produces the identical prefix.
    test('an ed25519 Multikey has the canonical z6Mk prefix', () {
      expect(encodeMultikey(_goldenPub).startsWith('z6Mk'), isTrue);
    });

    // EXTERNAL known-answer (not a mirror): this exact string was produced by the
    // gateway's base58btc alphabet for the fixture pubkey 00..1f AND verified to
    // round-trip through the gateway's own decode_multikey (aiko-chat-island
    // domain/signing.py). A change here means the app has drifted from the gateway
    // encoder — the interop contract is broken. (cage-match Tesla: no mirror tests.)
    test('golden: the canonical Multikey matches the gateway byte-for-byte', () {
      expect(encodeMultikey(_goldenPub),
          'z6MkeTGwHmLmuCmgg4ABYhzWVh6ZX7hTwWt8gguAretUfc9c');
    });

    test('a non-32-byte key is rejected at encode', () {
      expect(() => encodeMultikey(Uint8List(31)), throwsA(isA<OriginError>()));
    });

    test('a non-z multibase is rejected at decode', () {
      expect(() => decodeMultikey('f6Mk...'), throwsA(isA<OriginError>()));
    });
  });

  group('base64url-unpadded sig codec', () {
    test('emits no padding and round-trips through the strict decoder', () {
      final raw = Uint8List.fromList(List.generate(64, (i) => (i * 7) & 0xff));
      final s = base64UrlUnpadded(raw);
      expect(s.contains('='), isFalse);
      // Re-admit through a full envelope to exercise the strict _b64urlRaw path.
      final env = OriginEnvelope(
          keyVersion: 1,
          rawPublicKey: _goldenPub,
          clientMsgId: _goldenCmid,
          signedAtMs: _goldenTs,
          sig: raw);
      final back = validateOrigin(env.toWire(), frameClientMsgId: _goldenCmid);
      expect(back!.sig, raw);
    });
  });

  group('toWire (the frozen 7-key envelope)', () {
    test('emits EXACTLY the seven required keys, no more', () {
      final w = _validWire();
      expect(
        w.keys.toSet(),
        {'v', 'alg', 'key_version', 'sender_pubkey', 'client_msg_id', 'signed_at_ms', 'sig'},
      );
      expect(w['v'], 1);
      expect(w['alg'], 'EdDSA');
    });
  });

  group('validateOrigin — the single admission gate', () {
    test('absent origin (null) returns null, never throws (unsigned is legal)', () {
      expect(validateOrigin(null, frameClientMsgId: _goldenCmid), isNull);
    });

    test('a well-formed envelope admits and decodes the material', () {
      final env = validateOrigin(_validWire(), frameClientMsgId: _goldenCmid)!;
      expect(env.rawPublicKey, _goldenPub);
      expect(env.clientMsgId, _goldenCmid);
      expect(env.signedAtMs, _goldenTs);
      expect(env.sig.length, 64);
      expect(env.keyVersion, 1);
    });

    // THE interop test: carriage is verifier-sufficient. A real signature
    // re-verifies from ONLY the round-tripped wire envelope + the message's own
    // content fields — exactly what a recipient reconstructs. Mirrors the
    // gateway's golden-vector-interop test.
    test('carriage is verifier-sufficient end-to-end', () async {
      installSecureStorageMock();
      final key = await SovereignKeyStore().loadOrCreate();
      final payload = _fixture(key.rawPublicKey);
      final signature = await sign(key, payload);

      // Build → wire → JSON round-trip (proves a real transport hop) → admit.
      final wire = OriginEnvelope.fromSignature(signature, clientMsgId: payload.clientMsgId).toWire();
      final rehydrated = jsonDecode(jsonEncode(wire)) as Map<String, dynamic>;
      final admitted = validateOrigin(rehydrated, frameClientMsgId: payload.clientMsgId)!;

      // Reconstruct signingBytes from the ADMITTED envelope (signature material)
      // + the message's own content fields (channel/body/replyTo), then verify.
      final reconstructed = SignedPayload(
        rawPublicKey: admitted.rawPublicKey,
        channelId: payload.channelId, // from the message, not the envelope
        clientMsgId: admitted.clientMsgId,
        signedAtMs: admitted.signedAtMs,
        body: payload.body,
        replyTo: payload.replyTo,
      );
      expect(await verifySignature(admitted.rawPublicKey, admitted.sig, reconstructed), isTrue);
    });

    group('RED — fail-closed rejections', () {
      void expectReject(Map<String, dynamic> Function() mutate) {
        expect(() => validateOrigin(mutate(), frameClientMsgId: _goldenCmid),
            throwsA(isA<OriginError>()));
      }

      test('not a JSON object', () {
        expect(() => validateOrigin('nope', frameClientMsgId: _goldenCmid),
            throwsA(isA<OriginError>()));
      });
      test('a missing key', () => expectReject(() => _validWire()..remove('sig')));
      test('an extra key', () => expectReject(() => _validWire()..['extra'] = 1));
      test('a wrong alg (alg-confusion)', () => expectReject(() => _validWire()..['alg'] = 'RS256'));
      test('an unsupported version', () => expectReject(() => _validWire()..['v'] = 2));
      test('v as a bool (JSON true must not satisfy == 1)',
          () => expectReject(() => _validWire()..['v'] = true));
      test('key_version < 1', () => expectReject(() => _validWire()..['key_version'] = 0));
      test('sender_pubkey not a Multikey',
          () => expectReject(() => _validWire()..['sender_pubkey'] = 'not-a-multikey'));
      test('sender_pubkey oversized', () {
        expectReject(() => _validWire()..['sender_pubkey'] = 'z${'1' * 200}');
      });
      test('sig padded / non-canonical base64url',
          () => expectReject(() => _validWire()..['sig'] = '${'A' * 86}=='));
      test('sig decodes to the wrong length', () {
        expectReject(() => _validWire()..['sig'] = base64UrlUnpadded(Uint8List(32)));
      });
      test('signed_at_ms negative', () => expectReject(() => _validWire()..['signed_at_ms'] = -1));
      test('client_msg_id mismatch with the frame (envelope-vs-payload confusion)', () {
        expect(
          () => validateOrigin(_validWire(), frameClientMsgId: 'a-different-id'),
          throwsA(isA<OriginError>()),
        );
      });
      test('client_msg_id oversized', () {
        expect(
          () => validateOrigin(_validWire()..['client_msg_id'] = 'x' * 65,
              frameClientMsgId: 'x' * 65),
          throwsA(isA<OriginError>()),
        );
      });
    });
  });
}
