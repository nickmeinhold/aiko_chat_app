// Whether a call's media is end-to-end encrypted, and who can see it if not.
//
// Nick's ruling, 2026-08-31: **"the user should always know if their call is
// going to go through an island unencrypted."** Recorded in both tabs — the
// island's `docs/design/13-cross-island-calling-host-selection-and-exposure.md`
// carries it as Decision 9d, DECIDED, and adds the two properties that matter
// here: the disclosure happens AT CALL TIME rather than in a document, and it
// FAILS CLOSED.
//
// WHY THIS IS A CLOSED TYPE AND NOT A BOOL OR A STRING. It is a two-state fact
// today and a three-source fact tomorrow (client capability, the hosting
// island's signed manifest, and the call's own negotiated state). A `bool
// isEncrypted` invites `!isEncrypted` to mean "we checked and it is not", when
// the honest reading of an absent answer is the same as a negative one but for
// a completely different reason. An enum makes the resolver the only place that
// collapses those, and makes the collapse visible.
//
// WHAT IS TRUE TODAY, verified in this repo rather than assumed:
//   * `livekit_call_service.dart` pins `RTCIceTransportPolicy.relay`, so there
//     is no direct path — peer-IP privacy was a hard requirement and `.all` an
//     explicitly rejected fallback.
//   * LiveKit is an SFU, never a mesh, so media terminates at the server.
//   * `Room.connect` passes no `e2eeOptions`, and a grep for
//     `e2eeOptions|frameCryptor|keyProvider` across `lib/` finds only comments
//     noting their absence.
// Two server hops by construction, and the second one decrypts. So the answer
// is not merely unknown, it is known and it is NEGATIVE.
//
// WHY THE ISLAND MANIFEST IS NOT CONSULTED YET, which is the interesting part.
// Design 13 records the `island_mode` split (#3426 Q1) as "a precondition for
// the disclosure". That is true of the POSITIVE case only: you cannot honestly
// tell a user their media IS encrypted without a signed, verified field saying
// so. It is not a precondition for the disclosure itself, because an
// unconditional negative is exactly what fail-closed produces, and it is the
// branch a manifest-reading version would fall back to anyway. So this ships
// now and grows a manifest read later, at [resolveMediaConfidentiality], which
// is deliberately the single place that will change.
//
// And when it does change it needs its OWN trust root. `island_manifest_provider
// .dart` already fetches `GET /v1/island`, but caches it unverified and says so
// in its own header: *"If islands ever need to be cryptographically identified
// in the UI, that is a different feature with its own trust root, and it should
// not inherit this one's cache."* That is claude-tasks#3730, answered in advance
// by the code it is about. Do not reach for that cache here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';

/// Whether the media of a call is end-to-end encrypted.
///
/// Two states, and there is deliberately no `unknown`. An unknown answer is a
/// disclosure decision, not a third fact to render — see
/// [resolveMediaConfidentiality], which owns that collapse.
enum MediaConfidentiality {
  /// The server can see and hear this call.
  notEndToEndEncrypted,

  /// Only the participants hold the keys. **Nothing produces this today** — it
  /// exists so the disclosure is driven by a value rather than being a constant
  /// wearing a widget, and so its test can exercise the branch that does not
  /// ship. A renderer with one reachable state cannot be shown to depend on it.
  endToEndEncrypted,
}

/// What a call's media does, and through whose hands.
class MediaRouting {
  const MediaRouting({required this.confidentiality, required this.islandHost});

  final MediaConfidentiality confidentiality;

  /// The island the media passes through, named by the HOST THE USER CHOSE —
  /// never by the display name in the island's self-manifest.
  ///
  /// A disclosure must not let its subject choose the words it is described in.
  /// An island that calls itself "Secure Private Chat" would otherwise get to
  /// print that inside the sentence warning you about it, and the manifest that
  /// name comes from is unverified and cached (see the header). The host is the
  /// one identifier in this sentence the user supplied themselves.
  ///
  /// EMPTY when the app cannot say which island this is. That is an attribution
  /// failure, never a reason to go quiet: see [hasAttribution].
  final String islandHost;

