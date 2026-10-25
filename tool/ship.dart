// Build, verify, upload and TAG one platform's release, in one step.
//
//   dart run tool/ship.dart android --notes "What's new…" [--expect STR]... [--dry-run]
//   dart run tool/ship.dart ios   [--expect STR]... [--dry-run]
//   dart run tool/ship.dart macos [--expect STR]... [--dry-run]
//
// WHY THE TAG LIVES HERE
// The stores number builds independently and we ship platforms on different days,
// so `0.0.6+17` on Android (built from 1d51087 on 2026-10-09) and `0.0.6+17` on
// macOS (uploaded 2026-10-19, after the Mac fixes) are DIFFERENT commits. A tag
// per version can't say which. The tag `<platform>/v<name>+<build>` records "this
// store's build N came from this commit", and it is made by the same command that
// uploads, so it can't be forgotten. Then `git log android/v0.0.7+18..main`
// answers "what hasn't shipped on Android yet?".
//
// WHAT IT DOES NOT DO
// Submit for review. iOS/macOS submission stays a separate, confirmed `asc` step.
// ANDROID IS DIFFERENT: this Play account auto-submits on commit, so
// `ship.dart android` IS the submission.
//
// GATES (fatal; --dry-run builds and reports them, then stops before upload)
//   - tracked files clean, HEAD reachable from origin/main
//   - the tag doesn't exist yet, locally or on origin
//   - the built artifact carries pubspec's version (an exit code has lied before)
//   - each --expect STR is present in the compiled Dart (libapp.so / App)
import 'dart:convert';
import 'dart:io';

const _defines = 'dart_defines/prod.json';
const _platforms = {'android', 'ios', 'macos'};

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args == null) {
    stderr.writeln(
      'usage: dart run tool/ship.dart <android|ios|macos> '
      '[--notes TEXT] [--expect STR]... [--dry-run]',
    );
    exit(2);
  }
  Directory.current = (await _out('git', [
    'rev-parse',
    '--show-toplevel',
  ])).trim();

  final version = RegExp(
    r'^version:\s*(\S+)\+(\d+)\s*$',
    multiLine: true,
  ).firstMatch(File('pubspec.yaml').readAsStringSync());
  if (version == null) _die('no `version: X+N` line in pubspec.yaml');
  final name = version.group(1)!, build = version.group(2)!;
  final tag = '${args.platform}/v$name+$build';
  final head = (await _out('git', ['rev-parse', '--short', 'HEAD'])).trim();
  stdout.writeln('▶ ship ${args.platform} $name+$build from $head → tag $tag');

  final gates = _Gates();

  // --- source gates ---------------------------------------------------------
  await _must('git', ['fetch', '-q', 'origin', 'main', '--tags']);
  gates.check(
    (await _out('git', [
      'status',
      '--porcelain',
      '--untracked-files=no',
    ])).isEmpty,
    'tracked files clean',
    'uncommitted changes to tracked files',
  );
  gates.check(
    await _ok('git', ['merge-base', '--is-ancestor', 'HEAD', 'origin/main']),
    'HEAD is on origin/main',
    'HEAD is not on origin/main (merge the release PR first)',
  );
  final tagTaken =
      await _ok('git', ['rev-parse', '-q', '--verify', 'refs/tags/$tag']) ||
      (await _out('git', [
        'ls-remote',
        '--tags',
        'origin',
        'refs/tags/$tag',
      ])).isNotEmpty;
  gates.check(
    !tagTaken,
    'tag $tag is free',
    'tag $tag already exists: bump the build number in pubspec.yaml',
  );
  if (args.platform == 'android') {
    gates.check(
      args.notes != null,
      'release notes given',
      'android needs --notes (the upload submits to review)',
    );
  }
  if (gates.failed && !args.dryRun) exit(1);

  // --- build ----------------------------------------------------------------
  final work = Directory.systemTemp.createTempSync('ship-');
  try {
    final built = await _build(args.platform, name, work);

    // --- artifact gates ---------------------------------------------------------
    stdout.writeln('▶ verify ${built.artifact}');
    gates.check(
      built.version == name,
      'artifact version ${built.version}',
      "artifact version '${built.version}' != pubspec '$name'",
    );
    // latin1 maps every byte to one char, so an ASCII needle matches the bytes.
    final dart = latin1.decode(File(built.dartBinary).readAsBytesSync());
    for (final s in args.expects) {
      gates.check(
        dart.contains(s),
        "compiled Dart contains '$s'",
        "compiled Dart is missing '$s'",
      );
    }
    if (gates.failed) _die('gates failed: nothing uploaded, nothing tagged');
    if (args.dryRun) {
      stdout.writeln('✓ dry run passed: not uploading, not tagging');
      return;
    }

    // --- upload, then tag ---------------------------------------------------------
    switch (args.platform) {
      case 'android':
        await _must('gplay', [
          'upload', '--aab', built.artifact, '--track', 'production', //
          '--notes', args.notes!,
        ]);
      case 'ios':
        await _must('asc', [
          'upload',
          '--ipa',
          built.artifact,
          '--platform',
          'ios',
        ]);
      case 'macos':
        await _must('asc', ['mas-upload', '--pkg', built.artifact]);
    }
    final today = DateTime.now().toIso8601String().substring(0, 10);
    await _must('git', [
      'tag',
      '-a',
      tag,
      '-m',
      '${args.platform} $name+$build uploaded $today',
    ]);
    await _must('git', ['push', 'origin', 'refs/tags/$tag']);
    stdout.writeln('✓ $tag → $head');
    stdout.writeln(switch (args.platform) {
      'android' =>
        '  Submitted (this Play account auto-submits). '
            'Check: gplay status --track production',
      'ios' =>
        '  Next: asc ios-attach --version $name, asc preflight, asc ios-submit --confirm',
      _ =>
        '  Next: asc mas-attach --version $name, asc preflight, asc mas-submit --confirm',
    });
  } finally {
    work.deleteSync(recursive: true);
  }
}

