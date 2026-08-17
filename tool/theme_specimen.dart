// A palette bench: every shipped theme, side by side, on real pixels.
//
//   flutter run -t tool/theme_specimen.dart -d macos
//
// It renders EVERY preset in `kThemePresets` in the chosen brightness, so a new
// look shows up here the moment it joins the registry — the bench cannot fall
// behind the picker. Click the brightness toggle to swap all panels at once;
// comparing looks and comparing brightnesses are different questions and the
// bench answers one at a time.
//
// WHY THIS EXISTS. The light theme's failure mode is looking fine in code and
// wrong on screen — contrast that computes to spec and reads as mud, a lamp that
// vanishes on a bright ground, a hairline that disappears. The app itself cannot
// answer that quickly: its chat surface is behind a passkey gate, and rendering
// one theme at a time makes comparison a memory exercise. This renders both at
// once, with no auth, in about a second.
//
// WHAT IT PROVES, AND WHAT IT DOES NOT. Everything below is a STOCK Material
// widget. That is deliberate and it is the whole basis of the instrument: the
// theme's stated design is that every value routes through standard `ThemeData`
// fields precisely so an undecorated widget comes out maritime for free. So this
// bench measures exactly the claim the theme makes.
//
// It does NOT prove the chat screen. The composer is a custom widget with its
// own waterline/seal/lamp states (locked separately by
// `test/features/chat/composer_waterline_test.dart`), and the immersive call
// screen is deliberately theme-independent. Those need the real app.
import 'package:aiko_chat_app/app/theme/maritime_theme.dart' show kMaritimeMono;
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter/material.dart';

void main() => runApp(const _Bench());

class _Bench extends StatefulWidget {
  const _Bench();

  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  var _brightness = Brightness.light;

