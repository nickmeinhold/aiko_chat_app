// The channel tier of the scope cascade, and the two properties that make it
// safe to let a room you did not create change how your app looks.
//
//   1. A channel can tint ONE role. Not a palette, not a font, not a layout.
//   2. THE READER WINS. A hue that would break the reader's palette is dropped,
//      not applied and apologised for.
//
// The second is the one that actually matters: a channel accent arrives from
// outside the reader's own choices, so "it looked fine when we picked it" is
// not a guarantee that covers the reader who walks in with an edited palette.
import 'package:aiko_chat_app/app/theme/channel_look.dart';
import 'package:aiko_chat_app/app/theme/maritime_theme.dart';
import 'package:aiko_chat_app/app/theme/theme_laws.dart';
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel =
    '01J9ZQK8V0000000000000000A'; // a bare ULID, as the server gives it
const _other = '01J9ZQK8V0000000000000000B';

// Fixtures are brightness-specific ON PURPOSE. The first draft used noon's own
// deep teal against sea-night and the tint was (correctly) refused for being too
// dark to read there — the test fixture broke the very rule the test asserts.
// Each constant now names the palette it is legal on, and `_fixturesAreValid`
// below proves it rather than trusting the comment.
const _lawfulOnNight = Color(0xFF45D97F); // phosphor — reads on sea-night
const _lawfulOnNoon = Color(0xFF0B5F6C); // deep teal — reads on chart paper
const _unlawfulPale = Color(0xFFEFEAD9); // vanishes on maritime noon's ground

