import 'package:flutter/material.dart';

import 'theme_builder.dart';

/// The design language, stated as code the APP can run — not only the test suite.
///
/// `test/app/theme/theme_relationships_test.dart` has always held every shipped
/// theme to these rules. That was enough while every palette was authored here:
/// a bad palette failed CI and never reached a reader. The moment a READER can
/// author one, CI is the wrong place for the law — the person picking the
/// colours needs the answer while they are picking, and there is no build to
/// fail.
///
/// So the law lives here, and the editor and the test BOTH call it. They do not,
/// however, share an implementation: the test keeps its own independent
/// computation of every ratio and additionally asserts this engine agrees with
/// it, on every shipped palette. Two implementations that must agree is a real
/// cross-check; one implementation checking itself is a mirror. If these ever
/// drift, the suite fails and says so.
///
/// SCOPE, restated because it is easy to over-claim: these are COLOUR AND
/// CONTRAST laws. They guarantee that no palette can make a control invisible
/// against what it sits on. They say nothing about layout (claude-tasks#2715).

/// The twelve slots a palette fills. Named so the editor can point at the one
/// that broke a law instead of saying "this palette is invalid".
enum PaletteRole {
  ground('Ground', 'the base surface everything sits on'),
  panel('Panel', "others' bubbles, the sidebar, cards"),
  panelHigh('Raised panel', 'menus, sheets, tooltips'),
  panelMine('My bubble', 'your own messages'),
  ink('Ink', 'body text'),
  inkDim('Dim ink', 'timestamps, captions, unselected icons'),
  hairline('Hairline', 'panel edges and dividers — the only separator'),
  signal('Signal', 'links, focus, the lit waterline'),
  beacon('Beacon', 'the send lamp, highlights'),
  alarm('Alarm', 'errors'),
  onAccent('On accent', 'labels drawn on signal, beacon and alarm');

  const PaletteRole(this.label, this.blurb);
  final String label;
  final String blurb;
}

/// One broken rule, aimed at the role a reader would have to change to fix it.
@immutable
class ThemeLawViolation {
  const ThemeLawViolation({
    required this.role,
    required this.message,
  });

  /// The role to highlight in the editor. A contrast failure always involves
  /// two colours; this names the one the reader most likely just changed —
  /// the FOREGROUND, since a ground change breaks many rules at once and the
  /// per-rule message carries the other half.
  final PaletteRole role;

  /// A sentence a person can act on. Never "contrast ratio 3.2 < 4.5".
  final String message;

  @override
  String toString() => '${role.label}: $message';
}

/// Composite [fg] (which may be translucent) over an opaque [bg].
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

/// WCAG relative-luminance contrast ratio between two OPAQUE colours.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Contrast of [fg] against [bg], compositing first so a translucent ink is
/// measured as it is actually SEEN rather than as it is declared.
double seenContrast(Color fg, Color bg) =>
    contrastRatio(_over(fg, bg), bg);

/// Smallest angle between two hues, in degrees (0–180).
double hueGap(Color a, Color b) {
  var d = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
  if (d > 180) d = 360 - d;
  return d;
}

