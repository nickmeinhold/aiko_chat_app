import 'dart:math' as math;
import 'dart:ui' as ui;

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

/// The mark's colour is a CONTINUOUS hue derived from the island's identity, the
/// same way [MarkAvatar] derives a person's Blockie — not a pick from a fixed
/// palette.
///
/// It was a fixed palette of eight, and that shipped a real collision: the two
/// islands Nick actually switches between, `chat.imagineering.cc` and
/// `enspyr.co`, both landed on dusk violet. "The islands don't seem to be a
/// different colour" was not a perception problem. With eight buckets, two
/// islands collide one time in eight — which is not a tail case, it is a coin
/// you flip every time someone adds a second island.
///
/// Still MUTED, deliberately: saturation and lightness are held in a narrow band
/// so the mark stays furniture beside a reader's chosen palette instead of
/// competing with the theme's own signal. Only the HUE varies, and it varies
/// continuously.

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
/// A FALLBACK identity source, not the preferred one — see [IslandIdentity.of].
/// A hostname is a rented, transferable label.
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

  /// Derive an island's mark.
  ///
  /// PREFER THE KEY. `GET /v1/island` returns a signed self-manifest carrying an
  /// Ed25519 `island_pubkey`, and that — not the hostname — is what the island
  /// actually IS. A domain is rented and transferable: rename it and the island
  /// is the same island; let it lapse and whoever picks it up inherits the name
  /// but cannot inherit the key. Keying the mark to the pubkey means a mark
  /// cannot be acquired along with a domain, which is the same reasoning that
  /// makes a person's identity their key and their handle a mutable label.
  ///
  /// The URL is the fallback for an island that has not been asked yet, or one
  /// too old to answer. Stated plainly because it has a consequence: a mark
  /// derived from the URL and later re-derived from the key is a DIFFERENT mark,
  /// so an island settles once — on first contact — and is stable forever after
  /// (the manifest is cached).
  factory IslandIdentity.of(String baseUrl, {String? islandPubkey}) {
    final source = (islandPubkey != null && islandPubkey.isNotEmpty)
        ? islandPubkey
        : islandKey(baseUrl);
    final h = islandHash(source);

    // Hue from the full 32-bit spread, exactly like the Blockie's `k[3]/255*360`
    // but with more of the hash behind it. Continuous, so two islands collide
    // only if they collide in the hash itself.
    final hue = (h % 3600) / 10.0;
    return IslandIdentity(
      water: HSLColor.fromAHSL(1, hue, 0.30, 0.42).toColor(),
      shapeSeed: (h >> 11) & 0xFFFF,
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
    this.hitPadding = EdgeInsets.zero,
    this.islandPubkey,
    this.sunAltitude,
  });

  final String baseUrl;
  final double size;

  /// Where the sun is over THIS ISLAND, +1 noon to -1 midnight — see
  /// `island_daylight.dart`.
  ///
  /// NULL DRAWS THE MARK EXACTLY AS IT DREW BEFORE any of this existed, and
  /// that is the common path: no island publishes a timezone yet. It is the
  /// island's day, never the viewer's — a mark showing your own time-of-day on
  /// another island's face would be decorative and quietly dishonest about
  /// whose day it is.
  final double? sunAltitude;

  /// Tapping the mark should take you to the island picker — the mark answers
  /// "where am I", so the obvious next question is "can I go somewhere else".
  ///
  /// Passed IN rather than routed from here: this widget lives in `core/` and
  /// knowing about `/settings/island` would tie a drawing to the router.
  final VoidCallback? onTap;

  /// Padding that is INSIDE the tap target — pressable space around the mark.
  ///
  /// This is how an 18px glyph gets a thumb-sized target without growing on
  /// screen: the caller hands over the padding it was ALREADY drawing around
  /// this widget, so the mark lands in exactly the same pixels and the gutter
  /// beside it starts accepting presses. Flutter cannot hit-test outside a
  /// widget's own bounds, so the space has to belong to the gesture rather than
  /// to a Padding above it — there is no way to "extend" a hit area otherwise.
  final EdgeInsets hitPadding;

  /// The island's Ed25519 public key, when known. Preferred over [baseUrl] —
  /// see [IslandIdentity.of].
  final String? islandPubkey;

  /// Shown on hover/long-press. The mark is recognisable, not self-explanatory;
  /// the first time you see one you should be able to ask it what it means.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final identity = IslandIdentity.of(baseUrl, islandPubkey: islandPubkey);
    final mark = CustomPaint(
      size: Size.square(size),
      painter: IslandPainter(
        identity: identity,
        rim: Theme.of(context).colorScheme.outline,
        sunAltitude: sunAltitude,
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
            : GestureDetector(
                // OPAQUE, and a full 44×44. The first cut was an InkResponse
                // with 6px of padding — about a 30px target sitting in the
                // bottom-left corner, where thumb accuracy is worst, and it was
                // genuinely hard to hit.
                //
                // The behaviour matters as much as the size. Without
                // `opaque`, the hit test defers to the CHILD, and the child is a
                // circle inside a square box — so the corners were dead space
                // and a near-miss landed on nothing. That feels exactly like
                // "the border is swallowing taps", which is how this was
                // reported.
                //
                // 44 is Apple's minimum touch target. The target grows; the
                // drawing stays 18px.
                // OPAQUE matters as much as the size. Without it the hit test
                // defers to the CHILD — a circle inside a square box — so the
                // corners are dead and a near-miss lands on nothing. That is
                // what "the border is swallowing taps" felt like.
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Padding(padding: hitPadding, child: mark),
              ),
      ),
    );
  }
}

