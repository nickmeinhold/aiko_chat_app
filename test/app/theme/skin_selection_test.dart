// What a reader's saved edits are, and what happens to them when the world
// moves underneath.
//
// The two properties worth the most here:
//   1. SPARSE, not resolved — a reader who tweaked one accent still receives
//      every later improvement to the preset they tweaked.
//   2. SELF-HEALING — if a later build revises a preset's base colours and a
//      stored edit becomes unreadable against the new ground, that ONE role
//      falls back rather than the reader getting an unusable app or losing all
//      of their work.
import 'package:aiko_chat_app/app/theme/skin_selection.dart';
import 'package:aiko_chat_app/app/theme/theme_laws.dart';
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _legalTeal = Color(0xFF0B5F6C); // maritime noon's own signal — safe
const _illegalMint = Color(0xFF7FE0A8); // a highlighter on chart paper

void main() {
  group('round-trips through storage', () {
    test('a bare preset, encoded and decoded, is unchanged', () {
      const s = SkinSelection(presetId: 'blueprint');
      final back = SkinSelection.decode(s.encode());
      expect(back.presetId, 'blueprint');
      expect(back.isCustomised, isFalse);
    });

    test('overrides survive the round trip, per brightness', () {
      const s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {PaletteRole.signal: _legalTeal},
        darkOverrides: {PaletteRole.beacon: Color(0xFFF0B649)},
      );
      final back = SkinSelection.decode(s.encode());
      expect(back.lightOverrides[PaletteRole.signal]?.toARGB32(),
          _legalTeal.toARGB32());
      expect(back.darkOverrides[PaletteRole.beacon]?.toARGB32(),
          const Color(0xFFF0B649).toARGB32());
      expect(back.lightOverrides.containsKey(PaletteRole.beacon), isFalse,
          reason: 'a light edit must not leak into dark');
    });
  });

  group('decode is fail-soft in every direction', () {
    test('null and empty give the default look', () {
      expect(SkinSelection.decode(null).presetId, kDefaultPresetId);
      expect(SkinSelection.decode('').presetId, kDefaultPresetId);
    });

    test('a LEGACY bare id still works — this shape is on real devices right '
        'now, written by PR #143', () {
      expect(SkinSelection.decode('radar').presetId, 'radar');
      expect(SkinSelection.decode('radar').isCustomised, isFalse);
    });

    test('an unknown bare id falls back rather than throwing', () {
      expect(SkinSelection.decode('atlantis').presetId, kDefaultPresetId);
    });

    test('malformed JSON falls back rather than throwing — this runs at first '
        'frame, before any UI exists to report an error', () {
      expect(SkinSelection.decode('{not json').presetId, kDefaultPresetId);
      expect(SkinSelection.decode('{}').presetId, kDefaultPresetId);
      expect(SkinSelection.decode('[]').presetId, kDefaultPresetId);
    });

    test('an unknown ROLE name from a newer build is ignored, not fatal', () {
      const raw = '{"preset":"maritime","light":{"chartreuse":"#ff00ff00"}}';
      final s = SkinSelection.decode(raw);
      expect(s.presetId, 'maritime');
      expect(s.lightOverrides, isEmpty);
    });

    test('a garbage colour value is dropped, keeping the rest', () {
      const raw =
          '{"preset":"maritime","light":{"signal":"not-a-colour","beacon":"#ff8f6210"}}';
      final s = SkinSelection.decode(raw);
      expect(s.lightOverrides.containsKey(PaletteRole.signal), isFalse);
      expect(s.lightOverrides.containsKey(PaletteRole.beacon), isTrue);
    });
  });

  group('resolve() applies edits on top of a LIVE preset', () {
    test('an override actually reaches the palette', () {
      const s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {PaletteRole.signal: _legalTeal},
      );
      expect(s.resolve().light.signal.toARGB32(), _legalTeal.toARGB32());
    });

    test('untouched roles come from the preset, not a frozen copy', () {
      const s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {PaletteRole.signal: _legalTeal},
      );
      final resolved = s.resolve().light;
      final base = presetById('maritime').light;
      expect(resolved.ground, base.ground);
      expect(resolved.beacon, base.beacon);
    });

    test('the resolved palette is STILL legal — the whole point', () {
      const s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {PaletteRole.signal: _legalTeal},
      );
      expect(checkPalette(s.resolve().light), isEmpty);
    });

    test('identity is preserved: id, label and blurb survive customisation', () {
      const s = SkinSelection(
        presetId: 'blueprint',
        lightOverrides: {PaletteRole.signal: _legalTeal},
      );
      expect(s.resolve().id, 'blueprint');
      expect(s.resolve().label, presetById('blueprint').label);
    });
  });

  group('SELF-HEALING — an edit that became illegal drops, alone', () {
    test('an unreadable stored override is discarded rather than applied', () {
      const s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {PaletteRole.signal: _illegalMint},
      );
      final resolved = s.resolve().light;
      expect(resolved.signal, presetById('maritime').light.signal,
          reason: 'the illegal edit should have fallen back to the preset');
      expect(checkPalette(resolved), isEmpty,
          reason: 'a reader must never be handed an unreadable app');
    });

    test('a GOOD edit beside a bad one SURVIVES — losing all of someone\'s '
        'work because one colour went stale is the cheap wrong fix', () {
      // NOTE on the fixture: the first draft of this test used a "slightly
      // darker brass" for the beacon, assuming it was obviously fine. The law
      // rejected it — at 1.11:1 it collided with the alarm in luminance, under
      // the 1.4 the near-hue rule demands. The author picking a plausible bad
      // colour by eye is exactly the case this whole mechanism exists for, so
      // the fixture moved to a role with a wider legal band rather than the
      // rule being loosened.
      const paleWash = Color(0xFFDCE9E8);
      const s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {
          PaletteRole.signal: _illegalMint, // must drop
          PaletteRole.panelMine: paleWash, // legal — must survive
        },
      );
      final resolved = s.resolve().light;
      expect(resolved.signal, presetById('maritime').light.signal);
      expect(resolved.panelMine.toARGB32(), paleWash.toARGB32());
      expect(checkPalette(resolved), isEmpty);
    });

    test('even an all-garbage override set terminates and yields the preset',
        () {
      const junk = Color(0xFF808080);
      final s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {for (final r in PaletteRole.values) r: junk},
      );
      final resolved = s.resolve().light;
      expect(checkPalette(resolved), isEmpty);
      expect(resolved.ground, presetById('maritime').light.ground);
    });
  });

  group('editing operations', () {
    test('setting a role records it; passing null REMOVES it rather than '
        'storing the preset colour as an edit', () {
      var s = SkinSelection.none.withOverride(
        brightness: Brightness.light,
        role: PaletteRole.signal,
        colour: _legalTeal,
      );
      expect(s.lightOverrides.containsKey(PaletteRole.signal), isTrue);

      s = s.withOverride(
        brightness: Brightness.light,
        role: PaletteRole.signal,
        colour: null,
      );
      expect(s.lightOverrides.containsKey(PaletteRole.signal), isFalse,
          reason: 'a revert must delete the delta — storing the preset\'s own '
              'colour would freeze it against future revisions');
      expect(s.isCustomised, isFalse);
    });

    test('switching preset ABANDONS overrides — they were deltas against '
        'different base colours', () {
      const s = SkinSelection(
        presetId: 'maritime',
        lightOverrides: {PaletteRole.signal: _legalTeal},
      );
      expect(s.withPreset('blueprint').isCustomised, isFalse);
      expect(s.withPreset('blueprint').presetId, 'blueprint');
    });

    test('reset clears every edit but KEEPS the preset', () {
      const s = SkinSelection(
        presetId: 'radar',
        lightOverrides: {PaletteRole.signal: _legalTeal},
        darkOverrides: {PaletteRole.beacon: _legalTeal},
      );
      expect(s.reset.presetId, 'radar');
      expect(s.reset.isCustomised, isFalse);
      expect(s.reset.lightOverrides, isEmpty);
      expect(s.reset.darkOverrides, isEmpty);
    });
  });
}
