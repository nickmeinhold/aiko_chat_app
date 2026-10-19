// Synthesise the macOS ringtone — ours from first principles, so nothing to
// license.
//
// The Mac is the one platform where the app draws its own ring (no CallKit, no
// native ring screen), and the in-app ring was silent: on phones the OS has
// always supplied the sound. This writes the sound the Mac plays while a call
// rings.
//
// A marimba-like voice (a decaying sine plus its 4th partial, which is what
// makes a bar sound wooden rather than electronic): a rising three-note figure
// twice, then a rest. One cycle is the whole file; the native side loops it.
//
//   dart run tool/make_ringtone.dart   # rewrites the asset in place
//
// Deterministic: the same script always writes the same bytes.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _rate = 44100;
const _out = 'macos/Runner/Assets.xcassets/Ring.dataset/ring.wav';

// E5, G#5, B5: a major triad, bright without being shrill.
const _notes = [659.26, 830.61, 987.77];
const _step = 0.13; // seconds between notes in a figure
const _figureGap = 0.55; // seconds from one figure to the next
const _cycle = 3.0; // seconds; what follows the two figures is the rest
const _decay = 7.0; // per second: how fast a struck bar fades

/// One struck bar, [t] seconds after the strike.
double _bar(double t, double f) {
  final env = exp(-_decay * t) * min(1.0, t / 0.004); // 4 ms attack: no click
  final wood = 0.25 * sin(2 * pi * 4 * f * t) * exp(-3 * _decay * t);
  return env * (sin(2 * pi * f * t) + wood);
}

void main() {
  final strikes = [
    for (var fig = 0; fig < 2; fig++)
      for (var i = 0; i < _notes.length; i++)
        (at: fig * _figureGap + i * _step, f: _notes[i]),
  ];
  final n = (_rate * _cycle).round();
  final samples = List<double>.generate(n, (k) {
    final t = k / _rate;
    var s = 0.0;
    for (final (:at, :f) in strikes) {
      if (t >= at) s += _bar(t - at, f);
    }
    return s;
  });
  final peak = samples.map((s) => s.abs()).reduce(max);
  final gain = 0.6 / peak; // headroom: a ring should be clear, not loud

  final pcm = ByteData(n * 2);
  for (var k = 0; k < n; k++) {
    pcm.setInt16(k * 2, (samples[k] * gain * 32767).round(), Endian.little);
  }
  final header = ByteData(44)
    ..setUint32(0, 0x52494646, Endian.big) // "RIFF"
    ..setUint32(4, 36 + n * 2, Endian.little)
    ..setUint32(8, 0x57415645, Endian.big) // "WAVE"
    ..setUint32(12, 0x666d7420, Endian.big) // "fmt "
    ..setUint32(16, 16, Endian.little) // PCM chunk size
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, _rate, Endian.little)
    ..setUint32(28, _rate * 2, Endian.little) // byte rate
    ..setUint16(32, 2, Endian.little) // block align
    ..setUint16(34, 16, Endian.little) // bits per sample
    ..setUint32(36, 0x64617461, Endian.big) // "data"
    ..setUint32(40, n * 2, Endian.little);

  final repo = File.fromUri(Platform.script).parent.parent.path;
  File('$repo/$_out')
    ..createSync(recursive: true)
    ..writeAsBytesSync([
      ...header.buffer.asUint8List(),
      ...pcm.buffer.asUint8List(),
    ]);
  stdout.writeln('wrote $_out (${_cycle}s, $n samples)');
}
