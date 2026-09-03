// A SEMANTIC vocabulary audit — the instrument that fails DIFFERENTLY.
//
// Every other check on the island rename is TEXTUAL: the sweep was a regex, the
// string guard is a regex, the identifier guard is a regex, and every grep reached
// for along the way was a regex. They share a representation with the thing that
// produced the bugs, so they can only ever agree with each other — which is exactly
// how five instruments in a row each found survivors the previous one could not see
// (feedback: a verifier sharing a representation with the verified is blind to bugs
// in that layer).
//
// This one asks the ANALYZER what the code declares. It walks the resolved element
// model — classes, mixins, enums, extensions, type aliases, top-level functions and
// variables, getters/setters, and every member and formal parameter — rather than
// words on lines. It cannot be fooled by a name split across a line, a token inside
// a string, or a comment that reads like code.
//
// STATED COVERAGE BOUNDARY, because a guard that hides its edges is worse than one
// that has them: the element model does NOT expose function-LOCAL variables, and
// locals are precisely where two survivors lived (`final servers = ...` in the
// island picker and the sidebar). Locals remain covered by the regex identifier
// guard in test/vocabulary/island_vocabulary_test.dart. The two instruments are
// COMPLEMENTARY, not redundant: this one is semantic but shallow-scoped, that one is
// textual but total. Neither alone is sufficient, and saying so is the point.
//
// Usage:  dart run tool/vocabulary_audit.dart [dir ...]     (defaults to lib)
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

/// ADR-0001: island = the deployment, gateway = the bridge service INSIDE one,
/// server = the host it runs on (the third meaning, named 2026-09-02).
const _banned = {'server', 'servers'};
const _needsReason = {'gateway', 'gateways'};

/// Declarations permitted to say "gateway" because they NAME THE BRIDGE SERVICE,
/// plus the legacy storage-key constants. Deliberately duplicated from
/// _permittedIdentifiers rather than shared: two instruments that import one
/// allowlist cannot disagree about it, and disagreement is the whole value here.
const _permitted = {
  'GatewayRestApi', 'buildGatewayBackend', 'GatewayTransport',
  'GatewayCapabilities', 'gatewayCapabilities', 'GatewayFrame',
  'closeFromGateway',
  // Parses a timestamp field of an AckFrame, which IS a GatewayFrame — the bin
  // its sibling closeFromGateway landed in (PR #180, the third-meaning fix).
  '_parseGatewayTime',
  'kLegacyIslandBaseUrlPrefKey', 'kLegacyKnownIslandsPrefKey',
};

/// camelCase / snake_case components — the unit the question is actually about.
/// A substring flags `observer`; a `\b` boundary misses `serverUlidFor`.
Iterable<String> _words(String name) => name
    .split('_')
    .expand((p) => p.split(RegExp(r'(?=[A-Z])')))
    .map((w) => w.toLowerCase())
    .where((w) => w.isNotEmpty);

final _findings = <String>[];

void _check(String kind, String? name, String where) {
  if (name == null || name.isEmpty) return;
  if (_permitted.contains(name)) return;
  final words = _words(name).toSet();
  if (words.intersection(_banned).isNotEmpty) {
    _findings.add(
      '$where  [$kind] $name  (declares "server" — banned outright)',
    );
  } else if (words.intersection(_needsReason).isNotEmpty) {
    _findings.add(
      '$where  [$kind] $name  (declares "gateway" — not a permitted '
      'bridge-service name)',
    );
  }
}

void _checkExecutable(String kind, ExecutableElement e, String where) {
  _check(kind, e.name, where);
  for (final p in e.formalParameters) {
    _check('$kind-param', p.name, where);
  }
}

void _checkInterface(String kind, InterfaceElement c, String where) {
  _check(kind, c.name, where);
  for (final m in c.methods) {
    _checkExecutable('method', m, where);
  }
  for (final g in c.getters) {
    _check('getter', g.name, where);
  }
  for (final s in c.setters) {
    _check('setter', s.name, where);
  }
  for (final f in c.fields) {
    _check('field', f.name, where);
  }
  for (final ctor in c.constructors) {
    for (final p in ctor.formalParameters) {
      _check('ctor-param', p.name, where);
    }
  }
}

/// The locals, parameters and loop variables the element model cannot reach.
class _BodyVisitor extends RecursiveAstVisitor<void> {
  _BodyVisitor(this.where);
  final String where;

  @override
  void visitVariableDeclaration(VariableDeclaration n) {
    _check('local', n.name.lexeme, where);
    super.visitVariableDeclaration(n);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter n) {
    _check('parameter', n.name?.lexeme, where);
    super.visitSimpleFormalParameter(n);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier n) {
    _check('loop-variable', n.name.lexeme, where);
    super.visitDeclaredIdentifier(n);
  }
}

Future<void> main(List<String> args) async {
  final roots = (args.isEmpty ? ['lib'] : args)
      .map((d) => Directory(d).absolute.path)
      .toList();
  final collection = AnalysisContextCollection(includedPaths: roots);
  final seen = <String>{};
  var libraries = 0;

  for (final context in collection.contexts) {
    for (final path in context.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart')) continue;
      final result = await context.currentSession.getResolvedUnit(path);
      if (result is! ResolvedUnitResult) continue;
      final lib = result.libraryElement;
      final firstTimeLibrary = seen.add(lib.identifier);
      if (firstTimeLibrary) libraries++;
      final where = path.replaceFirst('${Directory.current.path}/', '');

      if (firstTimeLibrary) {
        for (final c in lib.classes) {
          _checkInterface('class', c, where);
        }
        for (final m in lib.mixins) {
          _checkInterface('mixin', m, where);
        }
        for (final e in lib.enums) {
          _checkInterface('enum', e, where);
        }
        for (final x in lib.extensionTypes) {
          _checkInterface('extension-type', x, where);
        }
        for (final x in lib.extensions) {
          _check('extension', x.name, where);
          for (final m in x.methods) {
            _checkExecutable('extension-method', m, where);
          }
        }
        for (final t in lib.typeAliases) {
          _check('typedef', t.name, where);
        }
        for (final f in lib.topLevelFunctions) {
          _checkExecutable('function', f, where);
        }
        for (final v in lib.topLevelVariables) {
          _check('top-level-variable', v.name, where);
        }
        for (final g in lib.getters) {
          _check('top-level-getter', g.name, where);
        }
        for (final s in lib.setters) {
          _check('top-level-setter', s.name, where);
        }
      }
      // Locals/params/loop vars — same resolved unit, different traversal.
      result.unit.accept(_BodyVisitor(where));
    }
  }

  stdout.writeln('resolved $libraries librar(ies) under ${roots.join(", ")}');
  final unique = _findings.toSet().toList()..sort();
  if (unique.isEmpty) {
    stdout.writeln(
      'SEMANTIC AUDIT CLEAN — no declaration says "server", and every '
      '"gateway" declaration is a permitted bridge-service name. Types, members, '
      'top-level declarations, locals, parameters and loop variables all checked.',
    );
    return;
  }
  stdout.writeln('SEMANTIC AUDIT FOUND ${unique.length} declaration(s):');
  for (final f in unique) {
    stdout.writeln('  $f');
  }
  exitCode = 1;
}
