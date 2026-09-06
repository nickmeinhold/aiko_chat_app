// Every theme slot that installs a bare `TextStyle` — does the reader's face
// survive it?
//
// This is the CLASS behind claude-tasks#3958. That bug was found in one slot,
// `appBarTheme.titleTextStyle`, and fixed in 654bbdf. The fix was correct and
// the class was never swept: `theme_builder.dart` hands a bare `TextStyle` to
// five more slots, and two frames already sitting in the blind playtester's
// first sweep — `block-person/frames/03.png` and `report-message/frames/03.png`
// — show the confirmation snackbar rendering as solid black blocks, which is
// the same signature the island title showed.
//
// WHY A BARE STYLE IS NOT AUTOMATICALLY A BUG, and why this file measures
// instead of asserting a rule. Two things a widget can do with a themed style:
//
//   REPLACE — install it AS the `DefaultTextStyle` (or hand it straight to the
//             span). A null family then means null family, and the reader's
//             chosen face is gone. This is what `AppBar` does.
//   MERGE   — `.merge()` it onto the ambient style. A null family then inherits,
//             and a bare `TextStyle` is completely harmless.
//
// `inputDecorationTheme.hintStyle` is the standing proof that MERGE is real:
// it is every bit as bare as the others, and the sweep's `search/frames/01.png`
// shows "Search messages" in real glyphs. A rule of the form "bare TextStyle in
// a theme is a bug" would have condemned it wrongly.
//
// So the discriminator is not the source, it is the RENDER TREE — what family
// did the span that actually paints this text resolve to? That is the question
// that settled #3958 after three hypotheses had died to reasoning about it, and
// it is the only question asked here.
//
// THE FIXTURE MUST BE ABLE TO FAIL. Every case first asserts that the chosen
// face reached the text theme at all. With the system font both sides are null
// and every comparison passes whether or not the bug is present — a green that
// measures nothing. That check is not ceremony; it is what makes the rest of
// the file readable as evidence.
import 'package:aiko_chat_app/app/theme/app_fonts.dart';
import 'package:aiko_chat_app/app/theme/theme_builder.dart';
import 'package:aiko_chat_app/app/theme/theme_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// A face the reader can actually pick. The system font is the uninteresting
/// case — null family on both sides of every comparison.
final _chosen = kAppFonts.firstWhere((f) => f.googleFamily != null);

final _palette = kThemePresets.first.light;

ThemeData get _theme => buildTheme(_palette, font: _chosen);

/// The family the rest of the app resolved to. Everything here is compared
/// against this, never against a literal, so the test survives the font list
/// changing.
String? get _bodyFamily => _theme.textTheme.bodyMedium?.fontFamily;

