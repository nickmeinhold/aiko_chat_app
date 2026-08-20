import 'package:aiko_chat_app/features/chat/data/carriage_capability.dart';
import 'package:aiko_chat_app/features/chat/domain/gateway_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GatewayCapabilities.parse (three-state, #1896)', () {
    test('explicit carriage.origin == true → carriesOrigin true', () {
      final c = GatewayCapabilities.parse({
        'carriage': {'origin': true},
      });
      expect(c?.carriesOrigin, isTrue);
    });

    test('explicit carriage.origin == false → carriesOrigin false '
        '(endpoint authoritative)', () {
      final c = GatewayCapabilities.parse({
        'carriage': {'origin': false},
      });
      expect(c?.carriesOrigin, isFalse);
    });

    // THE BUG FIX (cage-match Tesla + Carnot): a partial/stub 200 must decode to
    // UNKNOWN (null), NOT an authoritative false — else it flips an allowlisted
    // host off during the /capabilities rollout. null → resolver keeps the seed.
    test(
      'missing carriage/origin → null (unknown, NOT authoritative false)',
      () {
        expect(GatewayCapabilities.parse({}), isNull);
        expect(GatewayCapabilities.parse({'carriage': {}}), isNull);
        expect(
          GatewayCapabilities.parse({
            'carriage': {'other': true},
          }),
          isNull,
        );
      },
    );

    test('non-bool origin → null (never enables AND never authoritatively '
        'disables on garbage)', () {
      // A String "true", a 1, or a null are all "unknown" — they can neither
      // turn the gate on nor flip a known host off.
      for (final bad in [
        <String, dynamic>{
          'carriage': {'origin': 'true'},
        },
        <String, dynamic>{
          'carriage': {'origin': 1},
        },
        <String, dynamic>{
          'carriage': {'origin': null},
        },
        <String, dynamic>{'carriage': 'origin'},
      ]) {
        expect(
          GatewayCapabilities.parse(bad),
          isNull,
          reason: 'non-bool origin is unknown, not authoritative: $bad',
        );
      }
    });
  });

  group('CarriageCapability resolution (#1896)', () {
    test('allowlisted host seeds carriesOrigin=true before any fetch', () {
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => null,
      );
      expect(c.carriesOrigin, isTrue);
    });

    test(
      'non-allowlisted host seeds carriesOrigin=false (fail-closed stranger)',
      () {
        final c = CarriageCapability(
          host: 'new-island.example',
          fetch: () async => null,
        );
        expect(c.carriesOrigin, isFalse);
      },
    );

    test('allowlisted host is matched case-insensitively and past a trailing '
        'FQDN dot (cage-match Tesla — no silent downgrade)', () {
      for (final variant in [
        'CHAT.IMAGINEERING.CC',
        'Chat.Imagineering.CC',
        'chat.imagineering.cc.',
      ]) {
        final c = CarriageCapability(host: variant, fetch: () async => null);
        expect(
          c.carriesOrigin,
          isTrue,
          reason: 'normalized variant must match the allowlist: $variant',
        );
      }
    });

    test('a partial/stub 200 (parse → null) keeps the allowlisted seed ON '
        '(the no-regression bug fix)', () async {
      // Simulates the island deploying a stub /capabilities that 200s with a
      // missing carriage.origin: GatewayCapabilities.parse returns null, so the
      // resolver must NOT flip the known host off.
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => null, // parse-of-stub-200 → null, same as a 404
      );
      await c.refresh();
      expect(c.carriesOrigin, isTrue);
    });

    test('NO-REGRESSION: allowlisted host whose /capabilities 404s (null) '
        'KEEPS origin on after refresh', () async {
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => null, // 404 today
      );
      await c.refresh();
      expect(
        c.carriesOrigin,
        isTrue,
        reason: 'a 404 must never flip the live carriage host OFF',
      );
    });

    test('a fetch THROWING resolves to the allowlist seed', () async {
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => throw Exception('network down'),
      );
      await c.refresh();
      expect(c.carriesOrigin, isTrue, reason: 'unknown → seed (allowlisted)');
    });

    // Option B (cage-match Tesla + Carnot): the allowlist is a LIVE fallback,
    // not a one-shot seed. A transient explicit false must NOT stick forever.
    test('allowlisted host: explicit false then null RE-SEEDS to ON '
        '(no sticky sovereignty-off)', () async {
      final answers = <GatewayCapabilities?>[
        const GatewayCapabilities(carriesOrigin: false), // canary/misdeploy
        null, // endpoint reverts to 404/stub → unknown
      ];
      var i = 0;
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => answers[i++],
      );
      await c.refresh();
      expect(
        c.carriesOrigin,
        isFalse,
        reason: 'explicit false is authoritative',
      );
      await c.refresh();
      expect(
        c.carriesOrigin,
        isTrue,
        reason: 'unknown after a transient false re-seeds to the allowlist',
      );
    });

    test('stranger: explicit true then null RE-SEEDS to OFF '
        '(no sticky emit an island would bad_origin-drop)', () async {
      final answers = <GatewayCapabilities?>[
        const GatewayCapabilities(carriesOrigin: true),
        null,
      ];
      var i = 0;
      final c = CarriageCapability(
        host: 'new-island.example',
        fetch: () async => answers[i++],
      );
      await c.refresh();
      expect(c.carriesOrigin, isTrue, reason: 'stranger proved carriage');
      await c.refresh();
      expect(
        c.carriesOrigin,
        isFalse,
        reason: 'endpoint went dark → re-seed to stranger seed (false)',
      );
    });

    test('stranger: proved true then a THROWING fetch resolves to seed=false '
        '(deliberate fail-closed, cage-match Carnot)', () async {
      var throwNow = false;
      final c = CarriageCapability(
        host: 'new-island.example',
        fetch: () async {
          if (throwNow) throw Exception('boom');
          return const GatewayCapabilities(carriesOrigin: true);
        },
      );
      await c.refresh();
      expect(c.carriesOrigin, isTrue);
      throwNow = true;
      await c.refresh();
      expect(
        c.carriesOrigin,
        isFalse,
        reason:
            'unknown (throw) → seed; a dropped bad_origin message is '
            'worse than an unsigned one',
      );
    });

    test(
      'injected allowlist entries are normalized too (cage-match Carnot)',
      () {
        final c = CarriageCapability(
          host: 'chat.imagineering.cc',
          knownCarriageHosts: const {'CHAT.IMAGINEERING.CC'},
          fetch: () async => null,
        );
        expect(
          c.carriesOrigin,
          isTrue,
          reason: 'a mixed-case allowlist entry must still match',
        );
      },
    );

    test('stranger island that PROVES carriage flips on', () async {
      final c = CarriageCapability(
        host: 'new-island.example',
        fetch: () async => const GatewayCapabilities(carriesOrigin: true),
      );
      expect(c.carriesOrigin, isFalse, reason: 'unproven until fetched');
      await c.refresh();
      expect(c.carriesOrigin, isTrue, reason: 'endpoint is authoritative');
    });

    test('endpoint is authoritative: allowlisted host that advertises '
        'origin=false is turned OFF', () async {
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => const GatewayCapabilities(carriesOrigin: false),
      );
      expect(c.carriesOrigin, isTrue, reason: 'allowlist seed');
      await c.refresh();
      expect(
        c.carriesOrigin,
        isFalse,
        reason: 'a live negative answer overrides the transitional allowlist',
      );
    });
  });
}
