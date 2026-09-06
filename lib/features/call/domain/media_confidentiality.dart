// Whether a call's media is end-to-end encrypted, and who can hear it if not.
//
// Nick's ruling, 2026-08-31, recorded in both tabs (island design 13, Decision
// 9d, DECIDED): "the user should always know if their call is going to go
// through an island unencrypted." Disclosed AT CALL TIME, and FAILING CLOSED.
//
// TWO INVARIANTS. Everything else here is detail; these are the load-bearing
// pair, and a change that breaks either changes the security claim:
//
//   1. FAIL CLOSED. Every way of not knowing resolves to
//      `notEndToEndEncrypted`. Only a positive, verified statement may produce
//      the other branch, and nothing can produce it today.
//   2. DO NOT OVERSTATE. The media IS encrypted on the wire — WebRTC mandates
//      DTLS-SRTP — and is decrypted AT the island. So the claim is "not
//      END-TO-END encrypted", never the stronger, false "not encrypted". A
//      disclosure that overstates is still a disclosure that lies.
//
// True today, verified in this repo rather than assumed: forced relay
// (`RTCIceTransportPolicy.relay`), an SFU rather than a mesh, and no
// `e2eeOptions` anywhere in `lib/` — pinned by a test that greps for them, so
// enabling media E2EE goes red rather than silently making this file lie.
//
// The island manifest is NOT consulted. Design 13 calls the `island_mode` split
// (#3426 Q1) "a precondition for the disclosure"; it is a precondition for the
// POSITIVE case only, and the unconditional negative is what fail-closed
// produces anyway. When that changes it needs its OWN trust root:
// `island_manifest_provider.dart` caches `GET /v1/island` unverified and says so
// itself (claude-tasks#3730). Do not reach for that cache here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';

/// Whether the media of a call is end-to-end encrypted.
///
/// Two states, and deliberately no `unknown` — an unknown answer is a
/// disclosure DECISION, owned by [resolveMediaConfidentiality], not a third
/// thing for a widget to draw a shrug about.
enum MediaConfidentiality {
  /// The island can hear and see this call.
  notEndToEndEncrypted,

  /// Only the participants hold the keys. Nothing produces this today — it
  /// exists so the UI is driven by a value rather than being a constant wearing
  /// a widget, and so a test can exercise the branch that does not ship. A
  /// renderer with one reachable state cannot be shown to depend on it.
  endToEndEncrypted,
}

/// What a call's media does, and through whose hands.
///
/// Also the SINGLE SOURCE of the words. Two surfaces show this — the chip and
/// the Call entry's subtitle — and two controls describing one fact differently
/// is how a disclosure becomes a lie on one of them.
@immutable
class MediaRouting {
  const MediaRouting({required this.confidentiality, this.islandHost});

  final MediaConfidentiality confidentiality;

  /// The island the media passes through, named by the HOST THE USER CHOSE —
  /// never by the display name in the island's own self-manifest. A disclosure
  /// must not let its subject pick the words describing it: an island calling
  /// itself "Secure Private Chat" would otherwise print that inside the warning
  /// about itself.
  ///
  /// NULL, not `''`, when unknown. The empty string was a sentinel in an open
  /// type, so `''`, `'   '` and "not resolved yet" were the same value and a
  /// whitespace host would have rendered as a real attribution (Carnot, round 2).
  final String? islandHost;

  bool get isEndToEndEncrypted =>
      confidentiality == MediaConfidentiality.endToEndEncrypted;

  /// Whether we can name who the media passes through.
  ///
  /// The claim and the attribution fail SEPARATELY, and only the attribution may
  /// disappear: losing "through chat.example" leaves "not end-to-end encrypted"
  /// exactly as true.
  bool get hasAttribution => (islandHost?.trim().isNotEmpty) ?? false;

  /// The short form, for a chip.
  String get label {
    if (isEndToEndEncrypted) return 'End-to-end encrypted';
    return hasAttribution
        ? 'Not end-to-end encrypted · ${islandHost!.trim()}'
        : 'Not end-to-end encrypted';
  }

  /// The full sentence: a screen reader's label, and the Call entry's subtitle.
  ///
  /// Says WHO CAN HEAR YOU rather than making a transport claim. An earlier
  /// version said "in the clear", which is false — the media is not in the clear
  /// on the wire, it is decrypted at the island.
  String get sentence {
    if (isEndToEndEncrypted) return 'This call is end to end encrypted.';
    return hasAttribution
        ? 'This call is not end to end encrypted. ${islandHost!.trim()} can '
              'hear and see it.'
        // Vague because it is not known, not to be gentle about it.
        : 'This call is not end to end encrypted. The island carrying it can '
              'hear and see it.';
  }

  // COUPLING, named because it is invisible and will break silently (Carnot,
  // round 1). [islandHost] comes from the API base URL, which is only the media
  // host because a call is hosted by the island you are signed in to. Under
  // callee-hosting (island Decision 9) a cross-island call is hosted by the
  // CALLEE's island — one the caller never chose — and this would name the wrong
  // operator while the claim stayed true. That is the case 9d says the
  // disclosure bites hardest on, so it must not be discovered there. Gated on
  // claude-tasks#3697 rather than modelled now.
}

/// The disclosure's single source of truth.
final mediaRoutingProvider = Provider<MediaRouting>((ref) {
  // GUARDED, because reading config unguarded made the disclosure THROW where
  // config was absent — which is not a cautious warning, it is NO warning, and
  // it took the ring banner down with it. The behaviour stays broad on purpose:
  // any failure here degrades to an unattributed warning, never to silence.
  String? host;
  try {
    final raw = ref.watch(configProvider).httpBaseUrl;
    host = Uri.tryParse(raw)?.host;
    if ((host == null || host.isEmpty) &&
        raw.isNotEmpty &&
        !raw.contains('://')) {
      // A scheme-less base URL parses with an EMPTY host — the whole string
      // lands in `path` — so attribution went mute for a config shape that is
      // not obviously invalid. Re-parse as authority-only. Deliberately NOT
      // falling back to the raw string: a base URL can carry userinfo or a path,
      // and a warning is the last place to print either.
      host = Uri.tryParse('//$raw')?.host;
    }
  } catch (e) {
    // The message, not the stack: printing `$st` buried the trail in a 60-frame
    // dump on every widget test that mounts the chip without config.
    assert(() {
      debugPrint('media disclosure: island attribution unavailable — $e');
      return true;
    }());
  }
  return MediaRouting(
    confidentiality: resolveMediaConfidentiality(),
    islandHost: host,
  );
});

/// Today's answer, and the one seam a manifest read will land in.
///
/// Takes no argument on purpose: nothing could currently change the result, and
/// inventing a parameter would suggest something can.
MediaConfidentiality resolveMediaConfidentiality() =>
    // Forced relay + an SFU + no `e2eeOptions`. Not "we could not tell" — we can
    // tell, and the answer is no.
    MediaConfidentiality.notEndToEndEncrypted;
