// Unit tests for the SwiftPM lockfile-freshness gate (tool/check_swiftpm_lockfile.dart,
// task #1909). Targets the pure functions (parsing + drift rules) so every
// degenerate state is exercised without git or the filesystem.
//
// Relative import: the checker lives under tool/, not lib/, so it is not part of
// the package's import namespace. main() does not run on import.
import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_swiftpm_lockfile.dart';

void main() {
  group('normaliseIdentity', () {
    test('lowercases the repo basename and strips .git', () {
      expect(normaliseIdentity('https://github.com/google/GoogleSignIn-iOS.git'),
          'googlesignin-ios');
      expect(normaliseIdentity('https://github.com/google/GoogleSignIn-iOS'),
          'googlesignin-ios');
      expect(normaliseIdentity('GoogleSignIn-iOS'), 'googlesignin-ios');
    });
  });

  group('declaredIdentitiesFromPbxproj', () {
    test('extracts every XCRemoteSwiftPackageReference repositoryURL', () {
      const pbxproj = '''
        /* XCRemoteSwiftPackageReference "GoogleSignIn-iOS" */ = {
          isa = XCRemoteSwiftPackageReference;
          repositoryURL = "https://github.com/google/GoogleSignIn-iOS";
          requirement = { kind = upToNextMajorVersion; minimumVersion = 7.0.0; };
        };
        /* XCRemoteSwiftPackageReference "AppAuth" */ = {
          repositoryURL = "https://github.com/openid/AppAuth-iOS.git";
        };
      ''';
      expect(declaredIdentitiesFromPbxproj(pbxproj),
          {'googlesignin-ios', 'appauth-ios'});
    });

    test('an all-local project (no remote refs) declares nothing', () {
      expect(declaredIdentitiesFromPbxproj('isa = PBXNativeTarget; /* Runner */'),
          isEmpty);
    });
  });

  group('pinnedIdentitiesFromResolved', () {
    test('parses v2/v3 top-level pins by identity', () {
      const v3 = '''
        { "pins": [
            { "identity": "googlesignin-ios", "kind": "remoteSourceControl" },
            { "identity": "appauth-ios" }
          ], "version": 3 }''';
      expect(pinnedIdentitiesFromResolved(v3), {'googlesignin-ios', 'appauth-ios'});
    });

    test('parses v1 nested object.pins by repositoryURL', () {
      const v1 = '''
        { "object": { "pins": [
            { "package": "GoogleSignIn",
              "repositoryURL": "https://github.com/google/GoogleSignIn-iOS.git" }
          ] }, "version": 1 }''';
      expect(pinnedIdentitiesFromResolved(v1), {'googlesignin-ios'});
    });

    test('an empty lockfile pins nothing', () {
      expect(pinnedIdentitiesFromResolved('{ "pins": [], "version": 3 }'), isEmpty);
      expect(pinnedIdentitiesFromResolved('{ "version": 3 }'), isEmpty);
    });

    test('malformed JSON throws (fails loud, never reads as empty)', () {
      expect(() => pinnedIdentitiesFromResolved('{ not json'),
          throwsFormatException);
    });
  });

  group('driftProblems — RULE 1 (no declared roots ⇒ no pins)', () {
    test('the PR #69 disease: pins remain after every remote dep was removed', () {
      final problems = driftProblems(
        declaredByPlatform: {'ios': <String>{}},
        lockfilesByPlatform: {
          'ios': [(path: 'ios/…/Package.resolved', pins: {'googlesignin-ios'})],
        },
      );
      expect(problems, hasLength(1));
      expect(problems.single, contains('STALE'));
      expect(problems.single, contains('googlesignin-ios'));
    });

    test('all-local, no lockfiles at all: clean (the current repo state)', () {
      expect(
        driftProblems(
          declaredByPlatform: {'ios': <String>{}, 'macos': <String>{}},
          lockfilesByPlatform: {},
        ),
        isEmpty,
      );
    });

    test('no declared roots + an empty committed lockfile: clean', () {
      expect(
        driftProblems(
          declaredByPlatform: {'ios': <String>{}},
          lockfilesByPlatform: {
            'ios': [(path: 'ios/…/Package.resolved', pins: <String>{})],
          },
        ),
        isEmpty,
      );
    });
  });

  group('driftProblems — RULE 2 (declared roots ⊆ pinned)', () {
    test('a declared remote dep with no committed lockfile is not reproducible', () {
      final problems = driftProblems(
        declaredByPlatform: {'ios': {'googlesignin-ios'}},
        lockfilesByPlatform: {},
      );
      expect(problems.single, contains('MISSING lockfile'));
    });

    test('a declared dep missing from the lockfile is unresolved', () {
      final problems = driftProblems(
        declaredByPlatform: {'ios': {'googlesignin-ios', 'appauth-ios'}},
        lockfilesByPlatform: {
          'ios': [(path: 'ios/…/Package.resolved', pins: {'googlesignin-ios'})],
        },
      );
      expect(problems.single, contains('UNRESOLVED'));
      expect(problems.single, contains('appauth-ios'));
    });

    test('transitive pins beyond the declared set are NOT flagged', () {
      // declared = {A}; the lockfile also pins B (a transitive dep of A). Sound
      // gates must not false-positive on the transitive closure.
      expect(
        driftProblems(
          declaredByPlatform: {'ios': {'alpha'}},
          lockfilesByPlatform: {
            'ios': [(path: 'ios/…/Package.resolved', pins: {'alpha', 'beta-transitive'})],
          },
        ),
        isEmpty,
      );
    });

    test('a fully-consistent declared+pinned platform is clean', () {
      expect(
        driftProblems(
          declaredByPlatform: {'ios': {'alpha'}},
          lockfilesByPlatform: {
            'ios': [(path: 'ios/…/Package.resolved', pins: {'alpha'})],
          },
        ),
        isEmpty,
      );
    });
  });

  group('driftProblems — cross-platform independence', () {
    test('ios clean, macos stale → exactly one problem, attributed to macos', () {
      final problems = driftProblems(
        declaredByPlatform: {'ios': {'alpha'}, 'macos': <String>{}},
        lockfilesByPlatform: {
          'ios': [(path: 'ios/…/Package.resolved', pins: {'alpha'})],
          'macos': [(path: 'macos/…/Package.resolved', pins: {'ghost'})],
        },
      );
      expect(problems, hasLength(1));
      expect(problems.single, contains('macos'));
      expect(problems.single, contains('ghost'));
    });
  });
}
