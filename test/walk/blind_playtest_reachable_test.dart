// The positive control for the live playtest goals.
//
// When the model fails to silence a channel, that reading has two possible
// causes and they mean opposite things: the app is hard to discover, or the
// HARNESS cannot perform the gesture at all. Without separating them, every
// failed goal is unattributable and the instrument reports nothing.
//
// So this file drives the same goal through the same harness with the answer
// supplied — the path `docs/design/user-paths.html` records for
// "33 · silence this conversation". It uses a finder ONLY to locate the target,
// then presses POSITIONALLY through the same code path the blind agent uses. If
// this is green and the live run is red, the difference is knowledge, which is
// exactly the thing being measured.
//
// The documented path CHANGED with task #26, and this file is where that shows
// up as a number rather than an opinion. It used to be a hold on the app-bar
// title, because the title was the conversation switcher and mute had nowhere
// else to live on a phone; the blind sweep scored that path NOT REACHED in six
// presses. It is now: tap the title, which means THIS CONVERSATION, and press
// the mute switch on its details. Two taps, no hold, no invisible gesture.
//
// This is deliberately NOT a mechanical substitution of the old assertions. The
// old test proved a long-press this design removes; a sed that made it green
// would have tested nothing.
//
// No model, so it runs free and every time.
import 'package:aiko_chat_app/features/chat/application/mute_controller.dart';
import 'package:aiko_chat_app/features/chat/data/mute_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/blind_playtest.dart';
import '../support/fonts.dart';
import '../support/test_helpers.dart';
import '../support/walk_harness.dart';

void main() {
  setUpAll(() async {
    await initializeTestEnvironment();
    await loadRealFonts();
  });

  testWidgets('the mute IS reachable by tapping the app-bar title, unaided', (
    tester,
  ) async {
    hideDebugChrome();
    final container = (await pumpWalkableApp(tester, walkPhone)).container;

    // The one place a finder is allowed: establishing WHERE the documented
    // affordance is, so the press itself can be positional and go through the
    // identical harness path the blind agent's moves take.
    final title = tester.getCenter(find.text('general').first);

    var opened = false;
    final run = await playtest(
      tester,
      goal: 'silence the conversation called "general"',
      agent: (view) async {
        if (!opened) {
          opened = true;
          return Tap(title, because: 'the documented path');
        }
        // Conversation details is open; the mute control is the switch on it.
        // Found by looking, not by name.
        final mute = tester.getCenter(find.byType(SwitchListTile).first);
        return Tap(mute, because: 'the notification switch on the details');
      },
      reached: () async => container
          .read(mutesProvider.notifier)
          .isMuted(MuteTarget.channel, 'c1'),
      maxPresses: 4,
    );

    expect(
      run.reached,
      isTrue,
      reason:
          'the harness cannot reach the mute even when told exactly where it '
          'is — so a failed live run says nothing about discoverability, only '
          'about this file: $run',
    );
    expect(
      run.presses,
      2,
      reason:
          'the designed path is two presses: tap the title, press the mute '
          'switch. This number IS the acceptance test for task #26 — the blind '
          'sweep scored the old path NOT REACHED in six',
    );
  });
}
