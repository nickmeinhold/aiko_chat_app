// The positive control for the live playtest goals.
//
// When the model fails to silence a channel, that reading has two possible
// causes and they mean opposite things: the app is hard to discover, or the
// HARNESS cannot perform the gesture at all. Without separating them, every
// failed goal is unattributable and the instrument reports nothing.
//
// So this file drives the same goal through the same harness with the answer
// supplied — a scripted hold on the app-bar title, the path
// `docs/design/user-paths.html` records for "33 · silence this conversation".
// It uses a finder ONLY to locate the target, then presses POSITIONALLY through
// the same code path the blind agent uses. If this is green and the live run is
// red, the difference is knowledge, which is exactly the thing being measured.
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

  testWidgets('the mute IS reachable by holding the app-bar title, unaided', (
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
          return Hold(title, because: 'the documented path');
        }
        // The menu is open; the mute item is the only thing in it, drawn just
        // below the press point. Found by looking, not by name.
        final item = tester.getCenter(find.byType(PopupMenuItem<bool>).first);
        return Tap(item, because: 'the one item in the menu');
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
      reason: 'the designed path is two presses: hold the title, press mute',
    );
  });
}