/// Every way [p] breaks the design language. Empty means the palette is
/// legitimate — not that it is beautiful.
///
/// Ordered roughly by how badly the result would read, so an editor showing
/// only the first violation still shows the worst one.
List<ThemeLawViolation> checkPalette(ThemePalette p) {
  final v = <ThemeLawViolation>[];

  // ---- Text has to be readable on every ground it lands on. WCAG AA body. ----
  if (seenContrast(p.ink, p.ground) < 4.5) {
    v.add(const ThemeLawViolation(
      role: PaletteRole.ink,
      message: 'Body text is too close to the background to read.',
    ));
  }

  const panelRoles = {
    PaletteRole.panel: 'panels',
    PaletteRole.panelHigh: 'menus and sheets',
    PaletteRole.panelMine: 'your own messages',
  };
  panelRoles.forEach((role, where) {
    final panel = switch (role) {
      PaletteRole.panel => p.panel,
      PaletteRole.panelHigh => p.panelHigh,
      _ => p.panelMine,
    };
    // A panel is not exempt from the reading bar just because it is a container.
    if (seenContrast(p.ink, panel) < 4.5) {
      v.add(ThemeLawViolation(
        role: role,
        message: 'Body text would be hard to read on $where.',
      ));
    }
  });

  if (seenContrast(p.inkDim, p.ground) < 4.5) {
    v.add(const ThemeLawViolation(
      role: PaletteRole.inkDim,
      message: 'Timestamps and captions are too faint. They are small text, '
          'not decoration.',
    ));
  }

  // A label drawn ON a filled accent — the Send button's own text.
  const accentFills = {
    PaletteRole.signal: 'the signal colour',
    PaletteRole.beacon: 'the beacon',
    PaletteRole.alarm: 'the alarm colour',
  };
  accentFills.forEach((role, name) {
    final fill = switch (role) {
      PaletteRole.signal => p.signal,
      PaletteRole.beacon => p.beacon,
      _ => p.alarm,
    };
    if (seenContrast(p.onAccent, fill) < 4.5) {
      v.add(ThemeLawViolation(
        role: PaletteRole.onAccent,
        message: 'Button labels would be unreadable on $name.',
      ));
    }
  });

  // ---- The accents must still read as SIGNAL. WCAG 1.4.11, non-text UI. ----
  // This is the rule that kills "signal cyan on chart paper": a highlighter
  // fails it. 3:1 against the ground it sits on.
  accentFills.forEach((role, name) {
    final accent = switch (role) {
      PaletteRole.signal => p.signal,
      PaletteRole.beacon => p.beacon,
      _ => p.alarm,
    };
    if (seenContrast(accent, p.ground) < 3.0) {
      v.add(ThemeLawViolation(
        role: role,
        message: 'This colour disappears into the background — a control '
            'painted in it would be invisible.',
      ));
    }
  });

  // ---- Two accents must never be the same colour wearing two meanings. ----
  // Hues far apart carry themselves. Near neighbours must ALSO differ in
  // lightness — at noon the beacon and the alarm both become dark inks and hue
  // alone cannot hold a distinction, least of all for a red-green colour-blind
  // reader, for whom gold and red are the worst pair in the palette.
  const pairs = [
    (PaletteRole.signal, PaletteRole.beacon),
    (PaletteRole.signal, PaletteRole.alarm),
    (PaletteRole.beacon, PaletteRole.alarm),
  ];
  Color colourOf(PaletteRole r) => switch (r) {
        PaletteRole.signal => p.signal,
        PaletteRole.beacon => p.beacon,
        _ => p.alarm,
      };
  for (final (a, b) in pairs) {
    final ca = colourOf(a);
    final cb = colourOf(b);
    final gap = hueGap(ca, cb);
    if (gap < 25.0) {
      v.add(ThemeLawViolation(
        role: b,
        message: 'Too close to the ${a.label.toLowerCase()} — two different '
            'meanings would look like one colour.',
      ));
    } else if (gap < 60.0 && contrastRatio(ca, cb) < 1.4) {
      v.add(ThemeLawViolation(
        role: b,
        message: 'Nearly the same shade as the ${a.label.toLowerCase()}. '
            'Make it lighter or darker so the two can be told apart without '
            'relying on colour vision.',
      ));
    }
  }

  // ---- Emphasis ordering: an ARMED mark outranks a RESTING one. ----
  if (seenContrast(p.beacon, p.ground) <= seenContrast(p.hairline, p.ground)) {
    v.add(const ThemeLawViolation(
      role: PaletteRole.beacon,
      message: 'The beacon is quieter than a hairline, so an armed control '
          'would look less active than an idle one.',
    ));
  }

  // ---- A hairline is SEEN but never shouts. ----
  final hair = seenContrast(p.hairline, p.ground);
  if (hair <= 1.15) {
    v.add(const ThemeLawViolation(
      role: PaletteRole.hairline,
      message: 'This hairline is invisible, and an invisible hairline is not '
          'separation — it is the only separator this design has.',
    ));
  } else if (hair >= seenContrast(p.ink, p.ground)) {
    v.add(const ThemeLawViolation(
      role: PaletteRole.hairline,
      message: 'A hairline louder than the text is a border, and this design '
          'removed borders.',
    ));
  }

  // ---- A panel that matches the ground is not a panel. ----
  const liftRoles = {
    PaletteRole.panel: 'Panels',
    PaletteRole.panelHigh: 'Menus and sheets',
  };
  liftRoles.forEach((role, what) {
    final panel = role == PaletteRole.panel ? p.panel : p.panelHigh;
    if (contrastRatio(panel, p.ground) <= 1.03) {
      v.add(ThemeLawViolation(
        role: role,
        message: '$what would vanish into the background instead of lifting '
            'off it.',
      ));
    }
  });

  return v;
}

/// [p] with one role replaced — how the editor asks "would this colour be legal
/// here?" without mutating anything.
ThemePalette withRole(ThemePalette p, PaletteRole role, Color c) =>
    ThemePalette(
      brightness: p.brightness,
      ground: role == PaletteRole.ground ? c : p.ground,
      panel: role == PaletteRole.panel ? c : p.panel,
      panelHigh: role == PaletteRole.panelHigh ? c : p.panelHigh,
      panelMine: role == PaletteRole.panelMine ? c : p.panelMine,
      ink: role == PaletteRole.ink ? c : p.ink,
      inkDim: role == PaletteRole.inkDim ? c : p.inkDim,
      hairline: role == PaletteRole.hairline ? c : p.hairline,
      signal: role == PaletteRole.signal ? c : p.signal,
      beacon: role == PaletteRole.beacon ? c : p.beacon,
      alarm: role == PaletteRole.alarm ? c : p.alarm,
      onAccent: role == PaletteRole.onAccent ? c : p.onAccent,
    );

/// Read one role out of a palette.
Color roleOf(ThemePalette p, PaletteRole role) => switch (role) {
      PaletteRole.ground => p.ground,
      PaletteRole.panel => p.panel,
      PaletteRole.panelHigh => p.panelHigh,
      PaletteRole.panelMine => p.panelMine,
      PaletteRole.ink => p.ink,
      PaletteRole.inkDim => p.inkDim,
      PaletteRole.hairline => p.hairline,
      PaletteRole.signal => p.signal,
      PaletteRole.beacon => p.beacon,
      PaletteRole.alarm => p.alarm,
      PaletteRole.onAccent => p.onAccent,
    };