/// The family the span painting [text] actually resolved to.
///
/// Reads the RENDER TREE, not the theme. A themed style only matters if it
/// reaches the span, and whether it does is a property of the widget, not of
/// the style.
///
/// Matches on `toPlainText()` rather than `TextSpan.text`, because not every
/// widget puts its string in the root span: `Tooltip` builds its message as a
/// CHILD span, leaving the root's `text` null. Reading the wrong field found
/// nothing and reported it as a failing slot — see the note in the tooltip
/// case.
String? _paintedFamily(WidgetTester tester, String text) {
  final rich = find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText() == text,
  );
  expect(
    rich,
    findsAtLeast(1),
    reason:
        'nothing painted the text "$text", so there is no family to read and '
        'this case is void rather than passing',
  );
  final span = (tester.widget<RichText>(rich.first)).text;
  return span.style?.fontFamily;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  // No network from a unit test. `GoogleFonts` otherwise tries to FETCH Inter
  // over HTTP on the first render, which makes this file slow, flaky offline,
  // and quietly dependent on fonts.gstatic.com being up.
  //
  // Turning fetching off does not weaken the measurement, because the
  // measurement never needed the GLYPHS — it reads which family the span
  // RESOLVED to, and `GoogleFonts` names the family whether or not the bytes
  // ever arrive. The fixture check below is what proves that is still true: if
  // disabling the fetch ever stopped the family reaching the text theme, every
  // case would go void rather than silently passing on two nulls.
  //
  // It DOES leave a line in the run output, once per render: "allowRuntimeFetching
  // is false but font Inter-Regular was not found in the application assets".
  // That is true and harmless — the bytes really are absent — and it is left in
  // rather than silenced, because the alternative is a test that phones
  // fonts.gstatic.com to prove something about a string.
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() {
    // The fixture check, run before every case rather than once, because a
    // case that silently lost the face would otherwise report a clean pass.
    expect(
      _bodyFamily,
      isNotNull,
      reason:
          'the fixture is void: ${_chosen.id} did not reach the text theme, so '
          'no comparison below can distinguish a fixed slot from a broken one',
    );
  });

  testWidgets('snackBarTheme.contentTextStyle', (tester) async {
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('blocked')),
          ),
          child: const Text('go'),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(
      _paintedFamily(tester, 'blocked'),
      _bodyFamily,
      reason:
          'the snackbar resolved a different face from the rest of the app — '
          'SnackBar installs contentTextStyle as the DefaultTextStyle for its '
          'content, so a bare TextStyle there drops the reader\'s choice. This '
          'is claude-tasks#3958 in a second slot; see block-person/frames/03.png',
    );
  });

  testWidgets('chipTheme.labelStyle', (tester) async {
    await _pump(tester, const Chip(label: Text('mine')));
    expect(
      _paintedFamily(tester, 'mine'),
      _bodyFamily,
      reason: 'the chip label resolved a different face from the rest of the app',
    );
  });

  testWidgets('tooltipTheme.textStyle', (tester) async {
    final key = GlobalKey(debugLabel: 'tip');
    await _pump(
      tester,
      Tooltip(key: key, message: 'hint', child: const Icon(Icons.info)),
    );
    // Drive the tooltip through its own state rather than a tap. A tap DID
    // NOT show it — the case then failed on "nothing painted the text", which
    // reads at a glance like a broken slot and is in fact a broken probe. It
    // was only ever distinguishable because `_paintedFamily` refuses to score
    // an absent span; had it returned null the case would have gone red for
    // the wrong reason and been "fixed" by a change that did nothing.
    (key.currentState! as TooltipState).ensureTooltipVisible();
    await tester.pumpAndSettle();
    expect(
      _paintedFamily(tester, 'hint'),
      _bodyFamily,
      reason: 'the tooltip resolved a different face from the rest of the app',
    );
  });

  testWidgets('navigationRailTheme label styles, selected and not', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme,
        home: Scaffold(
          body: NavigationRail(
            selectedIndex: 0,
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home),
                label: Text('here'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings),
                label: Text('there'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      _paintedFamily(tester, 'here'),
      _bodyFamily,
      reason: 'the SELECTED rail label resolved a different face',
    );
    expect(
      _paintedFamily(tester, 'there'),
      _bodyFamily,
      reason: 'the UNSELECTED rail label resolved a different face',
    );
  });

  testWidgets('elevatedButtonTheme textStyle', (tester) async {
    await _pump(
      tester,
      ElevatedButton(onPressed: () {}, child: const Text('connect')),
    );
    expect(
      _paintedFamily(tester, 'connect'),
      _bodyFamily,
      reason: 'the elevated button label resolved a different face',
    );
  });

  // The control, and it is the point of the file rather than an afterthought.
  //
  // `hintStyle` is as bare as every slot above. If this case ever goes red the
  // same way they do, the reading is not "a sixth bug" — it is that this test
  // has stopped discriminating REPLACE from MERGE and none of its greens above
  // mean anything.
  testWidgets('CONTROL · inputDecorationTheme.hintStyle merges, and must', (
    tester,
  ) async {
    await _pump(
      tester,
      const TextField(decoration: InputDecoration(hintText: 'Search messages')),
    );
    expect(
      _paintedFamily(tester, 'Search messages'),
      _bodyFamily,
      reason:
          'the control failed: hintStyle is a bare TextStyle that is KNOWN to '
          'merge — search/frames/01.png shows it in real glyphs — so if it '
          'reads as broken here this test cannot tell replace from merge and '
          'every other case in this file is void',
    );
  });
}
