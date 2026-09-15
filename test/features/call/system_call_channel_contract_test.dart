// The system-call channel's NAMES, asserted across the language boundary.
//
// `system_call_navigator_test.dart` proves the Dart half does the right thing
// with an action. It cannot prove the action ever arrives, because it hands the
// navigator a `_FakeBridge` — a verifier that shares a representation with the
// thing it verifies is blind to a bug in that shared layer, and every name here
// lives in the ONE layer the fake replaces.
//
// The failure this exists for is the one this repo has already shipped once, in
// the `apns_environment` rename: a blanket rename moved the Dart side and left
// `AppDelegate.swift` answering the old name. Here the consequences are
//
//   a renamed event channel  -> `receiveBroadcastStream` on a name nothing feeds
//                            -> the user answers and the app never hears about it
//   a renamed method         -> MissingPluginException, deliberately swallowed
//                            -> a phantom "connected" call in the system UI
//   a renamed payload key    -> every event decodes to null and is dropped
//   a renamed action value   -> same, one layer in
//
// Every one of them is SILENT, and every one of them is invisible to a Dart
// suite that never crosses into Swift.
//
// COARSE BY CONSTRUCTION: this greps Swift, it does not execute it. The honest
// scope is that both sides NAME the same things. Naming is what drifts.
import 'dart:io';

import 'package:aiko_chat_app/features/call/data/system_call_bridge.dart';
import 'package:aiko_chat_app/features/call/domain/system_call_action.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();

  /// The `SystemCallChannel` class body, so an assertion about "the Swift side"
  /// cannot be satisfied by an identically-named thing in one of the other four
  /// channels this file carries.
  String systemCallChannelSource() {
    const start = 'final class SystemCallChannel';
    final from = swift.indexOf(start);
    if (from < 0) return '';
    // To the next top-level declaration. Good enough for a grep, and the
    // positive control below fails loudly if it ever is not.
    final to = swift.indexOf('\nextension CallKitRinger', from);
    return to < 0 ? swift.substring(from) : swift.substring(from, to);
  }

  test('the harness can see the Swift side — positive control', () {
    // Without this, a moved file or a renamed class would make every assertion
    // below pass vacuously against an empty string and report "no drift"
    // forever. A negative reading is a fact about the instrument first.
    expect(
      swift,
      isNotEmpty,
      reason: 'AppDelegate.swift did not read — this test is blind',
    );
    expect(
      systemCallChannelSource(),
      contains('FlutterEventChannel'),
      reason:
          'the SystemCallChannel class did not slice out of AppDelegate.swift '
          '— it was renamed or moved, and this test is now blind',
    );
  });

  test('both channel names exist verbatim on the Swift side', () {
    final src = systemCallChannelSource();
    expect(
      src,
      contains('"$kSystemCallActionsChannel"'),
      reason:
          'the answer never reaches Dart: the event channel Dart listens on is '
          'not the one Swift emits to',
    );
    expect(
      src,
      contains('"$kSystemCallControlChannel"'),
      reason:
          'Dart can never end a system call, so a failed join leaves a phantom '
          'connected call in the OS call UI',
    );
  });

  test('the method Dart invokes, Swift answers', () {
    final dart = File(
      'lib/features/call/data/system_call_bridge.dart',
    ).readAsStringSync();
    final invoked = RegExp(
      r"invokeMethod<[^>]*>\(\s*'([A-Za-z0-9_]+)'",
    ).allMatches(dart).map((m) => m.group(1)!).toSet();
    expect(
      invoked,
      isNotEmpty,
      reason: 'the Dart regex found no invokeMethod — this test is blind',
    );
    final handled = RegExp(
      r'case "([A-Za-z0-9_]+)":',
    ).allMatches(systemCallChannelSource()).map((m) => m.group(1)!).toSet();
    expect(
      invoked.difference(handled),
      isEmpty,
      reason:
          'MissingPluginException is swallowed on the Dart side by design (a '
          'teardown must not be taken out by it), so this mismatch surfaces '
          'only as a system call that never clears',
    );
  });

  test('every action kind Dart knows is one Swift can emit', () {
    // The enum is the census on both sides. Swift declares
    // `enum Action: String { case answered ... }`; Dart's member NAMES are the
    // strings that cross, so a member added on one side and not the other is a
    // transition that decodes to null and is silently dropped.
    final swiftCases = RegExp(
      r'case ([a-z][A-Za-z0-9]*)$',
      multiLine: true,
    ).allMatches(systemCallChannelSource()).map((m) => m.group(1)!).toSet();
    expect(
      swiftCases,
      isNotEmpty,
      reason: 'the Swift enum-case regex found nothing — this test is blind',
    );
    expect(
      SystemCallActionKind.values.map((k) => k.name).toSet(),
      swiftCases,
      reason:
          'the two halves disagree about which transitions exist. Extra on the '
          'Dart side is a case that can never fire; extra on the Swift side is '
          'a transition the app drops on the floor.',
    );
  });

  test('the payload keys are the same two words on both sides', () {
    final src = systemCallChannelSource();
    for (final key in ['action', 'channel']) {
      expect(
        src,
        contains('"$key"'),
        reason:
            'Dart decodes the event map by this key; a rename makes every '
            'event decode to null, which this app treats as an unknown '
            'transition and ignores',
      );
    }
    final dart = File(
      'lib/features/call/data/system_call_bridge.dart',
    ).readAsStringSync();
    expect(dart, contains("event['action']"));
    expect(dart, contains("event['channel']"));
  });
}
