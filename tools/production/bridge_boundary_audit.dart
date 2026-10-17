import 'dart:convert';
import 'dart:io';

/// Bridge-boundary audit.
///
/// Architecture rule (docs/architecture.md §1): `skotiq_core` is the only
/// Dart package that may talk to the Rust bridge (`package:skotiq_bridge`).
/// `apps` and every other `packages/*` must reach Rust through a
/// `skotiq_core` backend/role seam, never by importing the FRB surface
/// directly.
///
/// This audit scans `lib/` and `bin/` (excluding `test/`) under every workspace
/// root for `import`/`export 'package:skotiq_bridge/...'`. Files inside the
/// two allowed packages (`skotiq_core`, `skotiq_bridge`) are exempt.
/// Any other importer is a boundary violation unless it is listed in the
/// whitelist data file (a pragmatic, reviewed exception).
///
/// It complements `dependency_hygiene.dart`, which only verifies that imported
/// packages are *declared* in pubspec — that check would happily allow a UI
/// package to import `skotiq_bridge` so long as the dependency is declared.
/// This audit enforces the *direction* the dependency-hygiene check does not.
///
/// Output: docs/production-readiness/bridge-boundary.{json,md}
/// Exit code: 1 when un-whitelisted violations exist (unless
/// --no-fail-on-violation).
const _defaultWhitelistPath = 'tools/production/bridge_boundary_whitelist.json';
const _jsonOutputPath = 'docs/production-readiness/bridge-boundary.json';
const _markdownOutputPath = 'docs/production-readiness/bridge-boundary.md';

const _workspaceRoots = <String>['apps', 'packages'];

/// Packages permitted to import the bridge directly.
const _allowedPackagePrefixes = <String>[
  'packages/skotiq_core/',
  'packages/skotiq_bridge/',
];

final _bridgeImportPattern = RegExp(
  r'''(?:import|export)\s+['"]package:skotiq_bridge/[^'"]+['"]''',
);

void main(List<String> args) {
  final failOnViolation = !args.contains('--no-fail-on-violation');
  final root = _argValue(args, '--root') ?? Directory.current.path;
  final whitelistArg = _argValue(args, '--whitelist');

  final rootDir = Directory(root);
  if (!rootDir.existsSync()) {
    stderr.writeln('Root directory not found: $root');
    exit(2);
  }

  final whitelistPath = whitelistArg != null
      ? _resolve(root, whitelistArg)
      : _resolve(root, _defaultWhitelistPath);
  final whitelist = _loadWhitelist(whitelistPath);

  final importers = _findBridgeImporters(root);

  final violations = <_Violation>[];
  final whitelisted = <_Violation>[];
  for (final importer in importers) {
    final entry = whitelist[importer.relativePath];
    final v = _Violation(
      file: importer.relativePath,
      symbols: importer.symbols,
      whitelisted: entry != null,
      reason: entry,
    );
    if (entry != null) {
      whitelisted.add(v);
    } else {
      violations.add(v);
    }
  }

  violations.sort((a, b) => a.file.compareTo(b.file));
  whitelisted.sort((a, b) => a.file.compareTo(b.file));

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': violations.isEmpty,
    'rule':
        'skotiq_core is the only Dart package that may import '
        'package:skotiq_bridge (docs/architecture.md §1).',
    'allowedPackages': _allowedPackagePrefixes,
    'whitelistPath': _normalize(
      whitelistPath,
    ).replaceFirst('${_normalize(root)}/', ''),
    'importerCount': importers.length,
    'violationCount': violations.length,
    'whitelistedCount': whitelisted.length,
    'violations': violations.map((v) => v.toJson()).toList(),
    'whitelisted': whitelisted.map((v) => v.toJson()).toList(),
  };

  final jsonOut = File(_resolve(root, _jsonOutputPath));
  jsonOut.parent.createSync(recursive: true);
  jsonOut.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));

  final mdOut = File(_resolve(root, _markdownOutputPath));
  mdOut.parent.createSync(recursive: true);
  mdOut.writeAsStringSync(
    _renderMarkdown(
      importerCount: importers.length,
      violations: violations,
      whitelisted: whitelisted,
    ),
  );

  stdout.writeln('Bridge boundary audit complete.');
  stdout.writeln('Bridge importers (outside core/bridge): ${importers.length}');
  stdout.writeln('Whitelisted exceptions: ${whitelisted.length}');
  stdout.writeln('Violations: ${violations.length}');
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');

  if (violations.isEmpty) {
    stdout.writeln('Bridge boundary audit passed.');
    return;
  }

  stderr.writeln(
    'Bridge boundary violations (move behind a skotiq_core '
    'backend/role seam, or add to the whitelist with a reason):',
  );
  for (final v in violations) {
    stderr.writeln('  ${v.file} -> ${v.symbols.join(', ')}');
  }
  if (failOnViolation) {
    exit(1);
  }
}

List<_Importer> _findBridgeImporters(String root) {
  final importers = <_Importer>[];
  for (final rootName in _workspaceRoots) {
    final rootDir = Directory(_resolve(root, rootName));
    if (!rootDir.existsSync()) {
      continue;
    }
    for (final pkg in rootDir.listSync(followLinks: false)) {
      if (pkg is! Directory) {
        continue;
      }
      for (final sub in const ['lib', 'bin']) {
        final dir = Directory('${pkg.path}${Platform.pathSeparator}$sub');
        if (!dir.existsSync()) {
          continue;
        }
        for (final entity in dir.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File || !entity.path.endsWith('.dart')) {
            continue;
          }
          final rel = _relative(root, entity.path);
          if (_isAllowed(rel) || _isTest(rel)) {
            continue;
          }
          final contents = entity.readAsStringSync();
          if (!_bridgeImportPattern.hasMatch(contents)) {
            continue;
          }
          importers.add(
            _Importer(relativePath: rel, symbols: _extractSymbols(contents)),
          );
        }
      }
    }
  }
  importers.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return importers;
}

