import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_fonts.dart';
import 'theme_builder.dart';
import 'theme_laws.dart';
import 'theme_presets.dart';

/// What a reader has chosen: a preset, plus whatever they changed about it.
///
/// The stored value is a preset ID and a SPARSE map of overridden roles — never
/// a resolved [ThemePalette]. That distinction is the whole point: store the
/// resolved thing and a reader is frozen on a copy of whatever the preset
/// looked like the day they touched it, so every later improvement to Maritime
/// silently stops reaching the people who liked Maritime enough to tweak it.
/// Store the delta and their one changed accent rides on top of a preset that
/// keeps getting better.
@immutable
class SkinSelection {
  const SkinSelection({
    required this.presetId,
    this.fontId = kDefaultFontId,
    this.lightOverrides = const {},
    this.darkOverrides = const {},
  });

  final String presetId;

  /// The chosen BODY typeface. Orthogonal to the palette: a face is not part of
  /// a preset, so switching preset keeps your font and vice versa. They are two
  /// independent preferences that happen to share a settings page.
  final String fontId;
  final Map<PaletteRole, Color> lightOverrides;
  final Map<PaletteRole, Color> darkOverrides;

  static const none = SkinSelection(presetId: kDefaultPresetId);

  bool get isCustomised =>
      lightOverrides.isNotEmpty || darkOverrides.isNotEmpty;

  AppFont get font => fontById(fontId);

  SkinSelection withFont(String id) => SkinSelection(
    presetId: presetId,
    fontId: id,
    lightOverrides: lightOverrides,
    darkOverrides: darkOverrides,
  );

  SkinSelection withOverride({
    required Brightness brightness,
    required PaletteRole role,
    required Color? colour,
  }) {
    Map<PaletteRole, Color> edit(Map<PaletteRole, Color> m) {
      final next = Map<PaletteRole, Color>.from(m);
      if (colour == null) {
        next.remove(role); // reverting one role to the preset's own value
      } else {
        next[role] = colour;
      }
      return next;
    }

    return brightness == Brightness.light
        ? SkinSelection(
            presetId: presetId,
            fontId: fontId,
            lightOverrides: edit(lightOverrides),
            darkOverrides: darkOverrides,
          )
        : SkinSelection(
            presetId: presetId,
            fontId: fontId,
            lightOverrides: lightOverrides,
            darkOverrides: edit(darkOverrides),
          );
  }

  /// Switching preset ABANDONS the overrides. They were deltas against a
  /// different set of base colours; carrying them onto a new preset would apply
  /// a tweak that made sense on parchment to a palette drawn on prussian blue.
  SkinSelection withPreset(String id) =>
      SkinSelection(presetId: id, fontId: fontId);

  /// Drop every colour edit, keeping the preset AND the font — the font was
  /// never a colour edit, so "reset colours" must not silently take it away.
  SkinSelection get reset => SkinSelection(presetId: presetId, fontId: fontId);

  /// The preset as this reader actually sees it.
  ThemePreset resolve() {
    final base = presetById(presetId);
    if (!isCustomised) return base;
    return ThemePreset(
      id: base.id,
      label: base.label,
      blurb: base.blurb,
      light: _apply(base.light, lightOverrides),
      dark: _apply(base.dark, darkOverrides),
    );
  }

  /// Apply [overrides] to [base], DROPPING any that would break the design
  /// language.
  ///
  /// The editor already refuses to save an illegal colour, so this is not the
  /// primary gate — it is the gate for when WE move the ground under a stored
  /// edit. If a later build revises Maritime's ground, an override that was
  /// legal against the old one can become unreadable against the new one, and
  /// the reader is not present to be asked. A readable app beats a remembered
  /// preference, so the offending role falls back to the preset's own value —
  /// one role, not the whole edit.
  ///
  /// Terminates: every pass removes exactly one override and [base] is itself
  /// known-legal (`theme_relationships_test.dart` proves it), so the worst case
  /// is discarding all of them.
  static ThemePalette _apply(
    ThemePalette base,
    Map<PaletteRole, Color> overrides,
  ) {
    var kept = Map<PaletteRole, Color>.from(overrides);
    while (true) {
      var palette = base;
      kept.forEach((role, colour) {
        palette = withRole(palette, role, colour);
      });
      final broken = checkPalette(palette);
      if (broken.isEmpty || kept.isEmpty) return palette;

      // Prefer dropping a role the reader actually overrode; a violation can
      // name a role they never touched (their new ground broke the dim ink),
      // in which case drop any override and re-check rather than spin.
      final blame = broken
          .map((b) => b.role)
          .firstWhere(kept.containsKey, orElse: () => kept.keys.first);
      kept.remove(blame);
    }
  }

  // ---- Wire format ----------------------------------------------------------

  Map<String, dynamic> toJson() => {
    'preset': presetId,
    if (fontId != kDefaultFontId) 'font': fontId,
    if (lightOverrides.isNotEmpty) 'light': _encode(lightOverrides),
    if (darkOverrides.isNotEmpty) 'dark': _encode(darkOverrides),
  };

  String encode() => jsonEncode(toJson());

  static Map<String, String> _encode(Map<PaletteRole, Color> m) => {
    for (final e in m.entries)
      e.key.name: '#${e.value.toARGB32().toRadixString(16).padLeft(8, '0')}',
  };

  static Map<PaletteRole, Color> _decode(Object? raw) {
    if (raw is! Map) return const {};
    final out = <PaletteRole, Color>{};
    raw.forEach((k, val) {
      final role = PaletteRole.values
          .where((r) => r.name == k)
          .firstOrNull; // an unknown role name is a newer build's — ignore it
      final parsed = int.tryParse('$val'.replaceFirst('#', ''), radix: 16);
      if (role != null && parsed != null) out[role] = Color(parsed);
    });
    return out;
  }

  /// Read a stored value, FAIL-SOFT in every direction.
  ///
  /// Handles three shapes because all three exist in the wild:
  ///   - null / garbage        → the default look;
  ///   - a bare preset id      → what shipped in PR #143, before overrides
  ///                             existed. Readers on that build have this
  ///                             stored RIGHT NOW; it must keep working;
  ///   - the JSON object       → current.
  ///
  /// A partially-unreadable JSON value degrades to whatever parts made sense
  /// rather than throwing: this runs at first frame, before any UI exists to
  /// report an error, so there is nothing useful a throw could accomplish.
  static SkinSelection decode(String? raw) {
    if (raw == null || raw.isEmpty) return none;

    if (!raw.trimLeft().startsWith('{')) {
      // Legacy bare id. presetById is itself fail-soft on an unknown one.
      return SkinSelection(presetId: presetById(raw).id);
    }

    try {
      final json = jsonDecode(raw);
      if (json is! Map) return none;
      return SkinSelection(
        presetId: presetById(json['preset'] as String?).id,
        fontId: fontById(json['font'] as String?).id,
        lightOverrides: _decode(json['light']),
        darkOverrides: _decode(json['dark']),
      );
    } on FormatException {
      return none;
    }
  }
}
