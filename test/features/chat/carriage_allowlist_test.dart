// The carriage allowlist and the island list MUST NOT DRIFT — the test that
// would have caught a seven-week outage.
//
// `kKnownCarriageHosts` decides whether this client emits the sovereign `origin`
// envelope while `GET /capabilities` is undeployed. An island missing from it
// re-resolves to a `false` seed and `GatewayTransport` withholds the envelope —
// so every message to that island goes UNSIGNED, silently, with no error at
// either end.
//
// That is not a cosmetic loss. `admitRing` refuses an unsigned invitation as
// `unverifiedOrigin`, its head refusal, so **no call to that island can be
// answered by anyone**. Measured on the live island 2026-09-16: `chat.enspyr.co`
// had never been on the list, the gate reached handsets around 2026-08-10, and
// `nick`'s last signed message is dated 2026-08-10 with nothing since. Seven
// weeks, both platforms, one WARNING line in the recipient's ring buffer as the
// only evidence.
//
// The missing entry was the symptom. **A hand-curated list of production hosts,
// with nothing checking it against the hosts the app actually ships, was the
// defect** — so this test derives the requirement from `kIslandPresets` instead
// of restating it. Add an island to the picker without adding carriage for it
// and this goes red at once, which is the whole point.
//
// DELETE THIS FILE when `/capabilities` is live on every island and
// `kKnownCarriageHosts` is deleted with it (task #1896). Until then the list is
// a deploy-time promise that nothing else verifies.
import 'package:aiko_chat_app/features/chat/data/carriage_capability.dart';
import 'package:aiko_chat_app/features/chat/domain/gateway_capabilities.dart';
import 'package:aiko_chat_app/features/settings/domain/island_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The hosts this build actually offers users, minus the dev-only ones.
  ///
  /// Localhost and the emulator alias are excluded deliberately: they are a
  /// developer's own island of unknown vintage, and the honest default for an
  /// unknown host is the fail-closed seed the gate already applies.
  Iterable<String> shippedIslandHosts() => kIslandPresets
      .map((e) => Uri.parse(e.httpBaseUrl).host)
      .where((h) => h != 'localhost' && h != '10.0.2.2');

  test('the harness can see both lists — positive control', () {
    // Without this, a renamed constant or an empty preset list would make the
    // assertion below pass vacuously and report "no drift" forever.
    expect(
      shippedIslandHosts(),
      isNotEmpty,
      reason: 'kIslandPresets yielded no shippable hosts — this test is blind',
    );
    expect(
      kKnownCarriageHosts,
      isNotEmpty,
      reason: 'the carriage allowlist is empty — this test is blind',
    );
  });

  test('every island this build ships carries the origin envelope', () {
    final missing = shippedIslandHosts()
        .where((h) => !kKnownCarriageHosts.contains(h))
        .toList();
    expect(
      missing,
      isEmpty,
      reason:
          'These islands are offered in the picker but are not on the carriage '
          'allowlist, so this client will send every message to them UNSIGNED '
          'and no call to them can be answered: $missing. Either add them to '
          'kKnownCarriageHosts, or deploy GET /capabilities there and delete '
          'the allowlist (task #1896).',
    );
  });

  group('the gate that makes the omission fatal', () {
    Future<GatewayCapabilities?> unknown() async => null;

    test('a shipped island seeds ON even when /capabilities 404s', () {
      // The live configuration: both islands 404 that endpoint today, so the
      // seed is the only thing standing between a call and silence.
      for (final host in shippedIslandHosts()) {
        expect(
          CarriageCapability(host: host, fetch: unknown).carriesOrigin,
          isTrue,
          reason: '$host would send unsigned and be unanswerable',
        );
      }
    });

    test('an unknown host still seeds OFF — the fail-closed half stands', () {
      // The behaviour the allowlist exists for is unchanged by this fix: a
      // stranger whose carriage is unproven gets no envelope, because an island
      // that rejects one drops the whole message.
      expect(
        CarriageCapability(
          host: 'chat.someone-elses-island.example',
          fetch: unknown,
        ).carriesOrigin,
        isFalse,
      );
    });
  });
}
