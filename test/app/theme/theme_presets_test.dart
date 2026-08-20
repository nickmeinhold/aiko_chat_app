// The preset REGISTRY and the stored choice.
//
// `theme_relationships_test.dart` proves every preset is a legitimate LOOK.
// This file proves the registry is a legitimate REGISTRY — that ids are stable
// and unique, that each preset's two palettes are actually a light/dark pair,
// and that a stored choice resolves fail-soft rather than stranding a reader
// with no theme.
//
// The fail-soft cases are the ones that matter: a persisted id outlives the
// build that wrote it. A reader who downgrades, or who chose a preset we later
// retire, must land on the default — never on an exception at first frame,
// before any UI exists to report it.
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:aiko_chat_app/features/settings/application/theme_preset_controller.dart';
import 'package:aiko_chat_app/app/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('the registry', () {
    test('offers a real CHOICE — a picker of one is not a picker', () {
      expect(kThemePresets.length, greaterThanOrEqualTo(2));
    });

    test('ids are unique — an id is a persistence key, and a collision '
        'silently resolves to whichever came first', () {
      final ids = kThemePresets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate id in $ids');
    });

    test('the default id is actually IN the registry', () {
      expect(kThemePresets.map((p) => p.id), contains(kDefaultPresetId));
    });

    test('every preset is a PAIR — the light half is light and the dark half '
        'is dark, so picking a look never costs you OS following', () {
      for (final p in kThemePresets) {
        expect(p.light.brightness, Brightness.light, reason: '${p.id} light');
        expect(p.dark.brightness, Brightness.dark, reason: '${p.id} dark');
        // And the built ThemeData must agree with its palette — a mismatch here
        // is what makes MaterialApp hand back the wrong half under
        // ThemeMode.system.
        expect(p.lightTheme.brightness, Brightness.light, reason: p.id);
        expect(p.darkTheme.brightness, Brightness.dark, reason: p.id);
      }
    });

    test('every preset is labelled and described for the picker', () {
      for (final p in kThemePresets) {
        expect(p.label, isNotEmpty, reason: p.id);
        expect(p.blurb, isNotEmpty, reason: p.id);
      }
    });
  });

  group('presetById resolves FAIL-SOFT', () {
    test('a known id resolves to its preset', () {
      for (final p in kThemePresets) {
        expect(presetById(p.id).id, p.id);
      }
    });

    test('null (nothing ever chosen) → the default', () {
      expect(presetById(null).id, kDefaultPresetId);
    });

    test('an unknown id (a retired preset, or a newer build\'s) → the default, '
        'never a throw', () {
      expect(presetById('atlantis').id, kDefaultPresetId);
      expect(presetById('').id, kDefaultPresetId);
    });
  });

  group('SkinSelectionController persists the choice', () {
    Future<ProviderContainer> containerWith(Map<String, Object> initial) async {
      SharedPreferences.setMockInitialValues(initial);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('with nothing stored, the reader gets the default look', () async {
      final c = await containerWith({});
      expect(c.read(themePresetProvider).id, kDefaultPresetId);
    });

    test('a stored id is restored on the next launch', () async {
      final other = kThemePresets.firstWhere((p) => p.id != kDefaultPresetId);
      final c = await containerWith({themePresetPrefKey: other.id});
      expect(c.read(themePresetProvider).id, other.id);
    });

    test('garbage in prefs does not brick the app at first frame', () async {
      final c = await containerWith({themePresetPrefKey: 'not-a-preset'});
      expect(c.read(themePresetProvider).id, kDefaultPresetId);
    });

    test(
      'selectPreset() applies immediately AND writes the id through',
      () async {
        final c = await containerWith({});
        final other = kThemePresets.firstWhere((p) => p.id != kDefaultPresetId);

        c.read(skinSelectionProvider.notifier).selectPreset(other);

        expect(
          c.read(themePresetProvider).id,
          other.id,
          reason:
              'the in-memory state is the fast path — the app re-themes '
              'on the next frame, not after the disk write',
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(themePresetPrefKey),
          contains(other.id),
          reason:
              'the ID is stored, never a resolved palette — so a later '
              'build can revise the colours without stranding readers on a '
              'frozen copy',
        );
      },
    );

    test('a bare id written by the PREVIOUS build still resolves — readers on '
        'PR #143 have exactly this stored right now', () async {
      final other = kThemePresets.firstWhere((p) => p.id != kDefaultPresetId);
      final c = await containerWith({themePresetPrefKey: other.id});
      expect(c.read(themePresetProvider).id, other.id);
      expect(c.read(skinSelectionProvider).isCustomised, isFalse);
    });
  });
}
