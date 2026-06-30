// Unit tests for GatewayConfig — the gateway value object (#4).
//
// The normalizer is the single canonical-form owner that both the persisted and
// the dart-define paths funnel through; the no-op switch guard and the
// "already connected" UI both lean on `https://x/` and `https://x` resolving
// equal, so that's pinned here.

import 'package:aiko_chat_app/app/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GatewayConfig.normalized', () {
    test('strips a trailing slash and trims surrounding whitespace', () {
      expect(GatewayConfig.normalized('  https://x.io/  ').httpBaseUrl,
          'https://x.io');
      expect(GatewayConfig.normalized('https://x.io').httpBaseUrl, 'https://x.io');
    });

    test('a trailing-slash and a bare URL are the SAME gateway (==)', () {
      expect(GatewayConfig.normalized('https://chat.imagineering.cc/'),
          GatewayConfig.normalized('https://chat.imagineering.cc'));
    });

    test('strips MULTIPLE trailing slashes (no needless-logout slip)', () {
      // A single-slash strip would let `https://x//` slip the no-op guard and
      // destroy a live session (Carnot F5).
      expect(GatewayConfig.normalized('https://x//').httpBaseUrl, 'https://x');
      expect(GatewayConfig.normalized('https://x///'),
          GatewayConfig.normalized('https://x'));
    });
  });

  group('GatewayConfig.fromEnvironment', () {
    test('defaults to the live production gateway with no --dart-define', () {
      // The test runner passes no GATEWAY_BASE_URL, so this exercises the
      // hardcoded last-resort default (the #4 "default to prod" requirement).
      expect(GatewayConfig.fromEnvironment().httpBaseUrl,
          kDefaultGatewayBaseUrl);
      expect(kDefaultGatewayBaseUrl, 'https://chat.imagineering.cc');
    });
  });

  group('wsBaseUrl derivation', () {
    test('https→wss, http→ws — derived so it can never drift from the host', () {
      expect(
          const GatewayConfig(httpBaseUrl: 'https://chat.imagineering.cc')
              .wsBaseUrl,
          'wss://chat.imagineering.cc');
      expect(const GatewayConfig(httpBaseUrl: 'http://localhost:8095').wsBaseUrl,
          'ws://localhost:8095');
    });
  });
}
