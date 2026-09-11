import 'dart:math' as math;

/// Where the sun is over an island, as one continuous number.
///
/// **+1 at local noon, 0 at 06:00 and 18:00, -1 at local midnight.**
///
/// ONE INPUT, and that is the design rather than a shortcut. The mark expresses
/// time two ways — a terminator sweeping the disc, and the water's own
/// luminance — and both read from this single value, so they cannot disagree
/// about what time it is. Two separately-computed notions of "how light is it"
/// would drift the moment either was tuned.
///
/// **IT IS CLOCK TIME, NOT ASTRONOMY, and the code says so because the pixels
/// cannot.** A real terminator needs latitude: at 60°N in June the sun is up at
/// 03:00 and this will say it is dark. Modelling that needs a coordinate the
/// island does not publish and probably should not — a chat island's latitude
/// is a fact about its operator's house. The honest version treats 06:00 as
/// dawn everywhere, which is wrong by up to a couple of hours at temperate
/// latitudes and wrong by more near the poles, in exchange for needing nothing
/// but a timezone.
///
/// So the claim this supports is "it is night-ish there", never "the sun has
/// set there". That is the claim the feature actually needs: the human question
/// is *is this a reasonable hour to reach these people*, and that question is
/// answered by the clock, not by the sun.
double sunAltitudeAt(DateTime islandLocalTime) {
  final hours = islandLocalTime.hour + islandLocalTime.minute / 60.0;
  return -math.cos(hours / 24.0 * 2 * math.pi);
}

/// The island's local time, or null when the island has not said where it is.
///
/// **ABSENT IS THE COMMON CASE and must stay legal.** No island publishes a
/// timezone today (asked for as a cosmetic-tier directory field, ADR-0008), and
/// a mark that invented one would be showing the VIEWER's time-of-day wearing
/// the island's face — decorative, and quietly lying about whose day it is.
/// Null here means the mark draws exactly as it did before any of this existed.
DateTime? islandLocalTimeNow(Duration? utcOffset, {DateTime? nowUtc}) {
  if (utcOffset == null) return null;
  return (nowUtc ?? DateTime.now().toUtc()).add(utcOffset);
}

/// The moon's illuminated fraction: 0 at new, 1 at full.
///
/// **A SECOND, SLOWER CLOCK under the daily one.** The sun says what time it is
/// there; the moon says roughly where in the month you are, so an island's
/// nights are not all the same night — deep dark near new, silver near full.
///
/// GLOBAL ASTRONOMY, which is why it can exist at all here. Phase is very
/// nearly the same for every observer on Earth at a given instant, so unlike
/// sunrise it needs no latitude — and a chat island's latitude is a fact about
/// its operator's house, which is precisely why the terminator above is honest
/// clock time rather than real solar position. The moon is the one piece of
/// real astronomy this mark can afford.
///
/// Mean-synodic approximation from a known new moon. It drifts by a few hours
/// against the true phase because the orbit is elliptical and the month is not
/// constant — irrelevant for a wash of light on a 44px disc, and named here so
/// nobody later mistakes it for an ephemeris.
double moonIlluminationAt(DateTime utc) {
  const synodicDays = 29.530588853;
  final knownNewMoon = DateTime.utc(2000, 1, 6, 18, 14);
  final days = utc.difference(knownNewMoon).inMicroseconds / 86400e6;
  final phase = (days % synodicDays) / synodicDays;
  return (1 - math.cos(2 * math.pi * phase)) / 2;
}
