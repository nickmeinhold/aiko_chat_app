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
    expect(
      c.name,
      '',
    ); // a DM has no server name; the peer is the display title
  });

  test('fromDmJson FAILS CLOSED on a non-dm kind (contract drift)', () {
    // A trust boundary: fromWire collapses unknown/absent → standard, so a
    // drifted POST /v1/dm response must throw here rather than yield a non-DM
    // channel the caller would push into a doomed (video-less) call route.
    expect(
      () => Channel.fromDmJson(const {'channel_id': 'x', 'kind': 'standard'}),
      throwsFormatException,
    );
    expect(
      () => Channel.fromDmJson(const {
        'channel_id': 'x',
      }), // absent kind → standard → throw
      throwsFormatException,
    );
  });
}
