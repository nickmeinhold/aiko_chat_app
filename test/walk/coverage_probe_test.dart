@Tags(['deep'])
library;

// What the walker can SEE — the coverage boundary, asserted rather than assumed.
//
// A sweep that finds no bugs proves only that the slice it walked is clean, so
// the size of that slice has to be a fact in the suite rather than something
// measured once and remembered wrongly. If navigation breaks such that the
// walker can only reach the first screen, every walk still passes — and only
// this file goes red.
//
// The floor is deliberately below the current number: this is a regression
// tripwire, not a target to game.
//
// KNOWN BLIND SPOTS (each is a real feature the walker cannot currently reach):
//   - DMs — the fakes seed no DM channels, so the whole navigable-DM surface
//     (#2798) is invisible here.
//   - Mute / Report / Block / Message — reachable only by LONG-PRESS, and the
//     walker only taps.
//   - Search, the palette editor's interior, the typeface list.
// Closing those is the next increment; until then this file is what stops the
// gap being mistaken for coverage.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_walker.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
  });

  final seen = <String>{};

  for (var seed = 300; seed < 320; seed++) {
    testWidgets('coverage seed=$seed', (tester) async {
      await pumpWalkableApp(tester, seed.isEven ? walkPhone : walkDesktop);
      final t = await walkApp(tester, seed: seed, steps: 60);
      seen.addAll(t.steps);
    });
  }

  tearDownAll(() {
    final sorted = seen.toList()..sort();
    debugPrint('=== WALKER REACHED ${sorted.length} DISTINCT CONTROLS ===');
    for (final s in sorted) {
      debugPrint('  $s');
    }
    // Measured at 37 on 2026-09-01. A drop means the walker stopped being able
    // to reach parts of the app — which is either a navigation regression or a
    // widget type it no longer recognises, and both are worth a look.
    expect(
      sorted.length,
      greaterThanOrEqualTo(30),
      reason:
          'Walker coverage COLLAPSED to ${sorted.length} controls (was 37). '
          'Either navigation regressed or the predicate stopped matching '
          'something.\nReached:\n${sorted.join('\n')}',
    );
  });
}