void main() {
  test('the fixtures are what they claim — a test whose own colours break the '
      'rule proves nothing about the rule', () {
    expect(ChannelLooks.isLawful(maritimeNight, _lawfulOnNight), isTrue);
    expect(ChannelLooks.isLawful(maritimeNoon, _lawfulOnNoon), isTrue);
    expect(ChannelLooks.isLawful(maritimeNoon, _unlawfulPale), isFalse);
  });

  group('a channel tints ONE role, and only that role', () {
    test('the signal accent changes', () {
      const looks = ChannelLooks({_channel: _lawfulOnNight});
      final tinted = looks.applyTo(maritimeNight, _channel);
      expect(tinted.signal.toARGB32(), _lawfulOnNight.toARGB32());
    });

    test('EVERY other role is untouched — a room cannot restyle the app around '
        'you, which is the whole point of the cascade narrowing outward', () {
      const looks = ChannelLooks({_channel: _lawfulOnNight});
      final tinted = looks.applyTo(maritimeNight, _channel);

      for (final role in PaletteRole.values) {
        if (role == PaletteRole.signal) continue;
        expect(
          roleOf(tinted, role),
          roleOf(maritimeNight, role),
          reason: 'the channel moved ${role.name}',
        );
      }
    });
  });

  group('THE READER WINS', () {
    test('a hue that would break the palette is DROPPED, not applied', () {
      const looks = ChannelLooks({_channel: _unlawfulPale});
      final result = looks.applyTo(maritimeNoon, _channel);

      expect(
        result.signal,
        maritimeNoon.signal,
        reason: 'the unlawful tint should have been refused outright',
      );
      expect(
        checkPalette(result),
        isEmpty,
        reason: 'a reader must never be handed an unreadable room',
      );
    });

    test(
      'lawfulness is judged against the COMPOSED palette, not the hue alone '
      '— the same accent can be fine in one theme and invisible in another',
      () {
        // A pale accent reads on sea-night and disappears on chart paper.
        const pale = Color(0xFFBFE8F0);
        expect(ChannelLooks.isLawful(maritimeNight, pale), isTrue);
        expect(ChannelLooks.isLawful(maritimeNoon, pale), isFalse);
      },
    );

    test(
      'every preset, in both brightnesses, survives every tint we would '
      'OFFER — the offer list is the guarantee, so it has to hold globally',
      () {
        for (final preset in kThemePresets) {
          for (final base in [preset.light, preset.dark]) {
            for (var h = 0; h < 360; h += 30) {
              for (final l in [0.32, 0.55]) {
                final hue = HSLColor.fromAHSL(
                  1,
                  h.toDouble(),
                  0.6,
                  l,
                ).toColor();
                if (!ChannelLooks.isLawful(base, hue)) continue;
                final applied = ChannelLooks({
                  _channel: hue,
                }).applyTo(base, _channel);
                expect(
                  checkPalette(applied),
                  isEmpty,
                  reason:
                      'preset ${preset.id} accepted an offered hue that '
                      'then broke the palette',
                );
              }
            }
          }
        }
      },
    );
  });

  group('scoping', () {
    test('a tint applies to ITS channel and no other', () {
      const looks = ChannelLooks({_channel: _lawfulOnNight});
      expect(looks.applyTo(maritimeNight, _other).signal, maritimeNight.signal);
      expect(looks.applyTo(maritimeNight, null).signal, maritimeNight.signal);
    });

    test('an unknown channel is not an error — you can be in a room that has '
        'never been tinted', () {
      expect(
        ChannelLooks.none.applyTo(maritimeNight, _other).signal,
        maritimeNight.signal,
      );
    });

    test('the id is treated as OPAQUE — a DM id is a bare ULID with no prefix, '
        'and inferring channel kind from it has already caused one real bug', () {
      // Two ids that differ only in a way naive prefix-sniffing would collapse.
      const looks = ChannelLooks({_channel: _lawfulOnNight});
      expect(looks.hueFor(_channel), isNotNull);
      expect(
        looks.hueFor('dm:$_channel'),
        isNull,
        reason: 'the key is the raw id; nothing may reinterpret it',
      );
    });
  });

  group('editing', () {
    test('setting, changing and clearing a tint', () {
      var looks = ChannelLooks.none.set(_channel, _lawfulOnNight);
      expect(looks.hueFor(_channel), _lawfulOnNight);

      looks = looks.set(_channel, const Color(0xFF8F6210));
      expect(looks.hueFor(_channel)?.toARGB32(), 0xFF8F6210);

      looks = looks.set(_channel, null);
      expect(looks.hueFor(_channel), isNull);
      expect(looks.isEmpty, isTrue);
    });

    test('tinting one channel leaves the others alone', () {
      final looks = ChannelLooks.none
          .set(_channel, _lawfulOnNight)
          .set(_other, _lawfulOnNight);
      expect(looks.set(_channel, null).hueFor(_other), isNotNull);
    });
  });

  group('storage is fail-soft', () {
    test('round-trips', () {
      final looks = ChannelLooks.none.set(_channel, _lawfulOnNight);
      final back = ChannelLooks.decode(looks.encode());
      expect(back.hueFor(_channel)?.toARGB32(), _lawfulOnNight.toARGB32());
    });

    test('null, empty and malformed all give no tints rather than throwing — '
        'this is read at startup and a tint must never wedge the app', () {
      expect(ChannelLooks.decode(null).isEmpty, isTrue);
      expect(ChannelLooks.decode('').isEmpty, isTrue);
      expect(ChannelLooks.decode('{not json').isEmpty, isTrue);
      expect(ChannelLooks.decode('[]').isEmpty, isTrue);
    });

    test('a garbage colour is dropped, the rest survive', () {
      const raw = '{"$_channel":"nope","$_other":"#ff0b5f6c"}';
      final looks = ChannelLooks.decode(raw);
      expect(looks.hueFor(_channel), isNull);
      expect(looks.hueFor(_other), isNotNull);
    });

    test('a stored tint that has SINCE become unlawful is refused at apply '
        'time — the reader may have edited their palette after tinting', () {
      final looks = ChannelLooks.none.set(_channel, _unlawfulPale);
      final applied = looks.applyTo(maritimeNoon, _channel);
      expect(checkPalette(applied), isEmpty);
      expect(applied.signal, maritimeNoon.signal);
    });
  });
}