class _Built {
  _Built(this.artifact, this.dartBinary, this.version);
  final String artifact, dartBinary, version;
}

Future<_Built> _build(String platform, String version, Directory work) async {
  switch (platform) {
    case 'android':
      await _buildStep('flutter', [
        'build',
        'appbundle',
        '--release',
        '--dart-define-from-file=$_defines',
      ]);
      const aab = 'build/app/outputs/bundle/release/app-release.aab';
      await _buildStep('unzip', ['-q', aab, '-d', work.path]);
      // The bundle's manifest is binary protobuf; the versionName survives as text.
      final manifest = latin1.decode(
        File(
          '${work.path}/base/manifest/AndroidManifest.xml',
        ).readAsBytesSync(),
      );
      // Other dotted triples can sit in the manifest too, so report all of them
      // unless one is exactly pubspec's version.
      final found = RegExp(
        r'\d+\.\d+\.\d+',
      ).allMatches(manifest).map((m) => m[0]!).toSet();
      final v = found.contains(version) ? version : found.join(',');
      return _Built(aab, '${work.path}/base/lib/arm64-v8a/libapp.so', v);
    case 'ios':
      await _buildStep('flutter', [
        'build',
        'ipa',
        '--release',
        '--dart-define-from-file=$_defines',
        '--export-options-plist=ios/ExportOptions.plist',
      ]);
      final ipa = _only('build/ios/ipa', '.ipa');
      await _buildStep('unzip', ['-q', ipa, '-d', work.path]);
      final app = '${work.path}/Payload/Runner.app';
      return _Built(
        ipa,
        '$app/Frameworks/App.framework/App',
        await _plistVersion('$app/Info.plist'),
      );
    default: // macos
      // asc builds it (flutter build -> xcodebuild archive -> exportArchive),
      // forwarding prod.json's defines and stripping credentials from every step
      // (enspyrco/cli-tools#107). It leaves the archive here, which is where the
      // version is read back from.
      const archive = 'build/macos-archive/Runner.xcarchive';
      await _buildStep('asc', [
        'mas-package',
        '--repo',
        '.',
        '--dart-define-from-file',
        _defines,
      ]);
      final app = Directory(
        '$archive/Products/Applications',
      ).listSync().firstWhere((e) => e.path.endsWith('.app')).path;
      return _Built(
        _only('build/mas-export', '.pkg'),
        '$app/Contents/Frameworks/App.framework/App',
        await _plistVersion('$app/Contents/Info.plist'),
      );
  }
}

