// The disclosure, as a thing you can see rather than a thing you must dismiss.
//
// Nick chose an always-visible indicator over a confirmation sheet: no
// interruption, ever. That choice puts the whole weight of Decision 9d on this
// widget being LEGIBLE, because nothing forces the user to look at it — so it
// says what it means in words ("Not encrypted"), names who can listen, and does
// not rely on a padlock glyph being read correctly by someone who has seen a
// thousand padlocks.
//
// WHERE IT IS SHOWN — and the honest scope of "before connect", which is NOT
// the same for both parties (Maxwell, cage-match round 1; the first draft of
// this comment claimed it was):
//   * the RING banner. Genuinely before: the callee must press Answer, and the
//     warning is on the surface carrying that button. This is the party the
//     ruling protects most, and the one who did not choose the island.
//   * the CALL screen from its first frame, the `connecting` state. For the
//     CALLER this is concurrent with connect, not prior to it —
//     `CallScreen.initState` fires `unawaited(_session.connect())` and returns
//     before the first frame is painted, so the room join is already in flight
//     when these pixels first exist.
// That second one is a consequence of the chosen shape, not an oversight: an
// indicator cannot gate an action that has no gate, and Nick chose an indicator
// over a confirmation sheet precisely to avoid interrupting every call. The
// caller also chose to place it. But the distinction is real, so it is written
// down rather than smoothed over — overclaiming inside a feature whose whole
// job is to not overclaim would be the joke writing itself.
// An indicator that only appeared once a call was CONNECTED would be strictly
// worse than both, which is why it is drawn in every state.
//
// It draws its own colours instead of taking `ColorScheme` roles. Two roles can
// swap their relationship between light and dark, and this pill sits on a
// near-black video surface in one place and a themed banner in another; a
// warning that goes low-contrast in one theme is a warning that stopped
// working.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/media_confidentiality.dart';

/// Names, in a sentence, what the server can do with this call's media.
class MediaConfidentialityChip extends ConsumerWidget {
  const MediaConfidentialityChip({super.key});

  // There was a `compact` flag here that dropped the island name for a narrow
  // surface. It is GONE, for two reasons that arrived together: the ring banner
  // now gives the disclosure a full-width line of its own so nothing needs it,
  // and a parameter whose only power is to silently weaken a warning is a
  // footgun waiting for a caller. The claim's length is not negotiable; if a
  // future surface cannot fit it, that surface gets more room, not less truth.

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routing = ref.watch(mediaRoutingProvider);
    final encrypted = routing.isEndToEndEncrypted;

    // The claim always renders. The island name is an addition to it, never a
    // precondition for it: an unknown host drops the attribution and the claim
    // stands unchanged.
    final attributed = routing.hasAttribution;
    // "Not END-TO-END encrypted", never the shorter "Not encrypted" (Carnot,
    // cage-match round 1). The media IS encrypted on the wire — WebRTC mandates
    // DTLS-SRTP — and is decrypted AT the island. "Not encrypted" is the
    // rhetorically stronger sentence and the technically false one, and a
    // disclosure that overstates is still a disclosure that lies, which is the
    // precise failure this whole feature exists to prevent.
    //
    // The tell was in the diff the whole time: the enum is
    // `notEndToEndEncrypted` and the label said something weaker than its own
    // type. When the widget's word and the domain's word disagree, the domain
    // is usually the one that was thought about.
    final label = encrypted
        ? 'End-to-end encrypted'
        : attributed
        ? 'Not end-to-end encrypted · ${routing.islandHost}'
        : 'Not end-to-end encrypted';

    return Semantics(
      // The screen reader gets the FULL sentence even when the visible chip is
      // compact: the reason to shorten is horizontal space, which costs a
      // listener nothing.
      // "in the clear" went the same way as "Not encrypted", and for the same
      // reason: the media is not in the clear ON THE WIRE, it is decrypted AT
      // the island. What the user needs to know is WHO CAN HEAR THEM, so say
      // that instead of a transport claim that is false.
      label: encrypted
          ? 'This call is end to end encrypted.'
          : routing.hasAttribution
          ? 'This call is not end to end encrypted. ${routing.islandHost} can '
                'hear and see it.'
          // Named vaguely because it is not known, not to be gentle about it.
          : 'This call is not end to end encrypted. The island carrying it can '
                'hear and see it.',
      container: true,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xCC101418),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: encrypted
                  ? const Color(0x5563D18F)
                  : const Color(0x88E8A33D),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                encrypted ? Icons.lock_outline : Icons.lock_open,
                size: 15,
                color: encrypted
                    ? const Color(0xFF63D18F)
                    : const Color(0xFFE8A33D),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFE9EDF1),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
