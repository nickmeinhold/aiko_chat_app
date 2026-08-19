import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which island are you on?
///
/// A federated app has to answer that constantly and quietly. The previous
/// answer was nothing at all — you knew your island because you remembered it.
///
/// WHY A MARK AND NOT A THEME. Islands were briefly going to get a "bounded
/// band" of theming, and that was a smaller version of the same mistake as
/// per-channel colours: it spends the READER's palette — the thing they chose —
/// to say something about the room they are standing in. An island does not get
/// to restyle your app. It gets an identity you can recognise at a glance, in
/// its own small square of pixels, and nothing outside that square changes.
///
/// WHY IT IS DERIVED AND NOT REGISTERED. The mark is computed from the island's
/// own address, so every device shows the same island the same way with no
/// registry, no central authority to assign badges, and nothing for an island to
/// claim or squat. Same trick as the key-derived Blockie avatars: identity you
/// can SEE, computed from identity you already have. A new island gets a
/// distinct mark the moment it exists, without asking anyone.
///
/// THE COMBINATION IS THE IDENTITY. Water colour and island silhouette vary
/// independently, so the space is (colours × shapes) rather than either alone —
/// two islands sharing a water colour still read as different islands, which is
/// what lets the palette stay small enough that each colour is actually
/// recognisable.
///
/// It is DELIBERATELY STATIC. It replaced the signing seal, which animated on
/// every first and last keystroke; a thing that answers "where am I" must not
/// flicker while you type. Nothing here reacts to composer state.

/// Muted on purpose. These sit beside a reader's chosen palette all day, so they
/// are desaturated enough to be furniture rather than a second accent competing
/// with the theme's own signal. Chart-water hues: the sea in different lights.
const _waters = <Color>[
  Color(0xFF4E6E7A), // slate sea
  Color(0xFF5B7360), // shoal green
  Color(0xFF6B6480), // dusk violet
  Color(0xFF7A6350), // silt brown
  Color(0xFF4F6A86), // deep blue
  Color(0xFF7B6470), // heather
  Color(0xFF5E7472), // lagoon
  Color(0xFF80705A), // sandbank
];

/// A stable 32-bit hash (FNV-1a). Deliberately NOT `String.hashCode`, which Dart
/// does not guarantee to be stable across runs or platforms — an island whose
/// mark changed when you restarted the app would be worse than no mark at all.
int islandHash(String s) {
  var h = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// The island's address, reduced to the part that identifies it.
///
/// Scheme, port, path and trailing slashes are stripped so that
/// `https://chat.example.org/` and `chat.example.org` are the SAME island — a
/// mark that changed because a URL gained a slash would be a bug wearing a
/// feature's clothes.
String islandKey(String baseUrl) {
  var s = baseUrl.trim().toLowerCase();
  s = s.replaceFirst(RegExp(r'^[a-z]+://'), '');
  s = s.split('/').first;
  s = s.split(':').first;
  return s;
}

/// The identity a mark draws: which water, and which island shape.
@immutable
class IslandIdentity {
  const IslandIdentity({required this.water, required this.shapeSeed});

  final Color water;

  /// Drives the silhouette. A separate slice of the hash from the colour, so
  /// two islands that land on the same water still differ in outline.
  final int shapeSeed;

  factory IslandIdentity.of(String baseUrl) {
    final h = islandHash(islandKey(baseUrl));
    return IslandIdentity(
      water: _waters[h % _waters.length],
      shapeSeed: (h >> 8) & 0xFFFF,
    );
  }
}

/// A chart medallion: a small disc of water with an island in it.
///
/// The silhouette is generated rather than chosen from a fixed set of icons.
/// Eight stock glyphs would have made the ninth island a duplicate; a shape
/// grown from the hash gives every island its own outline, and — being built
/// from smooth harmonics rather than a random walk — they all still read as
/// *islands* rather than as noise.
class IslandMark extends StatelessWidget {
  const IslandMark({
    super.key,
    required this.baseUrl,
    this.size = 18,
    this.label,
    this.onTap,
  });

  final String baseUrl;
  final double size;

  /// Tapping the mark should take you to the island picker — the mark answers
  /// "where am I", so the obvious next question is "can I go somewhere else".
  ///
  /// Passed IN rather than routed from here: this widget lives in `core/` and
  /// knowing about `/settings/gateway` would tie a drawing to the router.
  final VoidCallback? onTap;

  /// Shown on hover/long-press. The mark is recognisable, not self-explanatory;
  /// the first time you see one you should be able to ask it what it means.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final identity = IslandIdentity.of(baseUrl);
    final mark = CustomPaint(
      size: Size.square(size),
      painter: _IslandPainter(
        identity: identity,
        rim: Theme.of(context).colorScheme.outline,
      ),
    );
    final name = label ?? islandKey(baseUrl);
    return Tooltip(
      message: onTap == null ? name : '$name — tap to change island',
      child: Semantics(
        label: 'Island: $name',
        button: onTap != null,
        child: onTap == null
            ? mark
            : InkResponse(
                onTap: onTap,
                radius: size,
                // A 18px target is well under the 44px minimum, and this sits
                // beside a text field people jab at — so the hit area is grown
                // without growing the mark.
                child: Padding(padding: const EdgeInsets.all(6), child: mark),
              ),
      ),
    );
  }
}

