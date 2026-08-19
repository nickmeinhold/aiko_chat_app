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
  });

  final String baseUrl;
  final double size;

  /// Tapping the mark should take you to the island picker — the mark answers
  /// "where am I", so the obvious next question is "can I go somewhere else".
  ///
  /// Passed IN rather than routed from here: this widget lives in `core/` and
  /// knowing about `/settings/gateway` would tie a drawing to the router.
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
  IslandPainter({required this.identity, required this.rim});

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

    canvas.drawPath(landPath(size), _landPaint());
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
  Paint _landPaint() {
    final hsl = HSLColor.fromColor(identity.water);
    return Paint()
      ..color = hsl
          .withLightness(0.86)
          .withSaturation((hsl.saturation * 0.5).clamp(0.0, 1.0))
          .toColor();
  }

  @override
  bool shouldRepaint(IslandPainter old) =>
      old.identity.water != identity.water ||
      old.identity.shapeSeed != identity.shapeSeed ||
      old.rim != rim;
}
