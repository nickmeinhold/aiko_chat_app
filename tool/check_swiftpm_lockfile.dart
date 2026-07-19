// Zero-cost SwiftPM lockfile-freshness gate (task #1909).
//
// WHY THIS EXISTS
// PR #69 removed the GoogleSignIn / AppAuth / app-check SwiftPM packages but left
// their pins behind in the committed `Package.resolved` files. Dart tests were
// green, so CI blessed the merge — a "false green": a build resting on committed
// artifacts out of sync with the actual dependency graph. Kelvin's cage-match
// catch: "a passing build that depends on stale, committed artifacts is a fiction."
//
// WHY IT'S A TEXT CHECK (not a regenerate-and-diff)
// The obvious gate — regenerate the SwiftPM integration and `git diff` — needs
// `xcodebuild` / `xcresolve`, which is macOS-only. This repo's CI runs on
// `ubuntu-latest` to stay zero-cost (Nick does not pay for Actions minutes, and
// macOS runners are billed). So the gate has to detect drift WITHOUT regenerating,
// from the committed files alone.
//
// WHAT IT CAN AND CANNOT PROVE (read before "improving" it)
// `Package.resolved` pins the full TRANSITIVE closure; the `.pbxproj` declares only
// DIRECT remote packages (XCRemoteSwiftPackageReference). So a legitimate transitive
// pin is NOT declared in the pbxproj — a naive "every pin must be declared" rule
// would false-positive on it. Two rules over the committed text:
//
//   RULE 1 (the PR #69 disease): if a platform declares ZERO remote SwiftPM
//     packages, it must have ZERO pins — any pin is stale. This catches the exact
//     historical failure (a complete dependency purge that left the lockfile).
//
//   RULE 2 (forgot-to-commit): every DIRECTLY-declared remote package must appear
//     as a pin. `declared ⊆ pinned` has no false-positives — a direct dep must be
//     resolved. Catches "added a remote dep, didn't commit the lockfile".
//
// RULE 1's SOUNDNESS ASSUMPTION (important): it assumes every remote SwiftPM dep is
// declared as an XCRemoteSwiftPackageReference in the COMMITTED pbxproj. That holds
// for app-direct deps — the PR #69 case (GoogleSignIn was a direct app reference).
// It does NOT hold if a Flutter plugin (a *local* Swift package, whose generated,
// uncommitted Package.swift can itself pull remote deps) introduces a remote
// transitive: that pin would appear with no matching pbxproj reference, and RULE 1
// would FALSE-POSITIVE. The failure is benign and loud (a blocked push, obvious and
// `--no-verify`-recoverable, never a silent wrong pass), but if it fires on a real
// plugin remote dep the fix is to teach this check about committed Package.swift
// manifests (or scope RULE 1 to pins whose package left the pbxproj in git history)
// — NOT to delete RULE 1. Today the repo is all-local (zero pins), so the assumption
// holds exactly.
//
// It deliberately does NOT flag `pinned - declared` when packages ARE declared,
// because that difference is (correctly) the transitive closure. The drift it
// therefore cannot see: a PARTIAL removal that leaves a stale pin while OTHER remote
// deps remain — distinguishing a stale pin from a transitive one needs regeneration
// (macOS). Documented as the follow-up in the task; do not "fix" it here by
// reintroducing the unsound rule.
//
// USAGE
//   dart run tool/check_swiftpm_lockfile.dart        # exit 0 clean, 1 on drift
// Wired into .github/workflows/ci.yml and tool/git-hooks/pre-push.

import 'dart:convert';
import 'dart:io';

/// A committed `Package.resolved`, reduced to the set of package identities it pins.
typedef Lockfile = ({String path, Set<String> pins});

/// Normalise a repo URL or package name to the identity SwiftPM uses in
/// `Package.resolved` (lowercased repository basename, `.git` stripped). The
/// pbxproj carries `repositoryURL`; v2/v3 lockfiles carry a lowercased `identity`;
/// v1 lockfiles carry a `repositoryURL`. Normalising all three the same way lets
/// them be compared as plain string sets.
String normaliseIdentity(String urlOrName) {
  var s = urlOrName.trim();
  final slash = s.lastIndexOf('/');
  if (slash >= 0) s = s.substring(slash + 1);
  if (s.endsWith('.git')) s = s.substring(0, s.length - 4);
  return s.toLowerCase();
}

/// The direct remote SwiftPM package identities declared in a `project.pbxproj`.
/// The only thing carrying `repositoryURL` in a pbxproj is an
/// XCRemoteSwiftPackageReference, so every such URL is a directly-declared dep.
Set<String> declaredIdentitiesFromPbxproj(String contents) {
  final re = RegExp(r'repositoryURL\s*=\s*"([^"]+)"');
  return re
      .allMatches(contents)
      .map((m) => normaliseIdentity(m.group(1)!))
      .toSet();
}

/// The package identities pinned by a `Package.resolved`, across its format
/// versions (v1 nests under `object.pins` with a `package`/`repositoryURL`;
/// v2/v3 use a top-level `pins` with an `identity`). Throws [FormatException] on
/// unparseable JSON so a corrupt lockfile fails loud rather than reading as empty.
Set<String> pinnedIdentitiesFromResolved(String jsonContents) {
  final decoded = jsonDecode(jsonContents);
  if (decoded is! Map) return {};
  final pins = (decoded['pins'] ?? (decoded['object']?['pins'])) as List?;
  if (pins == null) return {};
  final out = <String>{};
  for (final pin in pins) {
    if (pin is! Map) continue;
    final id = pin['identity'] ?? pin['repositoryURL'] ?? pin['package'];
    if (id is String && id.isNotEmpty) out.add(normaliseIdentity(id));
  }
  return out;
}

