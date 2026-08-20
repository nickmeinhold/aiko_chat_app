// The Apple half of the push pairing, at its platform-channel seam.
//
// This CANNOT prove a real device gets a real token — only a handset can, and
// the arc's definition of done says so explicitly. What it does prove is every
// way the Dart side can mishandle what the channel gives it, and one specific
// build accident: a `.swift` file that is not in the Runner target compiles to
// nothing and surfaces as MissingPluginException, which must degrade reach and
// never fail a sign-in.
import 'package:aiko_chat_app/features/notifications/data/apns_token_source.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _methods = MethodChannel('cc.imagineering.aikoChatApp/apns');
const _refreshes = EventChannel('cc.imagineering.aikoChatApp/apns/refreshes');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  ApnsTokenSource build() =>
      ApnsTokenSource(platformOverride: TargetPlatform.iOS);

  /// Answers the method channel with [handler]; null handler = no native side,
  /// which is what the framework turns into a MissingPluginException.
  void onMethod(Future<Object?>? Function(MethodCall)? handler) =>
      messenger.setMockMethodCallHandler(_methods, handler);

  tearDown(() => onMethod(null));

  test('the transport is apns — the discriminator the island keys its send '
      'path on', () {
    expect(build().platform, DevicePlatform.apns);
  });

  test('it refuses to be constructed on Android, where there is no APNs', () {
    expect(
      () => ApnsTokenSource(platformOverride: TargetPlatform.android),
      throwsA(isA<AssertionError>()),
      reason:
          'the mirror of FcmTokenSource. Getting the transport wrong is silent '
          'in both directions — a token registers, the island stores it, and '
          'pushes go to a service that has never heard of this device',
    );
  });

  group('permission', () {
    test('a grant is reported as granted', () async {
      onMethod(
        (call) async => call.method == 'requestPermission' ? true : null,
      );

      expect(await build().requestPermission(), isTrue);
    });

    test('a refusal is an ordinary answer, not an error', () async {
      onMethod((_) async => false);

      expect(await build().requestPermission(), isFalse);
    });

    test('a native failure degrades reach rather than throwing', () async {
      onMethod((_) async => throw PlatformException(code: 'ERR'));

      await expectLater(build().requestPermission(), completion(isFalse));
    });

    test('a MISSING native side degrades reach too — the shape of a .swift '
        'that never made it into the Runner target', () async {
      onMethod(null);

      await expectLater(build().requestPermission(), completion(isFalse));
    });
  });

  group('the current token', () {
    test(
      'is returned verbatim — the island stores exactly these bytes',
      () async {
        const token =
            'a1b2c3d4e5f60718293a4b5c6d7e8f90'
            'a1b2c3d4e5f60718293a4b5c6d7e8f90';
        onMethod((call) async => call.method == 'currentToken' ? token : null);

        expect(await build().currentToken(), token);
        expect(
          token,
          hasLength(64),
          reason:
              'a standard APNs device token is 64 lowercase hex characters. '
              'Anything derived from Data.description would carry angle brackets '
              'and spaces, and the only symptom would be silence',
        );
      },
    );

    test('no token yet reads as null, not an exception', () async {
      onMethod((_) async => null);

      expect(await build().currentToken(), isNull);
    });

    test('a registration failure reads as null — an unreachable APNs must not '
        'be able to fail a sign-in', () async {
      onMethod((_) async => throw PlatformException(code: 'ERR'));

      await expectLater(build().currentToken(), completion(isNull));
    });

    test('a missing native side reads as null', () async {
      onMethod(null);

      await expectLater(build().currentToken(), completion(isNull));
    });
  });

  group('rotations', () {
    /// Drives the event channel the way the framework does, so the test
    /// exercises the real stream plumbing rather than a hand-made Stream.
    Future<void> emit(Object? event) => messenger.handlePlatformMessage(
      _refreshes.name,
      _refreshes.codec.encodeSuccessEnvelope(event),
      (_) {},
    );

    Future<void> emitError(String code) => messenger.handlePlatformMessage(
      _refreshes.name,
      _refreshes.codec.encodeErrorEnvelope(code: code),
      (_) {},
    );

    setUp(() {
      // The stream handler's listen/cancel arrive as method calls on the event
      // channel; without a handler they raise MissingPluginException.
      messenger.setMockMethodCallHandler(
        MethodChannel(_refreshes.name, _refreshes.codec),
        (_) async => null,
      );
    });

    tearDown(
      () => messenger.setMockMethodCallHandler(
        MethodChannel(_refreshes.name, _refreshes.codec),
        null,
      ),
    );

    test('a rotated token reaches the registrar', () async {
      final rotations = build().tokenRefreshes();
      final seen = <String>[];
      final sub = rotations.listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      await emit('tok-rotated');
      await Future<void>.delayed(Duration.zero);

      expect(seen, ['tok-rotated']);
    });

    test('an error on the stream does NOT kill the subscription', () async {
      // The one that would fail silently and permanently: a stream that closes
      // on error leaves the registrar deaf to every later rotation for the life
      // of the session, and nothing surfaces a dead stream.
      final seen = <String>[];
      var done = false;
      final sub = build().tokenRefreshes().listen(
        seen.add,
        onDone: () => done = true,
      );
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      await emitError('BOOM');
      await Future<void>.delayed(Duration.zero);
      await emit('tok-after-the-error');
      await Future<void>.delayed(Duration.zero);

      expect(seen, ['tok-after-the-error']);
      expect(done, isFalse, reason: 'the subscription must still be alive');
    });
  });
}
