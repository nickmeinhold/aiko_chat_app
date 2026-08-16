// The design language, stated as relationships that hold in EVERY shipped theme.
//
// Why relationships and not colours: a test pinned to `#57C9D8` is a test that
// gets deleted the moment a second theme exists. A test pinned to "the armed
// lamp is more present than the resting lamp, whatever the theme" survives every
// palette anyone ever picks — including ones a user authors themselves. That is
// the whole point: these assertions are what will make user-chosen colour SAFE,
// so they are written against the theme, never against a specific palette.
//
// Adding a theme to [_shippedThemes] subjects it to every rule below. That list
// is the registry; when a palette record + builder eventually replace the
// hand-authored pair, these tests become the builder's property tests unchanged.
import 'package:aiko_chat_app/app/theme/maritime_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every theme the app can render. Both are held to the same law.
final _shippedThemes = <String, ThemeData>{
  'noon (light)': lightTheme(),
  'night (dark)': maritimeTheme(),
};

/// Composite [fg] (which may be translucent) over an opaque [bg].
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

/// WCAG relative-luminance contrast ratio between two OPAQUE colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Contrast of [fg] against [bg], compositing first so translucent inks are
/// measured as they are actually SEEN rather than as they are declared.
double _seen(Color fg, Color bg) => _contrast(_over(fg, bg), bg);

