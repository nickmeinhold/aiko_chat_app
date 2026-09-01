@Tags(['deep'])
library;

// Can a user actually GET to every screen this app registers?
//
// The denominator is the router's OWN table, read live from `routerProvider` —
// never a list maintained by hand beside it. That is the whole point. A
// hand-kept inventory of "user paths" is an authoritative fact living outside
// the running system: every new feature is supposed to update it, and the one
// time someone forgets is exactly the feature nobody tested. Here, adding a
// GoRoute puts it in the denominator whether anyone remembers or not, and if no
// walk can reach it this test goes red.
//
// The bug class it exists for is this repo's own recurring one: a route that is
// registered, built, correct, and unreachable. Before #2798 the entire Direct
// Messages section could only be reached by placing a video call — a feature
// present in the code and absent from the product. That shape is now mechanical
// to detect rather than waiting for someone to notice.
//
// A red result means one of three things, and they want different fixes:
//   1. genuinely unreachable -> a product bug, fix the app
//   2. reachable, but the walker cannot get there (needs typing, a scroll, a
//      server state the fakes never produce) -> fix the harness
//   3. reachable only under a condition that should not be walked (an operator
//      seat, a ban) -> add it below, WITH the reason
import 'package:aiko_chat_app/app/router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/app_walker.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

/// Routes a walk is not expected to reach, each with the reason it is exempt.
///
/// This is the artifact a human should actually read, and it is short by design
/// — unlike a list of every path in the app, which nobody reviews. Most entries
/// are HARNESS TO-DOs: states the fakes cannot yet produce, not permanent
/// exemptions. An entry that stops being a to-do and becomes furniture is the
/// thing to be suspicious of.
///
/// `/call/:channelId` is deliberately NOT here. While calling is gated off the
/// route is not registered at all, so it is not in the denominator and needs no
/// exemption — `call_gating_test.dart` owns that assertion. Turn calling back
/// on and the route rejoins the table, where the walker must reach it like any
/// other screen. An exemption would have been a special case that quietly
/// survived the flag being flipped; absence handles both states by itself.
const _expectedUnreachable = <String, String>{
  '/login':
      'The walk starts SIGNED IN, and sign-out is on the walker avoid list '
      'because it truncates every walk that finds it. Reaching login again is '
      'the "recover" verb and deserves a walk that starts there. HARNESS TO-DO.',
  '/splash':
      'Transient. The redirect passes through it during startup and it is never '
      'a destination, so no control leads to it.',
  '/eula':
      'The fakes start pre-accepted (FakeEulaStore(accepted: true)) so every '
      'other test can reach chat. Its own gate suite covers it. HARNESS TO-DO.',
  '/settings/eula':
      'Settings row 210, below Sign out and Report a problem, so it is off the '
      'bottom of a phone viewport. THE WALKER CANNOT SCROLL, so anything below '
      'the fold is invisible to it — an instrument limit, not a product gap: '
      'the Terms are one tap away for a real user. Teaching the walker to '
      'scroll retires this entry. HARNESS TO-DO.',
  '/claim-handle':
      'Only on first-passkey-creates-account. The walk signs IN to an existing '
      'account, so this branch is never taken. HARNESS TO-DO.',
  '/moderation/reports':
      'Operator seat — the tile renders only for a moderator, and the real '
      'boundary is the server ModeratorUser check. Needs a moderator fixture. '
      'HARNESS TO-DO.',
  '/suspended':
      'Requires a ban from the island; the fakes never produce one. Covered by '
      'the ban-arc suite. HARNESS TO-DO.',
};

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  testWidgets('every registered route is reachable by walking, or is '
      'explicitly exempt with a reason', (tester) async {
    final reached = <String>{};
    var registered = <String>{};

    // BOTH layouts, because reachability is layout-dependent and that is worth
    // asserting. `/settings/gateway` is reached through the WIDE sidebar's
    // server switcher (channel_sidebar.dart); walking only the phone viewport
    // reported it unreachable, which would have pushed a perfectly reachable
    // screen into the exemption list and taught the next reader it was a known
    // gap. A screen you can only reach on one form factor is a finding.
    for (final size in [walkPhone, walkDesktop]) {
      final container = await pumpWalkableApp(tester, size);
      final router = container.read(routerProvider);

      // The denominator, straight from the app. The route TABLE does not vary
      // by layout — only what leads into it does.
      registered = {
        for (final r in router.configuration.routes)
          if (r is GoRoute) r.path,
      };

      // Sampled harder than the ordinary walks: this asks what is reachable AT
      // ALL, and under-sampling would read as "unreachable".
      for (var seed = 1; seed <= 12; seed++) {
        final trail = await walkApp(
          tester,
          seed: seed,
          steps: 60,
          locationOf: () => router.state.fullPath,
        );
        reached.addAll(trail.routes);
      }
    }

    final unreached = registered.difference(reached)
      ..removeAll(_expectedUnreachable.keys);

    expect(
      unreached,
      isEmpty,
      reason:
          'These routes are REGISTERED but no walk could reach them:\n'
          '${unreached.map((r) => '  $r').join('\n')}\n\n'
          'A registered route nothing leads to is either dead code or a feature '
          'users cannot find. Fix the app, fix the harness, or add it to '
          '_expectedUnreachable WITH the reason.\n\n'
          'Reached: ${(reached.toList()..sort()).join(', ')}',
    );

    // The exemption list must not rot into a graveyard. If a route stops being
    // registered its exemption is stale and should go with it, or the list
    // slowly fills with excuses for screens that no longer exist and stops
    // being something anyone will read.
    final stale = _expectedUnreachable.keys.toSet()..removeAll(registered);
    expect(
      stale,
      isEmpty,
      reason:
          'Exempted but no longer registered — delete the exemption: '
          '${stale.join(', ')}',
    );
  });
}