/// Public so tests can measure the PAINTED COASTLINE rather than a declared
/// field — the shape is generated, so its bounds are the only honest statement
/// of what a reader sees.
class IslandPainter extends CustomPainter {
  IslandPainter({
    required this.identity,
    required this.rim,
    this.sunAltitude,
    this.moonIllumination,
    this.showSoundings = false,
  });

  final IslandIdentity identity;
  final Color rim;

  /// See [IslandMark.sunAltitude]. Null → no daylight expression at all.
  final double? sunAltitude;

  /// The moon's illuminated fraction, 0 new to 1 full. Null → no moonlight.
  final double? moonIllumination;

  /// Chart soundings in the water. OFF by default — see [_paintSoundings];
  /// unlike everything else here it is not gated on the island having a clock,
  /// so switching it on changes every mark for everyone.
  final bool showSoundings;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // The water, LIT DIRECTIONALLY — this single gradient is both the day/night
    // dimming and the terminator, because they were never two things.
    //
    // The first cut drew a uniform dim PLUS a shadow band on top, and the two
    // fought: if the whole disc darkens, the terminator has nothing to fall
    // across, so the boundary was invisible at every hour. Here the sun's
    // altitude is evaluated at the TOP and BOTTOM of the disc and the fill
    // interpolates between them, so a fade is what the mark IS rather than a
    // layer added to it. At noon both ends sit in the lit range and it reads as
    // flat daylight; at midnight both sit dark; through dawn and dusk the
    // boundary genuinely sweeps.
    canvas.drawCircle(c, r, _waterPaint(c, r));

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

    _paintSoundings(canvas, size);
    canvas.drawPath(landPath(size), _landPaint(size));
    // After the land so the glow sits ON the shore, before the point lights so
    // they are not blurred into it.
    _paintBioluminescence(canvas, size);

