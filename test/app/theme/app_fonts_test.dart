// The typeface choice: its registry, its persistence, and the two properties
// that make fetching-instead-of-bundling acceptable.
//
// Those two are the whole argument for the design, so they are asserted rather
// than asserted-in-a-comment:
//   1. the DEFAULT makes no network request (it sets no family at all);
//   2. a face choice survives, and composes with, every other theme preference.
import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/app/theme/app_fonts.dart';
import 'package:aiko_chat_app/app/theme/skin_selection.dart';
import 'package:aiko_chat_app/app/theme/theme_laws.dart';
import 'package:aiko_chat_app/features/settings/application/theme_preset_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('the registry', () {
    test('offers a real choice, and the default is IN it', () {
      expect(kAppFonts.length, greaterThanOrEqualTo(2));
      expect(kAppFonts.map((f) => f.id), contains(kDefaultFontId));
    });

    test('ids are unique — an id is a persistence key', () {
      final ids = kAppFonts.map((f) => f.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every font is labelled and has a reason to exist', () {
      for (final f in kAppFonts) {
        expect(f.label, isNotEmpty, reason: f.id);
        expect(f.blurb, isNotEmpty, reason: f.id);
      }
    });

    test('EXACTLY ONE system font, and it is the default — the offline-safe '
        'choice must be what a reader gets without asking', () {
      final system = kAppFonts.where((f) => f.isSystem).toList();
      expect(system.length, 1);
      expect(system.single.id, kDefaultFontId);
    });
  });

  group('the default costs nothing', () {
    test('the system face sets NO font family — which is what makes it render '
        'offline, instantly, with no request to anyone', () {
      expect(systemFont.googleFamily, isNull);

      const base = TextTheme(bodyMedium: TextStyle(fontSize: 14));
      final applied = systemFont.apply(base);
      expect(applied.bodyMedium?.fontFamily, isNull,
          reason: 'the system font must not name a family — naming one is '
              'exactly the thing that triggers a fetch');
      expect(applied.bodyMedium?.fontSize, 14, reason: 'and it changes nothing else');
    });

    test('every NON-system font names a family to fetch', () {
      for (final f in kAppFonts.where((f) => !f.isSystem)) {
        expect(f.googleFamily, isNotNull, reason: f.id);
        expect(f.googleFamily, isNotEmpty, reason: f.id);
      }
    });
  });

  group('fontById is fail-soft', () {
    test('unknown, empty and null all land on the system face — the one choice '
        'guaranteed to render on any device with no network', () {
      expect(fontById(null).id, kDefaultFontId);
      expect(fontById('').id, kDefaultFontId);
      expect(fontById('comic-papyrus').id, kDefaultFontId);
    });

    test('a known id resolves', () {
      for (final f in kAppFonts) {
        expect(fontById(f.id).id, f.id);
      }
    });
  });

  group('the font composes with the other preferences', () {
    test('it is orthogonal to the palette: switching preset KEEPS the font', () {
      const s = SkinSelection(presetId: 'maritime', fontId: 'inter');
      expect(s.withPreset('radar').fontId, 'inter');
      expect(s.withPreset('radar').presetId, 'radar');
    });

    test('resetting COLOURS keeps the font — it was never a colour edit', () {
      const s = SkinSelection(
        presetId: 'maritime',
        fontId: 'literata',
        lightOverrides: {PaletteRole.signal: Color(0xFF0B5F6C)},
      );
      expect(s.reset.fontId, 'literata');
      expect(s.reset.isCustomised, isFalse);
    });

    test('editing a colour keeps the font', () {
      final s = const SkinSelection(presetId: 'maritime', fontId: 'inter')
          .withOverride(
        brightness: Brightness.light,
        role: PaletteRole.signal,
        colour: const Color(0xFF0B5F6C),
      );
      expect(s.fontId, 'inter');
    });

    test('it round-trips through storage, and the default is not written out', () {
      const withFont = SkinSelection(presetId: 'maritime', fontId: 'inter');
      expect(SkinSelection.decode(withFont.encode()).fontId, 'inter');

      const plain = SkinSelection(presetId: 'maritime');
      expect(plain.encode(), isNot(contains('font')),
          reason: 'the default is the absence of a choice, not a stored value');
      expect(SkinSelection.decode(plain.encode()).fontId, kDefaultFontId);
    });

    test('a stored font id from a build that offered more faces falls back '
        'rather than throwing', () {
      expect(
        SkinSelection.decode('{"preset":"maritime","font":"wingdings"}').fontId,
        kDefaultFontId,
      );
    });
  });

  group('the composed theme', () {
    test('carries the palette AND the font, and stays lawful', () async {
      final c = await _container();
      c.read(skinSelectionProvider.notifier)
          .selectFont(kAppFonts.firstWhere((f) => !f.isSystem));

      // The palette laws are colour laws; a typeface cannot break them, and
      // this asserts the composition did not lose the palette on the way.
      expect(checkPalette(c.read(themePresetProvider).light), isEmpty);
      expect(c.read(lightThemeProvider).brightness, Brightness.light);
      expect(c.read(darkThemeProvider).brightness, Brightness.dark);
    });

    test('the chosen face reaches the built ThemeData', () async {
      final c = await _container();
      final inter = kAppFonts.firstWhere((f) => f.id == 'inter');
      c.read(skinSelectionProvider.notifier).selectFont(inter);

      final family = c.read(lightThemeProvider).textTheme.bodyMedium?.fontFamily;
      expect(family, isNotNull,
          reason: 'a chosen face that never reaches the TextTheme is a setting '
              'that does nothing');
      expect(family, contains('Inter'));
    });

    test('the system face IMPOSES no family of ours — whatever the platform '
        'typography says stands', () async {
      final c = await _container();
      final family = c.read(lightThemeProvider).textTheme.bodyMedium?.fontFamily;

      // NOT `isNull`: Flutter's own Typography names a face (Roboto on non-Apple
      // hosts, including the test harness) before we touch the theme. The claim
      // that matters is narrower and true — the system choice never substitutes
      // one of OUR fetchable families, so nothing is downloaded.
      final ours = kAppFonts
          .where((f) => !f.isSystem)
          .map((f) => f.googleFamily!)
          .toList();
      for (final o in ours) {
        expect(family, isNot(contains(o)),
            reason: 'the system face pulled in $o');
      }
    });

    test('the choice persists across a restart', () async {
      final c = await _container();
      c.read(skinSelectionProvider.notifier)
          .selectFont(kAppFonts.firstWhere((f) => f.id == 'literata'));

      final prefs = await SharedPreferences.getInstance();
      final restored = await _container({
        themePresetPrefKey: prefs.getString(themePresetPrefKey)!,
      });
      expect(restored.read(appFontProvider).id, 'literata');
    });
  });
}