  /// Whether we can name who the media passes through.
  ///
  /// The claim and the attribution fail SEPARATELY and only one of them is
  /// allowed to disappear. Losing "through chat.example" leaves "not encrypted"
  /// exactly as true as it was, so the warning renders without the name rather
  /// than not at all.
  bool get hasAttribution => islandHost.isNotEmpty;

  // COUPLING, named now because it is invisible and will break silently
  // (Carnot, cage-match round 1). [islandHost] is derived from the API base
  // URL, which is only the media host because a call is hosted by the island
  // you are signed in to. Under the island tab's Decision 9 (callee-hosting),
  // a cross-island call is hosted by the CALLEE's island — one the caller never
  // chose — and this attribution would then name the wrong operator while the
  // claim stayed true. That is precisely the case Decision 9d says the
  // disclosure "bites hardest" on, so it must not be discovered there.
  //
  // Not fixed here because cross-island calling does not work at all yet
  // (Decision 9) and inventing a hosting-island parameter now would model a
  // thing that does not exist. It is gated: claude-tasks#3697 must not ship
  // without revisiting THIS field.

  bool get isEndToEndEncrypted =>
      confidentiality == MediaConfidentiality.endToEndEncrypted;
}

/// The disclosure's single source of truth.
///
/// FAILS CLOSED, and this is the whole reason the function exists rather than a
/// literal at each call site: every way of not knowing — an island too old to
/// answer, an unreadable field, a request that never returned, a value in a
/// shape we do not recognise — resolves to [MediaConfidentiality
/// .notEndToEndEncrypted]. Only a positive, verified statement may ever produce
/// the other branch, and nothing can produce it today.
final mediaRoutingProvider = Provider<MediaRouting>((ref) {
  // The config read is GUARDED, and the reason is a bug this caught in its own
  // review: reading it unguarded made the disclosure throw when config was
  // unavailable, which does not produce a cautious warning — it produces NO
  // WARNING AT ALL, and takes the ring banner down with it. A fail-closed
  // feature that fails open when its own dependency is missing is worse than
  // one that never claimed to be careful.
  //
  // So the two halves of the sentence fail independently: the CLAIM is computed
  // from this repo's own code and cannot fail, and only the ATTRIBUTION depends
  // on anything outside it.
  String host = '';
  try {
    // `Uri.parse(...).host` rather than the mark module's `islandKey`: this is a
    // security sentence, not a drawing, and it should not quietly inherit the
    // normalisation or the cache of the identity-colour machinery.
    final raw = ref.watch(configProvider).httpBaseUrl;
    host = Uri.tryParse(raw)?.host ?? '';
    if (host.isEmpty && raw.isNotEmpty && !raw.contains('://')) {
      // A scheme-less base URL ("chat.example.com") PARSES — the whole string
      // lands in `path` and `host` comes back empty — so the disclosure went
      // mute for a config shape that is not obviously invalid (Maxwell,
      // cage-match round 1). Re-parse as authority-only to recover the name.
      // Deliberately NOT falling back to the raw string: a base URL can carry
      // userinfo or a path, and a warning is the last place to print either.
      host = Uri.tryParse('//$raw')?.host ?? '';
    }
  } catch (e) {
    // The aperture was `catch (_)` and swallowed EVERYTHING (Maxwell,
    // cage-match round 1): a genuine bug in `configProvider` — a bad cast, a
    // failed assertion — presented identically to "no SharedPreferences in a
    // widget test", so the next person debugging a missing island name would
    // read a comment saying "no config" while the truth was a TypeError three
    // layers down. The BEHAVIOUR must stay broad (any failure here still
    // degrades to an unattributed warning rather than no warning), so the fix
    // is not a narrower catch — it is leaving a breadcrumb.
    assert(() {
      // The MESSAGE, not the stack. The first version printed `$st` too, which
      // dumped a 60-frame trace into every widget test that mounts this chip
      // without config — a breadcrumb that buries the trail it exists to leave.
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
/// Takes no argument on purpose: there is currently no input that could change
/// the result, and inventing a parameter now would suggest one exists.
MediaConfidentiality resolveMediaConfidentiality() =>
    // Forced relay + an SFU + no `e2eeOptions`. Not "we could not tell" — we
    // can tell, and the answer is no.
    MediaConfidentiality.notEndToEndEncrypted;
