// A palette bench: both shipped themes, side by side, on real pixels.
//
//   flutter run -t tool/theme_specimen.dart -d macos
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
import 'package:aiko_chat_app/app/theme/maritime_theme.dart';
import 'package:flutter/material.dart';

void main() => runApp(const _Bench());

class _Bench extends StatelessWidget {
  const _Bench();

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          children: [
            Expanded(child: _Panel(theme: lightTheme(), label: 'NOON')),
            Expanded(child: _Panel(theme: maritimeTheme(), label: 'NIGHT')),
          ],
        ),
      );
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
          title: Text('# general  ·  $label'),
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
