@Tags(['live'])
library;

// A DRIFT GATE against a REAL island's served schema.
//
// The rest of the suite proves the app is self-consistent about
// `push_environment`. Self-consistency is exactly what cannot catch this bug
// class: our enum and our tests and our fakes can all agree on a string the
// island has never accepted.
//
// This one did catch it. The design note said the closed set was
// development/production, our code sent `development`, every unit test was
// green, and the deployed island's enum is ["sandbox", "production"] — a DB
// CHECK that would have 422'd the entire registration of every debug build.
// One HTTP GET refuted six files.
//
// `production` is the trap: it means the same thing on both sides, so the
// release path looks correct while the debug path is broken. A drift gate that
// only spot-checked one value would have passed.
//
// EXCLUDED from the default run — it needs network. Run it deliberately, and
// run it before shipping anything that touches the register body:
//
//   PUSH_ENV_ISLAND=https://chat.imagineering.cc \
//   flutter test test/live/push_environment_drift_test.dart --run-skipped --tags live

import 'dart:convert';
import 'dart:io';

import 'package:aiko_chat_app/features/notifications/domain/push_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final island =
      Platform.environment['PUSH_ENV_ISLAND'] ?? 'https://chat.imagineering.cc';

  late Map<String, dynamic> schema;

  setUpAll(() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$island/openapi.json'));
      final res = await req.close();
      expect(
        res.statusCode,
        200,
        reason: 'the island at $island did not serve a schema to gate against',
      );
      schema =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
    } finally {
      client.close();
    }
  });

  Map<String, dynamic> componentSchema(String name) =>
      ((schema['components'] as Map)['schemas'] as Map)[name]
          as Map<String, dynamic>;

  test('our wire strings ARE the island\'s closed set — exactly', () {
    final islandSet = (componentSchema('PushEnvironment')['enum'] as List)
        .cast<String>()
        .toSet();

    expect(
      PushEnvironment.values.map((e) => e.wire).toSet(),
      islandSet,
      reason:
          'set equality, not membership: a value we can send that the island '
          'rejects fails the whole registration, and a value it accepts that we '
          'can never send is a capability silently missing from the app',
    );
  });

  test('push_environment is OPTIONAL on the register body', () {
    final req = componentSchema('RegisterDeviceReq');

    expect(
      (req['required'] as List).cast<String>(),
      isNot(contains('push_environment')),
      reason:
          'the whole null-is-a-real-answer design rests on omission being legal '
          '— if it became required, every FCM register would 422',
    );
    expect(
      (req['properties'] as Map).containsKey('push_environment'),
      isTrue,
      reason: 'the island stopped accepting the field we send',
    );
  });
}
