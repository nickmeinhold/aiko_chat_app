// The disclosure, as a thing you can see rather than a thing you must dismiss.
//
// Nick chose an always-visible indicator over a confirmation sheet: no
// interruption, ever. That choice puts the whole weight of Decision 9d on this
// widget being LEGIBLE, because nothing forces the user to look at it — so it
// says what it means in words ("Not encrypted"), names who can listen, and does
// not rely on a padlock glyph being read correctly by someone who has seen a
// thousand padlocks.
//
// WHERE IT IS SHOWN, and why that satisfies "before connect":
//   * the RING banner, so a callee reads it while deciding whether to answer;
//   * the CALL screen from its first frame, which is the `connecting` state and
//     therefore precedes any media.
// An indicator that only appeared once a call was up would land after the thing
// it discloses, which is the one way this choice could have missed the ruling.
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
  const MediaConfidentialityChip({super.key, this.compact = false});

  /// Drop the island host, for a surface too narrow to carry it (the ring
  /// banner already names the caller and two buttons). The CLAIM never
  /// shortens — only the attribution does.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routing = ref.watch(mediaRoutingProvider);
    final encrypted = routing.isEndToEndEncrypted;

    // The claim always renders. The island name is an addition to it, never a
    // precondition for it — `compact` drops it for space, and an unknown host
    // drops it for ignorance, and neither is allowed to soften the claim.
    final attributed = !compact && routing.hasAttribution;
    final label = encrypted
        ? 'End-to-end encrypted'
        : attributed
        ? 'Not encrypted · ${routing.islandHost}'
        : 'Not encrypted';

    return Semantics(
      // The screen reader gets the FULL sentence even when the visible chip is
      // compact: the reason to shorten is horizontal space, which costs a
      // listener nothing.
      label: encrypted
          ? 'This call is end to end encrypted.'
          : routing.hasAttribution
          ? 'This call is not encrypted. Audio and video pass through '
                '${routing.islandHost} in the clear.'
          // Named vaguely because it is not known, not to be gentle about it.
          : 'This call is not encrypted. Audio and video pass through this '
                'island in the clear.',
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
