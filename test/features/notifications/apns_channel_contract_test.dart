// The platform channel's method names, asserted ACROSS THE LANGUAGE BOUNDARY.
//
// THE FAILURE THIS EXISTS FOR, caught live during the `apns_environment` rename.
// A blanket rename over `lib/` and `test/` moved the Dart side to invoke
// `apnsEnvironment` and left `ios/Runner/AppDelegate.swift` answering
// `pushEnvironment`. The consequences, in order, all silent:
//
//   invokeMethod('apnsEnvironment') -> MissingPluginException
//     -> ApnsTokenSource catches it and answers null (correctly! reach is never
//        a gate)
//     -> the register omits the field
//     -> the island resolves it from APNS_USE_SANDBOX
//     -> a TestFlight build's production token goes to the sandbox host
//     -> 400 BadDeviceToken, and the handset simply never rings.
//
// Which is precisely the failure the whole `apns_environment` feature exists to
// remove, re-created by the rename that implemented it.
//
// EVERY DART TEST STAYED GREEN, and that is the part worth understanding rather
// than just fixing. `apns_token_source_test.dart` mocks the channel and switches
// on the method name — the SAME name the source invokes, because the rename
// touched both. A verifier that shares a representation with the thing it
// verifies is structurally blind to a bug in that shared layer; it confirms the
// very failure it exists to catch. So this test deliberately reads the OTHER
// side's source text, which is the one artifact the Dart rename cannot reach.
//
// It is a coarse instrument — it greps Swift rather than executing it — and that
// is the honest scope: it proves the two sides NAME the same methods, not that
// the native implementation is correct. Naming is exactly what drifted.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Every method name the Dart side invokes on the APNs channel.
  ///
  /// Read from the source rather than hand-listed, so adding an
  /// `invokeMethod('somethingNew')` without a Swift case fails here rather than
  /// on a handset.
  Set<String> dartInvokedMethods() {
    final src = File(
      'lib/features/notifications/data/apns_token_source.dart',
    ).readAsStringSync();
    return RegExp(
      r"invokeMethod<[^>]*>\('([A-Za-z0-9_]+)'\)",
    ).allMatches(src).map((m) => m.group(1)!).toSet();
  }

  /// Every method name the native side answers.
  Set<String> swiftHandledMethods() {
    final src = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    return RegExp(
      r'case "([A-Za-z0-9_]+)":',
    ).allMatches(src).map((m) => m.group(1)!).toSet();
  }

  test('the harness can actually see both sides — positive control', () {
    // Without this, an empty read (moved file, changed syntax) would make the
    // subset assertion below pass vacuously and report "no drift" forever. A
    // negative reading is a fact about the instrument until proven otherwise.
    expect(
      dartInvokedMethods(),
      contains('currentToken'),
      reason:
          'the Dart regex found nothing — the source moved or the call '
          'shape changed, and this test is now blind',
    );
    expect(
      swiftHandledMethods(),
      contains('requestPermission'),
      reason:
          'the Swift regex found nothing — AppDelegate moved or the switch '
          'shape changed, and this test is now blind',
    );
  });

  test('every method Dart invokes, Swift answers', () {
    final invoked = dartInvokedMethods();
    final handled = swiftHandledMethods();

    expect(
      invoked.difference(handled),
      isEmpty,
      reason:
          'a method the app calls and the native side does not handle returns '
          'MissingPluginException, which this app deliberately degrades to null '
          'rather than throwing — so the mismatch never surfaces as an error, '
          'only as a device that quietly stops being reachable',
    );
  });

  test('the environment method is named on BOTH sides', () {
    // Named explicitly as well as covered by the subset above, because this is
    // the one that drifted and a specific assertion says so to the next reader.
    expect(dartInvokedMethods(), contains('apnsEnvironment'));
    expect(swiftHandledMethods(), contains('apnsEnvironment'));
  });
}