void main() {
  _shippedThemes.forEach((name, theme) {
    final s = theme.colorScheme;

    group('$name — text is readable on every ground it lands on', () {
      // WCAG AA body text. `onSurface` is the ink; it is drawn on the base
      // ground AND on every panel, so every pairing has to clear the bar — a
      // panel is not exempt just because it is a container.
      test('primary ink clears 4.5:1 on the base ground', () {
        expect(_seen(s.onSurface, s.surface), greaterThanOrEqualTo(4.5));
      });

      test('primary ink clears 4.5:1 on every panel', () {
        final panels = {
          'surfaceContainerLowest': s.surfaceContainerLowest,
          'surfaceContainerLow': s.surfaceContainerLow,
          'surfaceContainer': s.surfaceContainer,
          'surfaceContainerHigh': s.surfaceContainerHigh,
          'surfaceContainerHighest': s.surfaceContainerHighest,
          'primaryContainer': s.primaryContainer,
          'secondaryContainer': s.secondaryContainer,
        };
        panels.forEach((label, panel) {
          final ink = label.endsWith('Container') && label != 'surfaceContainer'
              ? (label == 'primaryContainer'
                  ? s.onPrimaryContainer
                  : s.onSecondaryContainer)
              : s.onSurface;
          expect(_seen(ink, panel), greaterThanOrEqualTo(4.5),
              reason: 'ink on $label is ${_seen(ink, panel).toStringAsFixed(2)}:1');
        });
      });

      test('secondary ink (timestamps, captions) clears 4.5:1 — it is small '
          'text, not decoration', () {
        expect(_seen(s.onSurfaceVariant, s.surface), greaterThanOrEqualTo(4.5));
      });

      test('a label on a filled accent clears 4.5:1', () {
        expect(_seen(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5),
            reason: 'onPrimary vs primary');
        expect(_seen(s.onSecondary, s.secondary), greaterThanOrEqualTo(4.5),
            reason: 'onSecondary vs secondary');
        expect(_seen(s.onError, s.error), greaterThanOrEqualTo(4.5),
            reason: 'onError vs error');
      });
    });

    group('$name — the accents still read as SIGNAL against their ground', () {
      // WCAG 1.4.11: a non-text UI component (a lit waterline, a send lamp, a
      // focus ring) needs 3:1 against what it sits on. This is the assertion
      // that kills "signal cyan on chart paper" — a highlighter fails it.
      test('signal (primary) clears 3:1 on the base ground', () {
        expect(_seen(s.primary, s.surface), greaterThanOrEqualTo(3.0));
      });

      test('beacon (secondary) clears 3:1 on the base ground', () {
        expect(_seen(s.secondary, s.surface), greaterThanOrEqualTo(3.0));
      });

      test('error clears 3:1 on the base ground', () {
        expect(_seen(s.error, s.surface), greaterThanOrEqualTo(3.0));
      });

      test('every pair of accents is distinguishable — near-hue neighbours must '
          'separate by LIGHTNESS', () {
        // The first cut of this test only checked signal-vs-beacon, and only by
        // hue. It passed a noon palette in which the beacon and the alarm were
        // two shades of one rust — caught by looking at the render, not by the
        // suite. The blind spot was structural: in the night palette those two
        // separate by lightness (bright amber vs mid red), so a hue-only rule
        // never had to do any work. At noon both accents become dark inks, the
        // lightness gap collapses, and hue alone is left holding a distinction
        // it cannot carry — least of all for a red-green colour-blind viewer,
        // for whom gold and red are the single worst pair in the palette.
        //
        // So: hues far apart (teal vs red) carry themselves. Hues within 60°
        // are near neighbours and must ALSO differ in luminance.
        final accents = {
          'signal': s.primary,
          'beacon': s.secondary,
          'alarm': s.error,
        };
        final names = accents.keys.toList();
        for (var i = 0; i < names.length; i++) {
          for (var j = i + 1; j < names.length; j++) {
            final a = accents[names[i]]!;
            final b = accents[names[j]]!;
            var dh = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
            if (dh > 180) dh = 360 - dh;
            final pair = '${names[i]} vs ${names[j]}';

            expect(dh, greaterThanOrEqualTo(25.0),
                reason: '$pair are ${dh.round()}° apart — the same colour '
                    'wearing two meanings');

            if (dh < 60.0) {
              final lum = _contrast(a, b);
              expect(lum, greaterThanOrEqualTo(1.4),
                  reason: '$pair are only ${dh.round()}° apart, so lightness '
                      'has to carry the distinction — and it is only '
                      '${lum.toStringAsFixed(2)}:1');
            }
          }
        }
      });
    });

    group('$name — emphasis ordering (the composer\'s law, generalised)', () {
      // The armed>rest relationship the waterline test locks for the composer,
      // stated once at the theme level so any future control inherits it.
      test('an ARMED mark is more present than a RESTING mark', () {
        final rest = _seen(s.outlineVariant, s.surface);
        final armed = _seen(s.secondary, s.surface);
        expect(armed, greaterThan(rest),
            reason: 'rest ${rest.toStringAsFixed(2)}:1, '
                'armed ${armed.toStringAsFixed(2)}:1');
      });

      test('a hairline is SEEN but never shouts — quieter than the ink', () {
        final hairline = _seen(s.outline, s.surface);
        final ink = _seen(s.onSurface, s.surface);
        expect(hairline, greaterThan(1.15),
            reason: 'an invisible hairline is not separation '
                '(${hairline.toStringAsFixed(2)}:1)');
        expect(hairline, lessThan(ink),
            reason: 'a hairline louder than the text is a border, and this '
                'design removed borders');
      });

      test('every panel is distinguishable from the ground it sits on', () {
        for (final panel in [
          s.surfaceContainerLow,
          s.surfaceContainer,
          s.surfaceContainerHigh,
        ]) {
          expect(_contrast(panel, s.surface), greaterThan(1.03),
              reason: 'a panel that matches the ground is not a panel');
        }
      });
    });

    group('$name — separation is by hairline, NEVER by elevation', () {
      // The dark theme's stated law. It was never enforced, which is exactly
      // how the light theme kept Material's default shadows and surface tints
      // for four months without anyone noticing.
      test('the theme casts no shadow', () {
        expect(theme.shadowColor.a, 0.0,
            reason: 'shadowColor is ${theme.shadowColor}');
        expect(s.shadow.a, 0.0, reason: 'colorScheme.shadow is ${s.shadow}');
      });

      test('the app bar is flat, scrolled or not', () {
        expect(theme.appBarTheme.elevation, 0);
        expect(theme.appBarTheme.scrolledUnderElevation, 0);
      });

      test('surfaces are not tinted by elevation', () {
        expect(theme.cardTheme.surfaceTintColor?.a, 0.0,
            reason: 'card surfaceTint is ${theme.cardTheme.surfaceTintColor}');
        expect(theme.dialogTheme.surfaceTintColor?.a, 0.0,
            reason: 'dialog surfaceTint is '
                '${theme.dialogTheme.surfaceTintColor}');
        expect(theme.popupMenuTheme.surfaceTintColor?.a, 0.0,
            reason: 'menu surfaceTint is '
                '${theme.popupMenuTheme.surfaceTintColor}');
      });

      test('panels do not float', () {
        expect(theme.cardTheme.elevation, 0);
        expect(theme.dialogTheme.elevation, 0);
        expect(theme.popupMenuTheme.elevation, 0);
        expect(theme.bottomSheetTheme.elevation, 0);
        expect(theme.floatingActionButtonTheme.elevation, 0);
      });

      test('the divider is the hairline', () {
        expect(theme.dividerTheme.color, s.outline);
        expect(theme.dividerTheme.thickness, 1);
      });
    });

    group('$name — the theme is authored, not generated', () {
      // The defect this whole suite exists to catch: a four-line
      // `ColorScheme.fromSeed` wearing the app's name. A generated scheme has
      // no component subthemes, so the absence of them IS the tell.
      test('it carries a hand-authored text theme', () {
        expect(theme.textTheme.bodyMedium?.color, isNotNull,
            reason: 'no explicit ink — the TextTheme was never authored');
      });

      test('it dresses the input, the list tile and the chrome', () {
        expect(theme.inputDecorationTheme.enabledBorder, isNotNull,
            reason: 'the input decoration was never authored');
        expect(theme.listTileTheme.textColor, isNotNull,
            reason: 'the list tile was never authored');
        expect(theme.appBarTheme.backgroundColor, isNotNull,
            reason: 'the app bar was never authored');
      });
    });
  });
}
