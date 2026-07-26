import 'package:aiko_chat_app/features/chat/data/carriage_capability.dart';
import 'package:aiko_chat_app/features/chat/domain/gateway_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GatewayCapabilities.fromJson (fail-closed decode, #1896)', () {
    test('carriage.origin == true → carriesOrigin true', () {
      final c = GatewayCapabilities.fromJson({
        'carriage': {'origin': true}
      });
      expect(c.carriesOrigin, isTrue);
    });

    test('carriage.origin == false → carriesOrigin false', () {
      final c = GatewayCapabilities.fromJson({
        'carriage': {'origin': false}
      });
      expect(c.carriesOrigin, isFalse);
    });

    test('missing carriage → false (absent capability is not enabled)', () {
      expect(GatewayCapabilities.fromJson({}).carriesOrigin, isFalse);
      expect(
        GatewayCapabilities.fromJson({'carriage': {}}).carriesOrigin,
        isFalse,
      );
    });

    test('malformed / non-bool origin decodes to false (never enables emit)',
        () {
      // A String "true", a 1, or a null must NOT turn the capability on.
      for (final bad in [<String, dynamic>{'carriage': {'origin': 'true'}},
        <String, dynamic>{'carriage': {'origin': 1}},
        <String, dynamic>{'carriage': {'origin': null}},
        <String, dynamic>{'carriage': 'origin'}]) {
        expect(GatewayCapabilities.fromJson(bad).carriesOrigin, isFalse,
            reason: 'hostile/partial doc can only withhold, not enable: $bad');
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

    test('non-allowlisted host seeds carriesOrigin=false (fail-closed stranger)',
        () {
      final c = CarriageCapability(
        host: 'new-island.example',
        fetch: () async => null,
      );
      expect(c.carriesOrigin, isFalse);
    });

    test('NO-REGRESSION: allowlisted host whose /capabilities 404s (null) '
        'KEEPS origin on after refresh', () async {
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => null, // 404 today
      );
      await c.refresh();
      expect(c.carriesOrigin, isTrue,
          reason: 'a 404 must never flip the live carriage host OFF');
    });

    test('a fetch THROWING keeps the prior (seeded) value', () async {
      final c = CarriageCapability(
        host: 'chat.imagineering.cc',
        fetch: () async => throw Exception('network down'),
      );
      await c.refresh();
      expect(c.carriesOrigin, isTrue);
    });

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
      expect(c.carriesOrigin, isFalse,
          reason: 'a live negative answer overrides the transitional allowlist');
    });
  });
}