    // Last: the lantern sits ON TOP of the night, or the night would put it out.
    _paintStars(canvas, size);
    _paintLantern(canvas, size);
  }

  /// The coastline, as a path — extracted so it can be MEASURED.
  ///
  /// The shape is generated, so "islands come in different proportions" is
  /// a claim about pixels that no declared field can stand in for. Handing
  /// tests the actual path is what lets them assert on bounds instead of on
  /// the seed arithmetic that is supposed to produce them.
  Path landPath(Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    // The land. An island is not a bumpy circle — real ones are LONG or FAT,
    // they lie at an angle, and their coastlines have a couple of decisive
    // features rather than uniform ripple. All four of those vary here, each
    // from its own slice of the seed, which is what makes two islands read as
    // different PLACES rather than the same blob wearing different dents.
    //
    // The first cut varied only the ripple, on a fixed 0.86 squash. Every
    // island came out the same egg. Nick: "long islands, fat, they should look
    // like islands too."
    final s = identity.shapeSeed;

    // ELONGATION, 0.45 (a long spit) to 1.0 (round). The single biggest driver
    // of "that is a different island" at a glance.
    final aspect = 0.45 + ((s & 0xF) / 15.0) * 0.55;

    // ...and the ANGLE it lies at. Without this every long island points the
    // same way, which reads as one island rendered badly rather than several.
    final tilt = ((s >> 4) & 0x1F) / 32.0 * math.pi;

    // Coastline. Amplitudes are deliberately uneven: one dominant feature (a
    // bay or a headland), one medium, one fine. Equal amplitudes average out
    // into that same uniform ripple.
    final amps = [
      0.14 + ((s >> 9) & 0x7) / 28.0, // 0.14 – 0.39, the dominant feature
      0.05 + ((s >> 12) & 0x7) / 70.0,
      0.03 + ((s >> 15) & 0x3) / 90.0,
    ];
    // Which harmonic carries the dominant feature — 2 lobes reads as a bay, 3
    // as a headland, 4 as a scatter. Varying it stops every island having the
    // same number of "arms".
    final lobes = 2 + ((s >> 17) & 0x3);
    final phases = [
      ((s >> 19) & 0xF) * math.pi / 8,
      ((s >> 23) & 0x7) * math.pi / 4,
      ((s >> 26) & 0x7) * math.pi / 4,
    ];

    final land = Path();
    const steps = 72;
    final base = r * 0.60;
    final cosT = math.cos(tilt);
    final sinT = math.sin(tilt);
    for (var i = 0; i <= steps; i++) {
      final t = i / steps * 2 * math.pi;
      final k =
          1 +
          amps[0] * math.sin(lobes * t + phases[0]) +
          amps[1] * math.sin((lobes + 2) * t + phases[1]) +
          amps[2] * math.sin(7 * t + phases[2]);
      // Stretch along one axis, THEN rotate — squashing after the rotation
      // would just re-round every island back towards the circle.
      final x = math.cos(t) * base * k;
      final y = math.sin(t) * base * k * aspect;
      final p = c + Offset(x * cosT - y * sinT, x * sinT + y * cosT);
      i == 0 ? land.moveTo(p.dx, p.dy) : land.lineTo(p.dx, p.dy);
    }
    land.close();
    return land;
  }

  /// Land is PALE, water is dark — the way a chart prints, and the reason is
  /// legibility rather than authenticity. The first cut drew land as the water
  /// darkened, which at 18px read as a hole punched in a coloured disc: the
  /// silhouette did no identifying work at all. It keeps a trace of the water's
  /// hue rather than going white, so the medallion stays one colour idea.
  /// The night factor: 0 in full day, 1 at midnight.
  double get _night =>
      sunAltitude == null ? 0 : ((1 - sunAltitude!) / 2).clamp(0.0, 1.0);

  /// How dark it is at a given sun altitude: 0 full day, 1 full night.
  ///
  /// **SMOOTHSTEP ACROSS A NARROW BAND, NOT A LINEAR RAMP, and the difference
  /// is the whole feature.** Linear in altitude, fed a linear spatial ramp,
  /// produces another linear ramp — a gradient whose LEVEL shifts with the hour
  /// but which never contains an edge. No width or depth tuning can put a
  /// boundary into it, because a straight line has none to find. The first two
  /// attempts here were both tuning a model that could not represent the target
  /// state.
  ///
  /// A terminator is a steep transition that MOVES: near-flat in full daylight,
  /// near-flat in full night, and steep across the horizon. [_horizonWidth] is
  /// how soft that edge is — the sun is a disc rather than a point, so it must
  /// not be a hard cut either.
  static const _horizonWidth = 0.42;

  double _nightFactor(double altitude) {
    final x = ((-altitude + _horizonWidth) / (2 * _horizonWidth)).clamp(
      0.0,
      1.0,
    );
    return x * x * (3 - 2 * x);
  }

  /// The sun's altitude AT A POINT on the disc, north-to-south.
  ///
  /// [t] runs 0 at the top edge to 1 at the bottom. The spread is what makes a
  /// terminator possible at all: with a single altitude for the whole mark
  /// there is no boundary to see, only a dimmer. 1.15 is slightly more than the
  /// disc so dawn and dusk push the boundary right across rather than parking
  /// it permanently in view.
  double _altitudeAt(double t) =>
      (sunAltitude! + (0.5 - t) * 1.6).clamp(-1.0, 1.0);

  /// Water colour for a given local altitude. HUE NEVER MOVES — identity lives
  /// there, and an island at midnight must still be unmistakably that island.
  /// Only lightness and saturation ride the sun, which is the channel identity
  /// is not using.
  /// How much this altitude sits IN the horizon band, 0 away from it, 1 on it.
  ///
  /// Golden hour is a real optical fact and a nearly free one here: light near
  /// the horizon travels through more atmosphere, the short wavelengths
  /// scatter out, and what lands is warm. The terminator band already exists as
  /// a computed quantity, so tinting it costs one lerp and buys the single most
  /// recognisable thing about dawn and dusk.
  double _goldenness(double altitude) =>
      (1 - (altitude.abs() / _horizonWidth)).clamp(0.0, 1.0);

  Color _waterAt(double altitude) {
    final hsl = HSLColor.fromColor(identity.water);
    final night = _nightFactor(altitude);
    final base = hsl
        // Not to zero: a black disc stops being a colour and the island stops
        // being recognisable, which costs the mark its whole job to buy a
        // slightly better sunset.
        .withLightness((hsl.lightness - 0.30 * night).clamp(0.06, 1.0))
        // Colour drains at night the way it does for an eye at night — but
        // ONLY 22%, down from 50%. Rendered as a fleet of 24 the heavier drain
        // pulled every island toward a common dusty pastel: identity was
        // preserved in the hue and COMPRESSED in practice, so the marks became
        // hardest to tell apart at exactly the hour you most need to know which
        // island you are looking at. n=2 could not show this; n=24 showed it
        // immediately. The mark's job outranks the atmosphere.
        .withSaturation((hsl.saturation * (1 - 0.22 * night)).clamp(0.0, 1.0))
        .toColor();
    // Warm, but gently — 0.30 max. The hue is the island's IDENTITY, and a
    // sunset that repaints every island the same amber would trade the mark's
    // whole job for a nice sky.
    final gold = Color.lerp(
      base,
      const Color(0xFFE08A4A),
      0.30 * _goldenness(altitude),
    )!;
    // MOONLIGHT, and only where it is actually night. A cold pale wash whose
    // strength is the illuminated fraction, so an island's nights differ across
    // a month instead of all being the same night. Capped low (0.22) for the
    // same reason as the sunset: identity lives in the hue.
    final moon = moonIllumination;
    if (moon == null) return gold;
    return Color.lerp(gold, const Color(0xFFBFD4E8), 0.22 * moon * night)!;
  }

  Paint _waterPaint(Offset c, double r) {
    if (sunAltitude == null) return Paint()..color = identity.water;
    // Five stops rather than two: lightness through a night factor is not
    // linear in the parameter, so a two-stop ramp visibly bends the wrong way
    // through dusk.
    const n = 12;
    return Paint()
      ..shader = ui.Gradient.linear(
        Offset(c.dx, c.dy - r),
        Offset(c.dx, c.dy + r),
        [for (var i = 0; i < n; i++) _waterAt(_altitudeAt(i / (n - 1)))],
        [for (var i = 0; i < n; i++) i / (n - 1)],
      );
  }

  /// Depth soundings: the little marks a printed chart scatters in its water.
  ///
  /// **NOT TIME-DRIVEN, and that makes it a different KIND of change from
  /// everything else here.** Sun, moon, lantern and stars all vanish when
  /// `sunAltitude` is null, so the shipped mark is untouched until an island
  /// publishes a timezone. Soundings are chart furniture: they would be there
  /// at every hour, on every island, for every user, immediately. So this is
  /// gated on its own flag and defaults OFF — changing what every mark looks
  /// like always is a decision, not a detail.
  ///
  /// Kept extremely faint and few. A real chart's soundings are dense because
  /// it is a metre wide; at 18px beside the composer, four legible dots would
  /// be four pieces of noise competing with the silhouette that does the
  /// identifying.
  void _paintSoundings(Canvas canvas, Size size) {
    if (!showSoundings) return;
    final land = landPath(size);
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final unit = size.width / 44.0;
    final hsl = HSLColor.fromColor(identity.water);
    final ink = hsl
        .withLightness((hsl.lightness + 0.22).clamp(0.0, 1.0))
        .toColor();
    var rnd = (identity.shapeSeed * 40503) & 0x7FFFFFFF;
    final placed = <Offset>[];
    final minGap = size.width * 0.17;
    for (var i = 0; i < 260 && placed.length < 6; i++) {
      rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
      final x = c.dx - r + (rnd % 1000) / 1000.0 * 2 * r;
      rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
      final y = c.dy - r + (rnd % 1000) / 1000.0 * 2 * r;
      final p = Offset(x, y);
      if ((p - c).distance > r * 0.82) continue;
      // Off the land, and not hugging it either — a sounding printed on the
      // coastline reads as a defect in the outline.
      if (land.contains(p)) continue;
      if (land.contains(p.translate(unit * 2, 0)) ||
          land.contains(p.translate(-unit * 2, 0))) {
        continue;
      }
      if (placed.any((q) => (q - p).distance < minGap)) continue;
      canvas.drawCircle(
        p,
        0.55 * unit,
        Paint()..color = ink.withValues(alpha: 0.30),
      );
      placed.add(p);
    }
  }

  /// Bioluminescence: the coastline glows faintly at deep night.
  ///
  /// Real, and the reason it belongs on THIS mark rather than being whimsy: the
  /// glow happens where water moves against land, which is exactly the path
  /// this painter already has. It costs one stroke of a path already computed.
  ///
  /// DEEP NIGHT ONLY, and under the moon's own wash — a bright moon drowns it,
  /// which is true of the real thing and also keeps the two night effects from
  /// competing for the same pixels.
  void _paintBioluminescence(Canvas canvas, Size size) {
    final deep = ((_night - 0.72) / 0.28).clamp(0.0, 1.0);
    if (deep <= 0) return;
    // Drowned by moonlight, the way it actually is.
    final moonDamp = 1 - 0.75 * (moonIllumination ?? 0);
    final strength = deep * moonDamp;
    if (strength <= 0.02) return;
    final unit = size.width / 44.0;
    canvas.drawPath(
      landPath(size),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * unit
        ..color = const Color(0xFF7FE7D4).withValues(alpha: 0.34 * strength)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.6 * unit),
    );
  }

  /// A few faint stars on the night water.
  ///
  /// SEEDED FROM THE ISLAND, so your island always has YOUR stars — the same
  /// argument as the lantern's bay. They are drawn on the water only: a star
  /// over the land would read as a second lantern, and the mark is a chart seen
  /// from above, where the sky is the sea.
  ///
  /// Deliberately few and faint. This is the detail most likely to tip the mark
  /// from atmospheric into busy, and it lives at 18px beside the composer where
  /// four bright dots would just be noise.
  void _paintStars(Canvas canvas, Size size) {
    final glow = ((_night - 0.55) / 0.30).clamp(0.0, 1.0);
    if (glow <= 0) return;
    final land = landPath(size);
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final unit = size.width / 44.0;
    var rnd = (identity.shapeSeed * 2654435761) & 0x7FFFFFFF;
    final placed = <Offset>[];
    // THREE, AND SPACED. Uniform random over the water clumps — two dots a few
    // pixels apart read as a rendering artefact rather than a sky, which is
    // exactly what the first cut looked like. A minimum separation is the
    // cheapest thing that makes scattered points read as stars.
    final minGap = size.width * 0.22;
    for (var i = 0; i < 200 && placed.length < 3; i++) {
      rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
      final x = c.dx - r + (rnd % 1000) / 1000.0 * 2 * r;
      rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
      final y = c.dy - r + (rnd % 1000) / 1000.0 * 2 * r;
      final p = Offset(x, y);
      // Inside the disc, off the land, and off the rim (a star ON the hairline
      // reads as a chip in the edge).
      if ((p - c).distance > r * 0.86) continue;
      if (land.contains(p)) continue;
      if (placed.any((q) => (q - p).distance < minGap)) continue;
      rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
      final twinkle = 0.35 + (rnd % 100) / 100.0 * 0.45;
      canvas.drawCircle(
        p,
        0.5 * unit,
        Paint()
          ..color = const Color(0xFFFFFFFF).withValues(alpha: twinkle * glow),
      );
      placed.add(p);
    }
  }

  /// A single warm light on the land after dark. Somebody is awake.
  ///
  /// **CLOCK-DERIVED, NOT PRESENCE.** It says nothing about whether anyone is
  /// actually there — presence was declined on shape (claude-tasks#3885: an
  /// ambient signal is safe when it is act-caused and self-expiring, and
  /// presence is neither, leaking by accumulation until it is a sleep diary).
  /// This is a drawing of a place at night, not a report about a person, and it
  /// accumulates nothing because it is a pure function of the hour.
  ///
  /// Placed from the SHAPE SEED, so an island's lantern is always in the same
  /// bay — part of its identity rather than a twinkle. Rejection-sampled inside
  /// the coastline: a lantern floating in the water is a firefly, and the whole
  /// charm is that it is on the land.
  void _paintLantern(Canvas canvas, Size size) {
    // Fades in through dusk rather than switching on — a pop at a threshold
    // would make the mark flicker at exactly the hour people are watching it.
    final glow = ((_night - 0.45) / 0.35).clamp(0.0, 1.0);
    if (glow <= 0) return;

    final land = landPath(size);
    final b = land.getBounds();
    var rnd = identity.shapeSeed | 1;
    Offset? spot;
    // INTERIOR, NOT MERELY INSIDE. Accepting the first point that satisfies
    // `contains` puts the lantern on the COASTLINE almost every time: the
    // bounding box is mostly water at its corners, so the first hit is
    // overwhelmingly likely to be just barely within the outline. Rendered at
    // 160px both islands had their light half in the sea. Requiring a margin —
    // four probes around the candidate must ALSO be land — pushes it into the
    // island's body, which is the only place a lantern makes sense.
    // A LANTERN WANTS A HARBOUR. Two rounds of this were wrong in opposite
    // directions: take the first point inside the outline and it lands ON the
    // coast (the bounding box is mostly water, so the first hit hugs the
    // edge); require a fat margin from the coast and it converges on the
    // island's MIDDLE, which reads as a bullseye. Across 24 islands the fat
    // blobby silhouettes all lit up dead centre.
    //
    // So the test is now two-sided: far enough from the water not to be
    // floating in it, and CLOSE enough that there is water nearby — which is
    // what a harbour is. Distance-from-coast alone can only ever push inland;
    // it has no way to express "near the shore".
    final margin = size.width * 0.045;
    final harbourReach = size.width * 0.16;
    final candidates = <Offset>[];
    for (var i = 0; i < 240 && candidates.length < 24; i++) {
      // Deterministic LCG, so the lantern never moves between frames or
      // devices: an island's light is always in the same bay.
      rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
      final x = b.left + (rnd % 1000) / 1000.0 * b.width;
      rnd = (rnd * 1103515245 + 12345) & 0x7FFFFFFF;
      final y = b.top + (rnd % 1000) / 1000.0 * b.height;
      final p = Offset(x, y);
      if (!land.contains(p)) continue;
      // Not on the waterline.
      if (!land.contains(p.translate(margin, 0)) ||
          !land.contains(p.translate(-margin, 0)) ||
          !land.contains(p.translate(0, margin)) ||
          !land.contains(p.translate(0, -margin))) {
        continue;
      }
      // ...but within sight of it. At least one direction must reach water
      // inside `harbourReach`, which excludes the deep interior.
      final nearShore =
          !land.contains(p.translate(harbourReach, 0)) ||
          !land.contains(p.translate(-harbourReach, 0)) ||
          !land.contains(p.translate(0, harbourReach)) ||
          !land.contains(p.translate(0, -harbourReach));
      if (!nearShore) continue;
      candidates.add(p);
    }
    if (candidates.isNotEmpty) {
      spot = candidates[(identity.shapeSeed >> 3) % candidates.length];
    }
    // A shape so thin that 48 samples all missed. Draw nothing rather than
    // guess a point — an off-island lantern is worse than none.
    if (spot == null) return;

    final unit = size.width / 44.0;
    canvas.drawCircle(
      spot,
      2.6 * unit,
      Paint()
        ..color = const Color(0xFFFFC46B).withValues(alpha: 0.16 * glow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.2 * unit),
    );
    canvas.drawCircle(
      spot,
      0.9 * unit,
      Paint()..color = const Color(0xFFFFD79A).withValues(alpha: 0.95 * glow),
    );
  }

  /// Land colour at a given local altitude.
  ///
  /// Land dims with the water but stays PALE RELATIVE TO IT, always — that
  /// contrast is what makes the silhouette do identifying work at all. Drawn
  /// dark it reads at 18px as a hole punched in a coloured disc, which is what
  /// the first cut of this mark did. So night moves both and never closes the
  /// gap: 0.86 down to 0.56, against water going 0.42 down to 0.12.
  Color _landAt(double altitude) {
    final hsl = HSLColor.fromColor(identity.water);
    final night = _nightFactor(altitude);
    return hsl
        .withLightness(0.86 - 0.30 * night)
        .withSaturation((hsl.saturation * 0.5).clamp(0.0, 1.0))
        .toColor();
  }

  /// THE TERMINATOR CROSSES THE COASTLINE.
  ///
  /// The land used to take a single global night factor while the water was lit
  /// directionally, so the boundary swept the sea and stopped dead at the
  /// shore — a brightly lit island floating on a dark ocean, which is not a
  /// thing that happens. The land now reads from the same [_altitudeAt] as the
  /// water, over the same disc-spanning axis, so one boundary crosses the whole
  /// mark.
  Paint _landPaint(Size size) {
    if (sunAltitude == null) {
      final hsl = HSLColor.fromColor(identity.water);
      return Paint()
        ..color = hsl
            .withLightness(0.86)
            .withSaturation((hsl.saturation * 0.5).clamp(0.0, 1.0))
            .toColor();
    }
    const n = 12;
    final r = size.width / 2;
    final c = Offset(size.width / 2, size.height / 2);
    return Paint()
      ..shader = ui.Gradient.linear(
        Offset(c.dx, c.dy - r),
        Offset(c.dx, c.dy + r),
        [for (var i = 0; i < n; i++) _landAt(_altitudeAt(i / (n - 1)))],
        [for (var i = 0; i < n; i++) i / (n - 1)],
      );
  }

  @override
  bool shouldRepaint(IslandPainter old) =>
      old.identity.water != identity.water ||
      old.identity.shapeSeed != identity.shapeSeed ||
      old.rim != rim ||
      old.sunAltitude != sunAltitude ||
      old.moonIllumination != moonIllumination ||
      old.showSoundings != showSoundings;
}