class _Args {
  _Args(this.platform, this.notes, this.expects, this.dryRun);
  final String platform;
  final String? notes;
  final List<String> expects;
  final bool dryRun;

  static _Args? parse(List<String> argv) {
    if (argv.isEmpty || !_platforms.contains(argv.first)) return null;
    String? notes;
    final expects = <String>[];
    var dryRun = false;
    for (var i = 1; i < argv.length; i++) {
      switch (argv[i]) {
        case '--notes' when i + 1 < argv.length:
          notes = argv[++i];
        case '--expect' when i + 1 < argv.length:
          expects.add(argv[++i]);
        case '--dry-run':
          dryRun = true;
        default:
          return null;
      }
    }
    return _Args(argv.first, notes, expects, dryRun);
  }
}

class _Gates {
  var failed = false;
  void check(bool pass, String ok, String fail) {
    if (pass) {
      stdout.writeln('  ✓ $ok');
    } else {
      stderr.writeln('  ✗ $fail');
      failed = true;
    }
  }
}

Never _die(String msg) {
  stderr.writeln('✗ $msg');
  exit(1);
}

String _only(String dir, String ext) {
  final hits = Directory(
    dir,
  ).listSync().where((e) => e.path.endsWith(ext)).toList();
  if (hits.length != 1) _die('expected one $ext in $dir, found ${hits.length}');
  return hits.single.path;
}

Future<String> _plistVersion(String plist) => _out('plutil', [
  '-extract',
  'CFBundleShortVersionString',
  'raw',
  plist,
]).then((s) => s.trim());

/// Runs with the console attached; a nonzero exit stops the release.
Future<void> _must(
  String cmd,
  List<String> args, {
  Map<String, String>? environment,
}) async {
  stdout.writeln('+ $cmd ${args.join(' ')}');
  final p = await Process.start(
    cmd,
    args,
    mode: ProcessStartMode.inheritStdio,
    environment: environment,
    includeParentEnvironment: environment == null,
  );
  final code = await p.exitCode;
  if (code != 0) _die('$cmd exited $code');
}

/// A build step: runs with the credentials stripped from the environment.
///
/// `xcodebuild archive` prints the WHOLE environment into the log for each
/// script phase, and on 2026-10-24 that printed a keystore password from
/// ~/.claude/.env. Builds sign from the keychain and android/key.properties,
/// never from env, so they don't need any of it.
Future<void> _buildStep(String cmd, List<String> args) =>
    _must(cmd, args, environment: buildEnvironment());

/// The parent environment minus every name defined in ~/.claude/.env (that
/// file IS the list of secrets) and anything whose name looks like one.
Map<String, String> buildEnvironment({
  Map<String, String>? parent,
  String? envFile,
}) {
  final env = Map.of(parent ?? Platform.environment);
  final file = File(envFile ?? '${Platform.environment['HOME']}/.claude/.env');
  final defined = file.existsSync()
      ? RegExp(
          r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=',
          multiLine: true,
        ).allMatches(file.readAsStringSync()).map((m) => m[1]!).toSet()
      : <String>{};
  final looksSecret = RegExp(
    r'PASS|SECRET|TOKEN|PRIVATE|CREDENTIAL|API_?KEY|_KEY$|_KEY_',
    caseSensitive: false,
  );
  env.removeWhere((k, _) => defined.contains(k) || looksSecret.hasMatch(k));
  return env;
}

Future<bool> _ok(String cmd, List<String> args) async =>
    (await Process.run(cmd, args)).exitCode == 0;

Future<String> _out(String cmd, List<String> args) async {
  final r = await Process.run(cmd, args);
  if (r.exitCode != 0) {
    _die('$cmd ${args.join(' ')} exited ${r.exitCode}: ${r.stderr}');
  }
  return r.stdout as String;
}
