// The reader's chosen typeface must reach the app-bar title too.
//
// It did not. `appBarTheme.titleTextStyle` was a BARE `TextStyle` — colour,
// size, weight, no family — and `AppBar` installs that style AS the
// `DefaultTextStyle` for its title rather than merging it into the ambient one.
// So the title silently dropped whatever face `_text()` had applied, and a
// reader who picked Inter got Inter everywhere except the one line at the top of
// every screen.
//
// It hid well. In production a null family resolves to the platform face, which
// looks deliberate rather than broken; and under `flutter test` it resolves to
// the box-glyph test font, which is how it was finally noticed — the blind
// playtester's screenshot of /settings/island showed a solid slab where a title
// belonged, 120px wide at exactly 20.0px per character, one flat colour.
//
// The guard is a comparison rather than a literal, so it keeps holding when the
// font list changes: whatever family the text theme resolved, the app-bar title
// resolved the same one.
import 'package:aiko_chat_app/app/theme/app_fonts.dart';
import 'package:aiko_chat_app/app/theme/theme_builder.dart';
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A face the reader can actually pick; the system font is the uninteresting
  // case because its family is null on BOTH sides and the comparison passes
  // whether or not the bug is present.
  final chosen = kAppFonts.firstWhere((f) => f.googleFamily != null);

  for (final preset in kThemePresets) {
    for (final (name, palette) in [
      ('light', preset.light),
      ('dark', preset.dark),
    ]) {
      test('${preset.id}/$name app-bar title uses the chosen face', () {
        final theme = buildTheme(palette, font: chosen);
        final body = theme.textTheme.titleLarge?.fontFamily;

        expect(
          body,
          isNotNull,
          reason:
              'the fixture is void: ${chosen.id} did not reach the text theme '
              'either, so this test cannot tell a fixed title from a broken one',
        );
        expect(
          theme.appBarTheme.titleTextStyle?.fontFamily,
          body,
          reason:
              'the app-bar title resolved '
              '${theme.appBarTheme.titleTextStyle?.fontFamily} while the rest '
              'of the app resolved $body — a bare TextStyle here replaces the '
              'DefaultTextStyle instead of merging with it, so the reader\'s '
              'chosen face never reaches the title',
        );
      });
    }
  }

  test('the size and weight the app bar asks for still survive', () {
    // The fix derives from titleLarge, so it could silently inherit that
    // style's metrics instead of the ones the chrome deliberately specifies.
    final theme = buildTheme(kThemePresets.first.light, font: chosen);
    expect(theme.appBarTheme.titleTextStyle?.fontSize, 20);
    expect(
      theme.appBarTheme.titleTextStyle?.fontWeight?.value,
      600,
    );
  });
}
