// SOMEONE ELSE'S DOCUMENT, arriving in your app.
//
// Every other theming test asks "does the reader's own choice work". This one
// asks the different question a trust boundary demands: what can a document
// authored by a stranger DO here? The answer has to be "nothing but change
// colours, and only to colours that still work" — for every input, not the ones
// I thought to imagine.
//
// The threat model is deliberately narrow and stated: nobody lies about their
// own wallpaper, so this is not about WHO wrote the skin (it is unsigned on
// purpose). It is entirely about what the document can do on ARRIVAL.
//
// RED-PROVE: delete the `checkPalette` gate in `decodeSkin` and
// "no input can produce an unlawful palette" goes green-to-red.
import 'dart:convert';

import 'package:aiko_chat_app/app/theme/app_fonts.dart';
import 'package:aiko_chat_app/app/theme/skin_selection.dart';
import 'package:aiko_chat_app/app/theme/skin_share.dart';
import 'package:aiko_chat_app/app/theme/theme_laws.dart';
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _code(Map<String, dynamic> doc) =>
    'aiko-skin:v$kSkinShareVersion:${base64Url.encode(utf8.encode(jsonEncode(doc)))}';

void main() {
  group('round trip — the honest case still has to work', () {
    test('a plain preset survives', () {
      const s = SkinSelection(presetId: 'blueprint');
      final back = decodeSkin(encodeSkin(s));
      expect(back.ok, isTrue, reason: '${back.error}');
      expect(back.selection!.presetId, 'blueprint');
      expect(back.wasAdjusted, isFalse);
    });

    test('a customised look survives intact — colours AND face', () {
      const s = SkinSelection(
        presetId: 'maritime',
        fontId: 'literata',
        lightOverrides: {PaletteRole.signal: Color(0xFF0B5F6C)},
      );
      final back = decodeSkin(encodeSkin(s));
      expect(back.ok, isTrue);
      expect(back.selection!.fontId, 'literata');
      expect(back.selection!.lightOverrides[PaletteRole.signal]?.toARGB32(),
          0xFF0B5F6C);
      expect(back.wasAdjusted, isFalse,
          reason: 'a lawful skin must arrive unmodified, or sharing is lossy');
    });

    test('per-channel tints are NOT shared — they are keyed by channel id, '
        'which is meaningless elsewhere and would leak which rooms you are in',
        () {
      // Channel tints live in a different store entirely; assert the shared
      // document has no room for them rather than trusting that by inspection.
      const s = SkinSelection(presetId: 'maritime');
      final payload = encodeSkin(s).split(':')[2];
      final doc = jsonDecode(utf8.decode(base64Url.decode(payload))) as Map;
      expect(doc.keys, isNot(contains('channels')));
      expect(doc.keys.toSet(), {'v', 'preset'});
    });
  });

  group('refusals name a reason — silence is indistinguishable from broken', () {
    test('empty', () {
      expect(decodeSkin(null).error, SkinImportError.empty);
      expect(decodeSkin('   ').error, SkinImportError.empty);
    });

    test('not a skin code at all', () {
      expect(decodeSkin('hello').error, SkinImportError.notASkin);
      expect(decodeSkin('http://evil.example/x').error,
          SkinImportError.notASkin);
      expect(decodeSkin('aiko-skin:v1').error, SkinImportError.notASkin);
    });

    test('a version we do not know is refused, NOT parsed hopefully — guessing '
        'at a newer document is how you apply half of something', () {
      expect(decodeSkin('aiko-skin:v99:e30=').error,
          SkinImportError.wrongVersion);
      expect(decodeSkin(_code({'v': 99})).error, SkinImportError.wrongVersion);
    });

    test('damaged payloads', () {
      expect(decodeSkin('aiko-skin:v1:!!!not-base64!!!').error,
          SkinImportError.malformed);
      expect(decodeSkin('aiko-skin:v1:${base64Url.encode(utf8.encode("[]"))}')
          .error, SkinImportError.malformed);
      expect(decodeSkin('aiko-skin:v1:${base64Url.encode(utf8.encode("nope"))}')
          .error, SkinImportError.malformed);
    });

    test('every error carries a message a person can act on', () {
      for (final e in SkinImportError.values) {
        expect(e.message, isNotEmpty);
        expect(e.message.length, greaterThan(15), reason: e.name);
      }
    });
  });

  group('hostile input', () {
    test('an oversized payload is refused BY LENGTH, before any parsing — the '
        'cheap check has to come first or the expensive one is the attack', () {
      final huge = 'aiko-skin:v1:${'A' * (kMaxSkinCodeLength + 1)}';
      expect(decodeSkin(huge).error, SkinImportError.tooLong);
    });

    test('deeply nested JSON cannot reach the parser at scale', () {
      final nested = '${'[' * 2000}${']' * 2000}';
      final code = 'aiko-skin:v1:${base64Url.encode(utf8.encode(nested))}';
      // Either too long, or malformed once parsed — never a crash, never ok.
      final result = decodeSkin(code);
      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
    });

    test('unknown role names are ignored, not fatal — a newer build may know '
        'roles we do not', () {
      final r = decodeSkin(_code({
        'v': kSkinShareVersion,
        'preset': 'maritime',
        'light': {'chartreuse': '#ff00ff00', 'signal': '#ff0b5f6c'},
      }));
      expect(r.ok, isTrue);
      expect(r.selection!.lightOverrides.length, 1);
      expect(r.selection!.lightOverrides.containsKey(PaletteRole.signal), isTrue);
    });

    test('an unknown preset or font falls back rather than failing — a skin '
        'naming a preset we retired is still a good set of colours', () {
      final r = decodeSkin(_code({
        'v': kSkinShareVersion,
        'preset': 'atlantis',
        'font': 'wingdings',
      }));
      expect(r.ok, isTrue);
      expect(r.selection!.presetId, kDefaultPresetId);
      expect(r.selection!.fontId, kDefaultFontId);
    });

    test('values that are not colours are dropped, whatever they are', () {
      for (final junk in [
        '"; DROP TABLE channels; --',
        '../../etc/passwd',
        '<script>alert(1)</script>',
        'null',
        '{}',
        '99999999999999999999999999',
      ]) {
        final r = decodeSkin(_code({
          'v': kSkinShareVersion,
          'preset': 'maritime',
          'light': {'signal': junk},
        }));
        expect(r.ok, isTrue, reason: 'junk value should be dropped, not fatal');
        expect(r.selection!.lightOverrides.containsKey(PaletteRole.signal),
            isFalse,
            reason: 'accepted "$junk" as a colour');
      }
    });

    test('a skin cannot smuggle LAYOUT — the document has no such field, and '
        'inventing one changes nothing', () {
      final r = decodeSkin(_code({
        'v': kSkinShareVersion,
        'preset': 'maritime',
        'layout': {'hideBlockButton': true, 'composer': 'none'},
        'bubbles': true,
        'density': 99,
      }));
      expect(r.ok, isTrue);
      // The selection type simply has nowhere to put any of it.
      expect(r.selection!.presetId, 'maritime');
      expect(r.selection!.isCustomised, isFalse);
    });

    test('a hostile role map cannot grow without bound — caught by the LENGTH '
        'cap when it is big, and by the role enum when it is not', () {
      // Big enough to blow the cap: refused before parsing, which is the point
      // of checking length first.
      final huge = {
        for (var i = 0; i < 500; i++) 'role$i': '#ff000000',
        'signal': '#ff0b5f6c',
      };
      expect(
        decodeSkin(_code({
          'v': kSkinShareVersion,
          'preset': 'maritime',
          'light': huge,
        })).error,
        SkinImportError.tooLong,
      );

      // Small enough to get through: now the role enum is the bound. Only names
      // that match one of eleven known roles survive; the rest are discarded.
      final sneaky = {
        for (var i = 0; i < 60; i++) 'r$i': '#ff000000',
        'signal': '#ff0b5f6c',
      };
      final r = decodeSkin(_code({
        'v': kSkinShareVersion,
        'preset': 'maritime',
        'light': sneaky,
      }));
      expect(r.ok, isTrue, reason: '${r.error}');
      expect(r.selection!.lightOverrides.length,
          lessThanOrEqualTo(PaletteRole.values.length));
      expect(r.selection!.lightOverrides.keys, [PaletteRole.signal]);
    });
  });

  group('THE PROPERTY: no input can produce an unlawful palette', () {
    test('an unreadable skin is either healed or refused — never applied', () {
      final r = decodeSkin(_code({
        'v': kSkinShareVersion,
        'preset': 'maritime',
        'light': {'signal': '#ffefead9'}, // vanishes on chart paper
      }));

      expect(r.ok, isTrue, reason: 'healing is preferred to refusing outright');
      expect(r.wasAdjusted, isTrue,
          reason: 'and the importer must be TOLD it is not what was sent');
      expect(checkPalette(r.selection!.resolve().light), isEmpty);
    });

    test('a skin that is unreadable in EVERY role still resolves to something '
        'usable', () {
      const mud = '#ff808080';
      final r = decodeSkin(_code({
        'v': kSkinShareVersion,
        'preset': 'maritime',
        'light': {for (final role in PaletteRole.values) role.name: mud},
        'dark': {for (final role in PaletteRole.values) role.name: mud},
      }));
      expect(r.ok, isTrue);
      expect(r.wasAdjusted, isTrue);
      expect(checkPalette(r.selection!.resolve().light), isEmpty);
      expect(checkPalette(r.selection!.resolve().dark), isEmpty);
    });

    test('SWEEP: no single-role colour, across every role, every preset and '
        'both brightnesses, can produce an unlawful result', () {
      // The claim is universal, so the test is a sweep rather than a handful of
      // colours I happened to think were nasty.
      for (final preset in kThemePresets) {
        for (final brightness in ['light', 'dark']) {
          for (final role in PaletteRole.values) {
            for (var h = 0; h < 360; h += 60) {
              for (final l in [0.05, 0.5, 0.95]) {
                final c = HSLColor.fromAHSL(1, h.toDouble(), 0.7, l).toColor();
                final hex =
                    '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';
                final r = decodeSkin(_code({
                  'v': kSkinShareVersion,
                  'preset': preset.id,
                  brightness: {role.name: hex},
                }));

                expect(r.ok, isTrue,
                    reason: '${preset.id}/$brightness/${role.name}/$hex was '
                        'refused outright: ${r.error}');
                final resolved = r.selection!.resolve();
                expect(checkPalette(resolved.light), isEmpty,
                    reason: '${preset.id}/$brightness/${role.name}/$hex broke '
                        'the light palette');
                expect(checkPalette(resolved.dark), isEmpty,
                    reason: '${preset.id}/$brightness/${role.name}/$hex broke '
                        'the dark palette');
              }
            }
          }
        }
      }
    });
  });
}