  @override
  Widget build(BuildContext context) {
    final isDark = _brightness == Brightness.dark;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Stack(
        children: [
          Row(
            children: [
              for (final preset in kThemePresets)
                Expanded(
                  child: _Panel(
                    theme: isDark ? preset.darkTheme : preset.lightTheme,
                    label: '${preset.label.toUpperCase()} · '
                        '${isDark ? 'DARK' : 'LIGHT'}',
                  ),
                ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: () => setState(() {
                _brightness = isDark ? Brightness.light : Brightness.dark;
              }),
              icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
              label: Text(isDark ? 'to light' : 'to dark'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.theme, required this.label});

  final ThemeData theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    final s = theme.colorScheme;
    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          // Ellipsised: with three presets on the bench each panel is narrow
          // enough that the title and the actions fight for the same pixels.
          title: Text('# general  ·  $label', overflow: TextOverflow.ellipsis),
          titleSpacing: 8,
          actions: const [
            Icon(Icons.videocam_outlined),
            SizedBox(width: 12),
            Icon(Icons.more_vert),
            SizedBox(width: 8),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Someone else's message — a panel lifted off the ground.
            _Bubble(
              theme: theme,
              mine: false,
              who: 'robin',
              body: 'the harbour light is out again',
            ),
            const SizedBox(height: 8),
            // My own message — the signal-tinted panel.
            _Bubble(
              theme: theme,
              mine: true,
              who: 'you',
              body: 'noted. logging it against the chart.',
            ),
            const SizedBox(height: 20),

            // The emphasis relationship, rendered rather than asserted: these
            // two marks are the resting and armed states of one control.
            Text('EMPHASIS', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.verified_outlined, color: s.outlineVariant),
              const SizedBox(width: 6),
              Icon(Icons.send, color: s.outlineVariant),
              const SizedBox(width: 24),
              Icon(Icons.verified_outlined, color: s.primary),
              const SizedBox(width: 6),
              Icon(Icons.send, color: s.secondary),
              const SizedBox(width: 12),
              Text('rest → armed', style: theme.textTheme.bodySmall),
            ]),
            const SizedBox(height: 20),

            // The composer's three states. `_Waterline` and `_SealMark` are
            // private to chat_screen.dart, so this is a VERBATIM transcription
            // of their build methods (same widget tree, same ColorScheme
            // tokens, same 1.5px height) rather than the real widgets — it can
            // drift if they change, and the behavioural contract stays locked
            // by composer_waterline_test.dart. What it answers honestly is the
            // question that is pure colour and geometry: does a 1.5px rule in
            // `primary` read as IGNITED against this ground?
            Text('THE COMPOSER — rest / focused / armed',
                style: theme.textTheme.labelSmall),
            const SizedBox(height: 8),
            _ComposerState_(theme: theme, lit: false, armed: false),
            const SizedBox(height: 14),
            _ComposerState_(theme: theme, lit: true, armed: false),
            const SizedBox(height: 14),
            _ComposerState_(theme: theme, lit: true, armed: true),
            const SizedBox(height: 20),

            Text('CONTROLS', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: () {}, child: const Text('Send')),
              TextButton(onPressed: () {}, child: const Text('Cancel')),
              const Chip(label: Text('signed')),
              Switch(value: true, onChanged: (_) {}),
            ]),
            const SizedBox(height: 20),

            const TextField(
              decoration: InputDecoration(hintText: 'Write a message…'),
            ),
            const SizedBox(height: 20),

            // A hairline-separated list — the sidebar's construction.
            Card(
              child: Column(children: [
                const ListTile(
                  leading: Icon(Icons.tag),
                  title: Text('general'),
                  trailing: Text('3'),
                ),
                Divider(color: s.outline, height: 1),
                const ListTile(
                  leading: Icon(Icons.alternate_email),
                  title: Text('robin'),
                  subtitle: Text('the harbour light is out again'),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            Text('THE RAW TOKENS', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _Swatch(c: s.surface, name: 'ground', on: s.onSurface),
              _Swatch(c: s.surfaceContainer, name: 'panel', on: s.onSurface),
              _Swatch(c: s.surfaceContainerHigh, name: 'high', on: s.onSurface),
              _Swatch(c: s.primaryContainer, name: 'mine', on: s.onSurface),
              _Swatch(c: s.primary, name: 'signal', on: s.onPrimary),
              _Swatch(c: s.secondary, name: 'beacon', on: s.onSecondary),
              _Swatch(c: s.error, name: 'alarm', on: s.onError),
              _Swatch(c: s.outline, name: 'hairline', on: s.onSurface),
            ]),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

/// One composer state, transcribed from `chat_screen.dart`'s `Composer` /
/// `_Waterline` / `_SealMark`. [lit] is the focus state (the rule grows in
/// `primary` over the resting hairline); [armed] is "there is something to
/// send" (seal → `primary`, lamp → `secondary`).
class _ComposerState_ extends StatelessWidget {
  const _ComposerState_({
    required this.theme,
    required this.lit,
    required this.armed,
  });

  final ThemeData theme;
  final bool lit;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    final s = theme.colorScheme;
    final label = armed ? 'armed' : (lit ? 'focused' : 'rest');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          // The seal — dim until there is something to sign.
          Icon(Icons.verified_outlined,
              size: 20, color: armed ? s.primary : s.outlineVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              armed ? 'the harbour light is out again' : 'Write a message…',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: armed ? s.onSurface : s.onSurfaceVariant,
              ),
            ),
          ),
          // The lamp — touch layouts only in the real app, shown here so the
          // "one fact, two readings" pairing with the seal is visible.
          Icon(Icons.send,
              size: 20, color: armed ? s.secondary : s.outlineVariant),
          const SizedBox(width: 10),
          SizedBox(
            width: 62,
            child: Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontFamily: kMaritimeMono)),
          ),
        ]),
        const SizedBox(height: 7),
        // _Waterline, verbatim: a resting hairline with the lit rule grown over
        // it from the left. 1.5px is the real height.
        SizedBox(
          height: 1.5,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: s.outlineVariant),
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: lit ? 1.0 : 0.0,
                  // The transcription originally omitted this, exactly as the
                  // real widget did — and rendered zero-height, exactly as the
                  // real widget did. Reproducing the bug is the strongest
                  // evidence the copy was faithful. Both carry the fix now.
                  heightFactor: 1.0,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(color: s.primary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.theme,
    required this.mine,
    required this.who,
    required this.body,
  });

  final ThemeData theme;
  final bool mine;
  final String who;
  final String body;

  @override
  Widget build(BuildContext context) {
    final s = theme.colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: mine ? s.primaryContainer : s.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: s.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(who,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              // The instrument voice — mono, for ids and timestamps.
              Text('14:21',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontFamily: kMaritimeMono)),
              const SizedBox(width: 6),
              Icon(Icons.verified_outlined, size: 13, color: s.primary),
            ]),
            const SizedBox(height: 3),
            Text(body, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.c, required this.name, required this.on});

  final Color c;
  final String name;
  final Color on;

  @override
  Widget build(BuildContext context) => Container(
        width: 74,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: Text(name,
            style: TextStyle(color: on, fontSize: 10, fontFamily: kMaritimeMono)),
      );
}
