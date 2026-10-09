// Runs before every test file (flutter_test's `testExecutable` hook).
//
// The native call bridge is live in every build since 0.0.6, so any test that
// mounts the app builds `NativeSystemCallBridge`, and it listens on
// `call/actions` straight away. A test has no native side behind that channel,
// so without a handler each listen throws `MissingPluginException` (51 chat
// tests failed on exactly that when the calling flag was deleted). The flag had
// been keeping the bridge null in tests; this stub does that job on purpose.
//
// The stub is silent: the stream emits nothing and every control call returns
// null. A test that drives the bridge injects its own channels through the
// constructor, or installs its own handler, which replaces this one.
import 'dart:async';

import 'package:aiko_chat_app/features/call/data/system_call_bridge.dart'
    show kSystemCallActionsChannel, kSystemCallControlChannel;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockStreamHandler(
      const EventChannel(kSystemCallActionsChannel),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(kSystemCallControlChannel),
      (_) async => null,
    );
  });
  await testMain();
}
