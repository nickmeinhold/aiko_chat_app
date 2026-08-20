// The transport split, asserted rather than trusted to a comment.
//
// Everything else about FcmTokenSource is a thin forward to FirebaseMessaging
// and is not worth a mock. The one thing that IS worth pinning is the platform
// constraint, because getting it wrong has no symptom: FlutterFire returns an
// APNs-backed token on Apple platforms, the island stores it under
// `platform=fcm`, pushes are delivered, and Google has silently become a second
// intermediary on the one platform where Apple was already a mandatory first.
// Nothing fails. That is exactly the shape of defect a test has to carry.
import 'package:aiko_chat_app/features/notifications/data/fcm_token_source.dart';
import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('constructs on Android', () {
    expect(
      FcmTokenSource(platformOverride: TargetPlatform.android).platform,
      DevicePlatform.fcm,
    );
  });

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.fuchsia,
  ]) {
    test('refuses to construct on $platform — a token from here would be the '
        'wrong transport, silently', () {
      expect(
        () => FcmTokenSource(platformOverride: platform),
        throwsA(isA<AssertionError>()),
      );
    });
  }
}
