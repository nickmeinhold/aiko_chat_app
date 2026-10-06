// Shared call fixtures (design 22): calling is v2-only, so a test's "an
// invite" or "a hangup" is a call/2 body. These are the golden bytes pinned
// with the island (`call_wire_test.dart`), as consts so they can be default
// parameter values.
import 'package:aiko_chat_app/features/call/domain/call_wire.dart';

/// The golden call id, shared with the island's `test_call_wire_v2.py`.
const kTestCallId = '01JABCDEFGHJKMNPQRSTVWXYZ0';

/// A second, distinct call id — for "a different call" cases.
const kOtherCallId = '01JZZZZZZZZZZZZZZZZZZZZZZZ';

/// The invite and end for [kTestCallId].
const kTestInviteBody =
    'aiko:call/2 01JABCDEFGHJKMNPQRSTVWXYZ0 · 📞 started a call';
const kTestEndBody =
    'aiko:call/2 01JABCDEFGHJKMNPQRSTVWXYZ0 · 📞 ended the call';

/// The invite and end for [kOtherCallId].
const kOtherInviteBody =
    'aiko:call/2 01JZZZZZZZZZZZZZZZZZZZZZZZ · 📞 started a call';
const kOtherEndBody =
    'aiko:call/2 01JZZZZZZZZZZZZZZZZZZZZZZZ · 📞 ended the call';

final kTestCall = CallRef(kTestCallId);
final kOtherCall = CallRef(kOtherCallId);
