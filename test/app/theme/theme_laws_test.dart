// The law engine the EDITOR runs, held to the same standard as the law the
// TEST SUITE runs — and cross-checked against it.
//
// `theme_relationships_test.dart` computes every ratio itself, independently.
// `lib/app/theme/theme_laws.dart` computes them again so the editor can consult
// the law while a reader is picking colours. Two implementations of one rule is
// a liability unless something forces them to agree, so the first group below
// forces it: every shipped palette must be judged legal by the engine, and the
// relationships test independently proves the same palettes legal. If either
// drifts, one of the two suites goes red.
//
// The rest of this file is the part that actually matters for user-authored
// colour: proving the engine says NO. A validator that has never rejected
// anything is indistinguishable from `return []`.
import 'package:aiko_chat_app/app/theme/maritime_theme.dart';
import 'package:aiko_chat_app/app/theme/theme_builder.dart';
import 'package:aiko_chat_app/app/theme/theme_laws.dart';
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A deliberately awful palette: mid-grey everything. Nothing is readable,
/// nothing separates, no accent is distinguishable from another.
const _mud = ThemePalette(
  brightness: Brightness.light,
  ground: Color(0xFF808080),
  panel: Color(0xFF828282),
  panelHigh: Color(0xFF818181),
  panelMine: Color(0xFF838383),
  ink: Color(0xFF888888),
  inkDim: Color(0xFF8A8A8A),
  hairline: Color(0xFF858585),
  signal: Color(0xFF8B8B8B),
  beacon: Color(0xFF8C8C8C),
  alarm: Color(0xFF8D8D8D),
  onAccent: Color(0xFF8E8E8E),
);

void main() {
  group('the engine agrees with the shipped palettes', () {
    test('every preset, in both brightnesses, is judged legal', () {
      for (final preset in kThemePresets) {
        expect(
          checkPalette(preset.light),
          isEmpty,
          reason: '${preset.id} light: ${checkPalette(preset.light)}',
        );
        expect(
          checkPalette(preset.dark),
          isEmpty,
          reason: '${preset.id} dark: ${checkPalette(preset.dark)}',
        );
      }
    });
  });

  group('the engine says NO — a validator that never rejects is not one', () {
    test('mud fails, and fails LOUDLY rather than on one technicality', () {
      final broken = checkPalette(_mud);
      expect(broken, isNotEmpty);
      // It should object on many grounds at once; a single complaint would
      // suggest the other rules never ran.
      expect(broken.length, greaterThan(4), reason: '$broken');
    });

    test('unreadable body text is caught', () {
      final p = withRole(
        maritimeNoon,
        PaletteRole.ink,
        const Color(0xFFE4DDCC),
      );
      expect(
        checkPalette(p).where((v) => v.role == PaletteRole.ink),
        isNotEmpty,
      );
    });

    test('an accent that vanishes into the ground is caught — this is the rule '
        'that kills "signal cyan on chart paper"', () {
      final p = withRole(
        maritimeNoon,
        PaletteRole.signal,
        const Color(0xFF7FE0A8),
      );
      expect(
        checkPalette(p).where((v) => v.role == PaletteRole.signal),
        isNotEmpty,
      );
    });

    test(
      'two accents that are the same colour wearing two meanings are caught',
      () {
        // The beacon moved onto the alarm's hue.
        final p = withRole(
          maritimeNoon,
          PaletteRole.beacon,
          const Color(0xFF8C2318),
        );
        expect(checkPalette(p), isNotEmpty);
      },
    );

    test('a RELATIONAL violation is reported against one of the two colours, '
        'not necessarily the one that moved', () {
      // This is a property callers must respect, and it caused a real bug: the
      // editor originally asked "does any violation name the role I am
      // editing?" and so judged this exact palette legal, offering a beacon
      // that collides with the alarm. Moving the beacon is blamed on the ALARM
      // because the pair is checked as (beacon, alarm). Any consumer deciding
      // whether an EDIT is safe must therefore ask "is the palette clean?",
      // never "is my role blamed?".
      final p = withRole(
        maritimeNoon,
        PaletteRole.beacon,
        const Color(0xFF8C2318),
      );
      final blamed = checkPalette(p).map((v) => v.role).toSet();
      expect(blamed, contains(PaletteRole.alarm));
      expect(
        blamed,
        isNot(contains(PaletteRole.beacon)),
        reason:
            'if this ever starts blaming the beacon too, the property '
            'above got stronger — relax this expectation, but do NOT let the '
            'editor go back to filtering by role',
      );
    });

    test('an invisible hairline is caught — it is the only separator this '
        'design has', () {
      final p = withRole(
        maritimeNoon,
        PaletteRole.hairline,
        const Color(0xFFE7E0CF),
      );
      expect(
        checkPalette(p).where((v) => v.role == PaletteRole.hairline),
        isNotEmpty,
      );
    });

    test('a hairline LOUDER than the ink is caught too — the failure is '
        'two-sided, not just "more contrast is better"', () {
      final p = withRole(
        maritimeNoon,
        PaletteRole.hairline,
        const Color(0xFF000000),
      );
      expect(
        checkPalette(p).where((v) => v.role == PaletteRole.hairline),
        isNotEmpty,
      );
    });

    test('a panel that matches the ground is caught', () {
      final p = withRole(maritimeNoon, PaletteRole.panel, maritimeNoon.ground);
      expect(
        checkPalette(p).where((v) => v.role == PaletteRole.panel),
        isNotEmpty,
      );
    });

    test(
      'every violation names a role, so the editor can point at something',
      () {
        for (final v in checkPalette(_mud)) {
          expect(v.message, isNotEmpty);
          expect(
            v.message,
            isNot(contains(':1')),
            reason:
                'messages are for people — "contrast 3.2:1" is not '
                'actionable, "this text is too faint" is',
          );
        }
      },
    );
  });

  group('withRole/roleOf are exact inverses', () {
    test('setting a role then reading it back returns what was set', () {
      for (final role in PaletteRole.values) {
        const c = Color(0xFF123456);
        expect(
          roleOf(withRole(maritimeNoon, role, c), role),
          c,
          reason: role.name,
        );
      }
    });

    test('setting one role changes NOTHING else — an editor that silently '
        'moved a second colour would be unfixable by hand', () {
      for (final role in PaletteRole.values) {
        final edited = withRole(maritimeNoon, role, const Color(0xFF123456));
        for (final other in PaletteRole.values) {
          if (other == role) continue;
          expect(
            roleOf(edited, other),
            roleOf(maritimeNoon, other),
            reason: 'editing ${role.name} moved ${other.name}',
          );
        }
      }
    });
  });
}