/// Best-effort extraction of which bridge symbols a file actually references.
///
/// Handles both `show A, B` imports (symbols are explicit) and prefixed
/// `as foo` imports (collect `foo.Symbol` references in the body). Falls back
/// to `<unresolved-import>` so an importer is never silently dropped.
List<String> _extractSymbols(String contents) {
  final symbols = <String>{};
  final lines = contents.split('\n');
  for (final line in lines) {
    final match = _bridgeImportPattern.firstMatch(line);
    if (match == null) {
      continue;
    }
    final showMatch = RegExp(r'\bshow\s+([^;]+)').firstMatch(line);
    if (showMatch != null) {
      for (final s in showMatch.group(1)!.split(',')) {
        final name = s.trim();
        if (name.isNotEmpty) {
          symbols.add(name);
        }
      }
      continue;
    }
    final asMatch = RegExp(r'\bas\s+([A-Za-z0-9_]+)').firstMatch(line);
    if (asMatch != null) {
      final prefix = asMatch.group(1)!;
      final refPattern = RegExp('\\b$prefix\\.([A-Za-z_][A-Za-z0-9_]*)');
      for (final ref in refPattern.allMatches(contents)) {
        final name = ref.group(1)!;
        // Skip string-literal artifacts like "bridge.dll" / "bridge.dart"
        // by ignoring all-lowercase file-extension-like tokens.
        if (name == 'dll' || name == 'dart' || name == 'so' || name == 'h') {
          continue;
        }
        symbols.add('$prefix.$name');
      }
      if (symbols.isEmpty) {
        symbols.add('<prefixed import, no references found (unused?)>');
      }
    }
  }
  if (symbols.isEmpty) {
    symbols.add('<unresolved-import>');
  }
  final sorted = symbols.toList()..sort();
  return sorted;
}

Map<String, String> _loadWhitelist(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return const {};
  }
  final decoded = jsonDecode(file.readAsStringSync());
  final result = <String, String>{};
  if (decoded is Map && decoded['allow'] is List) {
    for (final entry in decoded['allow'] as List) {
      if (entry is Map && entry['file'] is String) {
        result[_normalize(entry['file'] as String)] =
            (entry['reason'] as String?) ?? 'no reason given';
      }
    }
  }
  return result;
}

bool _isAllowed(String relativePath) {
  for (final prefix in _allowedPackagePrefixes) {
    if (relativePath.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

bool _isTest(String relativePath) =>
    relativePath.contains('/test/') || relativePath.endsWith('_test.dart');

String _renderMarkdown({
  required int importerCount,
  required List<_Violation> violations,
  required List<_Violation> whitelisted,
}) {
  final buffer = StringBuffer()
    ..writeln('# Bridge Boundary Audit')
    ..writeln()
    ..writeln(
      'Rule: `skotiq_core` is the only Dart package that may import '
      '`package:skotiq_bridge` (docs/architecture.md §1). Every other '
      'package and app must reach Rust through a `skotiq_core` '
      'backend/role seam.',
    )
    ..writeln()
    ..writeln('- Bridge importers outside core/bridge: `$importerCount`')
    ..writeln('- Whitelisted exceptions: `${whitelisted.length}`')
    ..writeln('- Violations: `${violations.length}`');

  if (violations.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Violations')
      ..writeln()
      ..writeln('| File | Bridge symbols |')
      ..writeln('| --- | --- |');
    for (final v in violations) {
      buffer.writeln('| `${v.file}` | ${v.symbols.join(', ')} |');
    }
  }

  if (whitelisted.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Whitelisted exceptions')
      ..writeln()
      ..writeln('| File | Bridge symbols | Reason |')
      ..writeln('| --- | --- | --- |');
    for (final v in whitelisted) {
      buffer.writeln('| `${v.file}` | ${v.symbols.join(', ')} | ${v.reason} |');
    }
  }

  return buffer.toString();
}

String? _argValue(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index >= 0 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

String _resolve(String root, String relative) {
  if (relative.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(relative)) {
    return relative;
  }
  return '$root${Platform.pathSeparator}$relative';
}

String _relative(String root, String path) {
  final normRoot = _normalize(root);
  final normPath = _normalize(path);
  if (normPath.startsWith('$normRoot/')) {
    return normPath.substring(normRoot.length + 1);
  }
  return normPath;
}

String _normalize(String path) => path.replaceAll('\\', '/');

class _Importer {
  final String relativePath;
  final List<String> symbols;

  const _Importer({required this.relativePath, required this.symbols});
}

class _Violation {
  final String file;
  final List<String> symbols;
  final bool whitelisted;
  final String? reason;

  const _Violation({
    required this.file,
    required this.symbols,
    required this.whitelisted,
    required this.reason,
  });

  Map<String, Object?> toJson() => {
    'file': file,
    'symbols': symbols,
    'whitelisted': whitelisted,
    if (reason != null) 'reason': reason,
  };
}
