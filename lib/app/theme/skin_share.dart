import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_fonts.dart';
import 'skin_selection.dart';
import 'theme_builder.dart';
import 'theme_laws.dart';
import 'theme_presets.dart';

/// Give your look to someone else.
///
/// This is the first part of the theming work where the input is authored by
/// SOMEONE ELSE, which makes it a trust boundary rather than a preference
/// surface — and claude-tasks#2715's original body is wrong to call skins "pure
/// presentation (no trust boundary)". The correction is posted on the issue; the
/// design below is what it resolves to.
///
/// THE TWO BLOCKING PRECONDITIONS, decided:
///
/// 1. A SHARED SKIN IS COLOUR ONLY. It carries a preset id, a font id, and
///    per-role colour overrides. It carries NO LAYOUT — not bubbles-vs-flat, not
///    alignment, not density, not which composer buttons show. That is the only
///    option where the existing guarantee covers the entire shared surface:
///    "the palette supplies hue, the builder owns relationships" makes an
///    unreadable control unrepresentable, but it says nothing about a skin that
///    could MOVE one. A skin that can move the composer can hide things a skin
///    that can only recolour cannot, so layout does not travel. If layout ever
///    needs to, it needs its own guarantee first, not an extension of this one.
///
/// 2. A SKIN IS DECLARATIVE DATA, NEVER CODE. It is a JSON document of names and
///    colours. Nothing in it is executed, interpreted as a path, or used to
///    address anything. A shared skin that could execute would be a
///    remote-code-execution surface wearing a wallpaper costume.
///
/// AND IT IS NOT SIGNED, deliberately. Signing was rejected in the skin-scout
/// report and the reasoning still holds: there is no threat model in which
/// someone lies about their own wallpaper. What this inherits from the Carried
/// Record is SHAPE — subject-owned, portable, versioned — not its cryptographic
/// machinery. Every defence here is about what the document can DO on arrival,
/// not about who wrote it, because who wrote it does not matter.
///
/// Transport is a copyable code. No island involvement, so nothing here is
/// co-owned with `aiko-chat-island` and no wire contract is at stake; an
/// island-pushed branding tier would be a separate design with a separate
/// adversary.

/// Bump when the document's SHAPE changes incompatibly. An unknown version is
/// refused outright rather than parsed hopefully — guessing at a newer build's
/// document is how you apply half of something.
const kSkinShareVersion = 1;

const _prefix = 'aiko-skin';

/// A hard cap applied BEFORE decoding anything.
///
/// A real skin is a few hundred bytes. The cap exists so that a pathological
/// payload — a megabyte of nested arrays designed to exhaust the parser — is
/// rejected by length, cheaply, before `jsonDecode` ever sees it. Validating
/// after parsing would mean doing the expensive thing first.
const kMaxSkinCodeLength = 4096;

/// Why an import was refused. Every refusal names a reason: a skin that fails
/// silently is indistinguishable from a broken app.
enum SkinImportError {
  empty('There is nothing to import.'),
  tooLong('That code is too long to be a skin.'),
  notASkin('That does not look like an aiko skin code.'),
  wrongVersion(
      'That skin was made by a newer version of the app. Update to use it.'),
  malformed('That skin code is damaged or incomplete.'),
  unusable('That skin would make parts of the app unreadable, so it '
      "can't be used as-is.");

  const SkinImportError(this.message);
  final String message;
}

/// The outcome of reading someone else's skin code.
@immutable
class SkinImport {
  const SkinImport._({this.selection, this.error, this.adjustedRoles = 0});

  /// A valid, USABLE selection — already healed if it needed healing.
  final SkinSelection? selection;
  final SkinImportError? error;

  /// How many of the author's colours had to be dropped to keep the result
  /// readable. Surfaced to the importer rather than swallowed: "this is not
  /// quite what they sent" is information they are entitled to.
  final int adjustedRoles;

  bool get ok => selection != null;
  bool get wasAdjusted => adjustedRoles > 0;
}

/// Encode the reader's current look as a shareable code.
///
/// Only the three shareable axes are written. Per-channel tints are NOT
/// included: they are keyed by channel id, which is meaningless on someone
/// else's device and would leak which rooms you are in.
String encodeSkin(SkinSelection selection) {
  final doc = {
    'v': kSkinShareVersion,
    'preset': selection.presetId,
    if (selection.fontId != kDefaultFontId) 'font': selection.fontId,
    ...selection.toJson()
      ..remove('preset')
      ..remove('font'),
  };
  final payload = base64Url.encode(utf8.encode(jsonEncode(doc)));
  return '$_prefix:v$kSkinShareVersion:$payload';
}

