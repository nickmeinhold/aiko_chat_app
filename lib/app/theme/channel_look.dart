import 'dart:convert';

import 'package:flutter/material.dart';

import 'theme_builder.dart';
import 'theme_laws.dart';

/// A room may tint itself. It may not redecorate around you.
///
/// This is the CHANNEL tier of the scope cascade from claude-tasks#2715, where
/// authority narrows as it moves away from the reader:
///
///   you      → everything (any palette, any face, any role)
///   island   → a bounded band (not built yet; co-owned with aiko-chat-island)
///   channel  → ONE HUE
///
/// The narrowing is the design, not a simplification of it. A channel supplies
/// a single accent — the signal colour — and nothing else. It cannot touch the
/// ground, the ink, the hairline, or the alarm. That is what makes walking into
/// a room safe: the worst a channel can do to you is look wrong, never make a
/// control unreadable or hide the thing you came to press.
///
/// Resist the pull to model each tier as "a full palette at a smaller scope".
/// That would hand a channel operator the same power as the reader, which is
/// precisely the inversion the cascade exists to prevent.
///
/// THE READER ALWAYS WINS. A channel hue is applied on top of the reader's
/// resolved palette, and only if the result still satisfies the design language
/// ([checkPalette]). A hue that would break the reader's chosen look is dropped,
/// not negotiated. This is a preference surface, not a branding surface.
///
/// DEVICE-LOCAL, like theme mode and preset beside it. A channel tint is not
/// carried across islands the way identity is, and it is not part of the signed
/// record of anything.
@immutable
class ChannelLooks {
  const ChannelLooks(this.hues);

  /// channel id → the accent that channel wears.
  ///
  /// Keyed by the RAW channel id exactly as the server gives it. Note that
  /// `channels.id` is a bare ULID — a DM channel does NOT carry a `dm:` prefix
  /// on that column, and string-sniffing it to infer the channel's kind is a
  /// mistake this codebase has already made once (PR #139). Nothing here
  /// interprets the id; it is an opaque key.
  final Map<String, Color> hues;

  static const none = ChannelLooks({});

  Color? hueFor(String channelId) => hues[channelId];
  bool get isEmpty => hues.isEmpty;

  ChannelLooks set(String channelId, Color? hue) {
    final next = Map<String, Color>.from(hues);
    if (hue == null) {
      next.remove(channelId);
    } else {
      next[channelId] = hue;
    }
    return ChannelLooks(next);
  }

  /// The reader's palette, tinted for this channel — or unchanged.
  ///
  /// Returns [base] untouched when there is no tint, when the tint would break
  /// the design language, or when the channel is unknown. Callers therefore
  /// never have to handle "the channel made my app unusable"; that state cannot
  /// be represented.
  ThemePalette applyTo(ThemePalette base, String? channelId) {
    if (channelId == null) return base;
    final hue = hues[channelId];
    if (hue == null) return base;

    final tinted = withRole(base, PaletteRole.signal, hue);
    // The law is checked against the COMPOSED palette, not the hue in
    // isolation: the same accent can be fine on parchment and invisible on
    // sea-night, and the reader may have edited either.
    return checkPalette(tinted).isEmpty ? tinted : base;
  }

  /// Whether [hue] would actually take effect for a reader on [base]. The UI
  /// uses this to refuse an accent up front rather than accepting it and
  /// silently ignoring it — a setting that stores a value it will never honour
  /// is worse than one that says no.
  static bool isLawful(ThemePalette base, Color hue) =>
      checkPalette(withRole(base, PaletteRole.signal, hue)).isEmpty;

  // ---- Wire format ----------------------------------------------------------

  String encode() => jsonEncode({
        for (final e in hues.entries)
          e.key: '#${e.value.toARGB32().toRadixString(16).padLeft(8, '0')}',
      });

  /// Fail-soft in every direction: this is read at startup, and a device
  /// preference that can wedge the app at first frame is a bad trade for a tint.
  static ChannelLooks decode(String? raw) {
    if (raw == null || raw.isEmpty) return none;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return none;
      final out = <String, Color>{};
      json.forEach((k, v) {
        final parsed = int.tryParse('$v'.replaceFirst('#', ''), radix: 16);
        if (parsed != null) out['$k'] = Color(parsed);
      });
      return ChannelLooks(out);
    } on FormatException {
      return none;
    }
  }
}
