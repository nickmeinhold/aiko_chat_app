import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// `Channel.fromDmJson` maps the `POST /v1/dm` find-or-create response, whose
/// shape differs from `GET /v1/channels`: the id field is `channel_id` (not
/// `id`) and there is no `name`. A silent regression here would send the call to
/// the wrong room (or crash on the missing `id` key), so it is pinned explicitly.
void main() {
  test('fromDmJson reads channel_id as the id and marks the channel a DM', () {
    final c = Channel.fromDmJson(const {
      'channel_id': 'dm:01ABC:01XYZ',
      'kind': 'dm',
      'members': ['01ABC', '01XYZ'],
      'created_at': '2026-08-10T13:00:00Z',
    });

    expect(c.id, 'dm:01ABC:01XYZ'); // channel_id → id (NOT the absent `id` key)
    expect(c.kind, ChannelKind.dm);
    expect(c.name, ''); // a DM has no server name; the peer is the display title
  });

  test('fromDmJson decodes kind off the wire rather than assuming dm', () {
    // Defensive: if the server ever returns a non-dm kind here we surface it
    // honestly instead of hardcoding dm.
    final c = Channel.fromDmJson(const {'channel_id': 'x', 'kind': 'standard'});
    expect(c.kind, ChannelKind.standard);
  });
}