/// Read someone else's skin code.
///
/// FAIL-CLOSED at every step: anything unrecognised is refused with a reason
/// rather than partially applied. A half-applied skin is worse than none — it
/// leaves the reader in a state neither they nor the author chose, with no
/// obvious way back.
SkinImport decodeSkin(String? raw) {
  final code = raw?.trim() ?? '';
  if (code.isEmpty) return const SkinImport._(error: SkinImportError.empty);
  if (code.length > kMaxSkinCodeLength) {
    return const SkinImport._(error: SkinImportError.tooLong);
  }

  final parts = code.split(':');
  if (parts.length != 3 || parts[0] != _prefix) {
    return const SkinImport._(error: SkinImportError.notASkin);
  }
  if (parts[1] != 'v$kSkinShareVersion') {
    return const SkinImport._(error: SkinImportError.wrongVersion);
  }

  Map<String, dynamic> doc;
  try {
    final json = jsonDecode(utf8.decode(base64Url.decode(parts[2])));
    if (json is! Map<String, dynamic>) {
      return const SkinImport._(error: SkinImportError.malformed);
    }
    doc = json;
  } catch (_) {
    // Any decoding failure at all — bad base64, invalid UTF-8, broken JSON —
    // is the same answer to the reader, and none of them is worth a different
    // message. Deliberately broad: this is hostile input.
    return const SkinImport._(error: SkinImportError.malformed);
  }

  if (doc['v'] != kSkinShareVersion) {
    return const SkinImport._(error: SkinImportError.wrongVersion);
  }

  // Every field is resolved through the SAME fail-soft resolvers the app uses
  // for its own stored state: an unknown preset or font id becomes the default
  // rather than an error, because a skin naming a preset we retired is still a
  // perfectly good set of colours.
  final requested = SkinSelection(
    presetId: presetById(doc['preset'] as String?).id,
    fontId: fontById(doc['font'] as String?).id,
    lightOverrides: _roles(doc['light']),
    darkOverrides: _roles(doc['dark']),
  );

  // THE GATE. `resolve()` drops any override that would break the design
  // language, so the result is lawful by construction; what matters here is
  // COUNTING what it dropped, so the importer is told rather than quietly
  // handed something other than what they were sent.
  final resolved = requested.resolve();
  final dropped = _countDropped(requested, resolved);

  // Belt and braces: assert the property rather than trusting the layer below.
  // This is the last point before someone else's document becomes the reader's
  // app, and the cost of being wrong here is an unusable app with no obvious
  // way back.
  if (checkPalette(resolved.light).isNotEmpty ||
      checkPalette(resolved.dark).isNotEmpty) {
    return const SkinImport._(error: SkinImportError.unusable);
  }

  return SkinImport._(selection: requested, adjustedRoles: dropped);
}

/// How many authored colours did not survive resolution.
int _countDropped(SkinSelection requested, ThemePreset resolved) {
  var dropped = 0;
  void count(Map<PaletteRole, Color> overrides, ThemePalette got) {
    overrides.forEach((role, colour) {
      if (roleOf(got, role).toARGB32() != colour.toARGB32()) dropped++;
    });
  }

  count(requested.lightOverrides, resolved.light);
  count(requested.darkOverrides, resolved.dark);
  return dropped;
}

/// Parse a role→colour map from untrusted JSON.
///
/// Unknown role names are IGNORED rather than fatal (a newer build may know
/// roles we do not), and a colour that is not a plain integer literal is
/// dropped. Nothing here is addressed, executed, or used as a path — the only
/// thing a name can do is match one of eleven known enum values or be discarded.
Map<PaletteRole, Color> _roles(Object? raw) {
  if (raw is! Map) return const {};
  final out = <PaletteRole, Color>{};
  for (final entry in raw.entries) {
    if (out.length >= PaletteRole.values.length) break; // no unbounded growth
    final role =
        PaletteRole.values.where((r) => r.name == entry.key).firstOrNull;
    if (role == null) continue;
    final parsed =
        int.tryParse('${entry.value}'.replaceFirst('#', ''), radix: 16);
    if (parsed == null) continue;
    out[role] = Color(parsed);
  }
  return out;
}
