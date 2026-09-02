// Unit tests for IslandConfig — the gateway value object (#4).
//
// The normalizer is the single canonical-form owner that both the persisted and
// the dart-define paths funnel through; the no-op switch guard and the
// "already connected" UI both lean on `https://x/` and `https://x` resolving
// equal, so that's pinned here.

import 'package:aiko_chat_app/app/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IslandConfig.normalized', () {
    test('strips a trailing slash and trims surrounding whitespace', () {
      expect(
        IslandConfig.normalized('  https://x.io/  ').httpBaseUrl,
        'https://x.io',
      );
      expect(
        IslandConfig.normalized('https://x.io').httpBaseUrl,
        'https://x.io',
      );
    });

    test('a trailing-slash and a bare URL are the SAME gateway (==)', () {
      expect(
        IslandConfig.normalized('https://chat.imagineering.cc/'),
        IslandConfig.normalized('https://chat.imagineering.cc'),
      );
    });

    test('strips MULTIPLE trailing slashes (no needless-logout slip)', () {
      // A single-slash strip would let `https://x//` slip the no-op guard and
      // destroy a live session (Carnot F5).
      expect(IslandConfig.normalized('https://x//').httpBaseUrl, 'https://x');
      expect(
        IslandConfig.normalized('https://x///'),
        IslandConfig.normalized('https://x'),
      );
    });
  });

  group('IslandConfig.fromEnvironment', () {
    test('defaults to the live production gateway with no --dart-define', () {
      // The test runner passes no GATEWAY_BASE_URL, so this exercises the
      // hardcoded last-resort default (the #4 "default to prod" requirement).
      expect(IslandConfig.fromEnvironment().httpBaseUrl, kDefaultIslandBaseUrl);
      expect(kDefaultIslandBaseUrl, 'https://chat.imagineering.cc');
    });
  });

  group('wsBaseUrl derivation', () {
    test(
      'https→wss, http→ws — derived so it can never drift from the host',
      () {
        expect(
          const IslandConfig(
            httpBaseUrl: 'https://chat.imagineering.cc',
          ).wsBaseUrl,
          'wss://chat.imagineering.cc',
        );
        expect(
          const IslandConfig(httpBaseUrl: 'http://localhost:8095').wsBaseUrl,
          'ws://localhost:8095',
        );
      },
    );
  });
}