class _IslandPainter extends CustomPainter {
  _IslandPainter({required this.identity, required this.rim});

  final IslandIdentity identity;
  final Color rim;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // The water.
    canvas.drawCircle(c, r, Paint()..color = identity.water);

    // A hairline rim, in the app's own outline colour — the one place the mark
    // acknowledges the surrounding theme, so it sits in the design rather than
    // on top of it.
    canvas.drawCircle(
      c,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rim,
    );

    // The land: a closed blob whose radius is modulated by three harmonics with
    // seed-derived amplitudes and phases. Three is the number that matters —
    // one gives an egg, two gives a peanut, three gives something that reads as
    // a coastline while staying smooth.
    final s = identity.shapeSeed;
    final amps = [
      0.10 + (s & 0x7) / 40, // 0.10 – 0.27
      0.06 + ((s >> 3) & 0x7) / 60,
      0.04 + ((s >> 6) & 0x7) / 90,
    ];
    final phases = [
      ((s >> 9) & 0xF) * math.pi / 8,
      ((s >> 13) & 0x7) * math.pi / 4,
      ((s >> 4) & 0x7) * math.pi / 4,
    ];

    final land = Path();
    const steps = 48;
    final base = r * 0.62;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps * 2 * math.pi;
      final k =
          1 +
          amps[0] * math.sin(2 * t + phases[0]) +
          amps[1] * math.sin(3 * t + phases[1]) +
          amps[2] * math.sin(5 * t + phases[2]);
      final p =
          c + Offset(math.cos(t) * base * k, math.sin(t) * base * k * 0.86);
      i == 0 ? land.moveTo(p.dx, p.dy) : land.lineTo(p.dx, p.dy);
    }
    land.close();

    // Land is PALE, water is dark — the way a chart actually prints, and the
    // reason is legibility rather than authenticity. The first cut drew land as
    // the water darkened, which at the 18px this ships at read as a hole punched
    // in a coloured disc: every island looked like "dark blob on colour" and the
    // silhouette did no identifying work at all. Inverting it puts the contrast
    // where the SHAPE is, so the outline survives being small.
    //
    // The land keeps a trace of the water's hue rather than going white, so the
    // medallion still reads as one colour idea and the water remains what you
    // recognise first.
    final hsl = HSLColor.fromColor(identity.water);
    canvas.drawPath(
      land,
      Paint()
        ..color = hsl
            .withLightness(0.86)
            .withSaturation((hsl.saturation * 0.5).clamp(0.0, 1.0))
            .toColor(),
    );
  }

  @override
  bool shouldRepaint(_IslandPainter old) =>
      old.identity.water != identity.water ||
      old.identity.shapeSeed != identity.shapeSeed ||
      old.rim != rim;
}