/// The pure drift logic (RULE 1 + RULE 2), over already-parsed inputs so it is
/// exhaustively unit-testable without touching git or the filesystem. Returns a
/// human-readable problem per violation; empty means clean.
List<String> driftProblems({
  required Map<String, Set<String>> declaredByPlatform,
  required Map<String, List<Lockfile>> lockfilesByPlatform,
}) {
  final problems = <String>[];
  final platforms = {...declaredByPlatform.keys, ...lockfilesByPlatform.keys};

  for (final platform in platforms) {
    final declared = declaredByPlatform[platform] ?? const <String>{};
    final lockfiles = lockfilesByPlatform[platform] ?? const <Lockfile>[];

    if (declared.isEmpty) {
      // RULE 1: no declared remote roots ⇒ no pins are legitimate.
      for (final lf in lockfiles) {
        if (lf.pins.isNotEmpty) {
          problems.add(
            'STALE lockfile: ${lf.path} pins ${_fmt(lf.pins)} but the $platform '
            'Xcode project declares NO remote SwiftPM packages. Most likely a '
            'stale leftover (the PR #69 class) — regenerate or delete the '
            'lockfile. If instead a Flutter plugin legitimately introduced a '
            'remote SwiftPM dependency, this check needs teaching about local '
            'Package.swift manifests (see the script header).',
          );
        }
      }
      continue;
    }

    // RULE 2: declared roots must be pinned somewhere reproducible.
    if (lockfiles.isEmpty) {
      problems.add(
        'MISSING lockfile: the $platform Xcode project declares remote SwiftPM '
        'packages ${_fmt(declared)} but no Package.resolved is committed under '
        '$platform/ — the build is not reproducible. Commit the resolved lockfile.',
      );
      continue;
    }
    for (final lf in lockfiles) {
      final missing = declared.difference(lf.pins);
      if (missing.isNotEmpty) {
        problems.add(
          'UNRESOLVED dep: ${lf.path} does not pin declared remote package(s) '
          '${_fmt(missing)}. Re-resolve SwiftPM and commit the updated lockfile.',
        );
      }
      // Intentionally NOT flagging lf.pins - declared: that is the transitive
      // closure, not drift. See the header note.
    }
  }
  return problems;
}

String _fmt(Set<String> s) => '{${(s.toList()..sort()).join(', ')}}';

/// The only platforms a Flutter app integrates SwiftPM into. A `Package.resolved`
/// or pbxproj outside these is not the app's SwiftPM integration, so it is out of
/// this gate's scope (avoids judging, e.g., a vendored package's own lockfile).
const _swiftpmPlatforms = {'ios', 'macos'};

/// The SwiftPM platform a repo-relative path belongs to (`ios/…` → `ios`), or null
/// if the path is not under a SwiftPM platform dir.
String? _platformOf(String repoRelPath) {
  final head = repoRelPath.split('/').first;
  return _swiftpmPlatforms.contains(head) ? head : null;
}

/// Gather the committed pbxproj + Package.resolved inputs from git. Uses
/// `git ls-files` so only TRACKED files count — an untracked local lockfile never
/// ships, so it is not the gate's concern.
({Map<String, Set<String>> declared, Map<String, List<Lockfile>> lockfiles})
    collectFromGit(String root) {
  final ls = Process.runSync('git', ['-C', root, 'ls-files'], stdoutEncoding: utf8);
  if (ls.exitCode != 0) {
    stderr.writeln('git ls-files failed in $root: ${ls.stderr}');
    exit(2);
  }
  final tracked = (ls.stdout as String).split('\n').where((l) => l.isNotEmpty);

  final declared = <String, Set<String>>{};
  final lockfiles = <String, List<Lockfile>>{};

  for (final rel in tracked) {
    final platform = _platformOf(rel);
    if (platform == null) continue; // not under ios/ or macos/
    final base = rel.split('/').last;
    if (base == 'project.pbxproj') {
      final contents = File('$root/$rel').readAsStringSync();
      (declared[platform] ??= <String>{})
          .addAll(declaredIdentitiesFromPbxproj(contents));
    } else if (base == 'Package.resolved') {
      final contents = File('$root/$rel').readAsStringSync();
      final Set<String> pins;
      try {
        pins = pinnedIdentitiesFromResolved(contents);
      } on FormatException catch (e) {
        stderr.writeln('Could not parse $rel: $e');
        exit(1);
      }
      (lockfiles[platform] ??= <Lockfile>[]).add((path: rel, pins: pins));
    }
  }
  return (declared: declared, lockfiles: lockfiles);
}

void main() {
  final rootProc =
      Process.runSync('git', ['rev-parse', '--show-toplevel'], stdoutEncoding: utf8);
  final root = rootProc.exitCode == 0
      ? (rootProc.stdout as String).trim()
      : Directory.current.path;

  final inputs = collectFromGit(root);
  final problems = driftProblems(
    declaredByPlatform: inputs.declared,
    lockfilesByPlatform: inputs.lockfiles,
  );

  if (problems.isEmpty) {
    final declaredCount =
        inputs.declared.values.fold<int>(0, (n, s) => n + s.length);
    final lockCount =
        inputs.lockfiles.values.fold<int>(0, (n, l) => n + l.length);
    stdout.writeln(
      '✓ SwiftPM lockfile gate: clean '
      '($declaredCount declared remote package(s), $lockCount committed lockfile(s)).',
    );
    exit(0);
  }

  stderr.writeln('✗ SwiftPM lockfile gate: ${problems.length} problem(s):');
  for (final p in problems) {
    stderr.writeln('  • $p');
  }
  exit(1);
}
