import 'dart:convert';
import 'dart:io';

const _defaultRegisterPath =
    'docs/production-readiness/behavioral-audit-register.md';
const _defaultReportPath = '.behavioral_audit_hits.txt';

// Audit policed runtime code only — generated, vendored, or tooling files would
// produce false positives that hide real silent-fallback regressions in the
// shipped product.
const _scanRoots = <String>['apps', 'packages', 'native/skotiq_native'];

const _allowedExtensions = <String>{'.dart', '.rs'};

// Excluded directory NAMES (anchored as path segments). A bare ".test" file
// would not be excluded; a path containing /test/ would. This is intentional
// and matches: the previous substring match silently skipped any
// production module whose path happened to contain "test", "example", etc.
const _excludedDirectoryNames = <String>{
  '.dart_tool',
  '.git',
  '.worktrees',
  'build',
  'target',
  'coverage',
  'generated',
  'frb_dump',
  'test',
  'tests',
  'example',
  'samples',
};

const _excludedSubstrings = <String>['/frb_generated.'];

final _runtimePathPatterns = <RegExp>[
  RegExp(r'^apps/[^/]+/lib/'),
  RegExp(r'^packages/[^/]+/lib/'),
  RegExp(r'^native/skotiq_native(?:/[^/]+)+/src/'),
];

class _Rule {
  final String id;
  final RegExp regex;
  final String summary;
  final bool highRisk;
  // Languages this rule applies to. Empty set = all supported languages.
  final Set<String> languages;

  const _Rule({
    required this.id,
    required this.regex,
    required this.summary,
    this.highRisk = true,
    this.languages = const <String>{},
  });
}

final _rules = <_Rule>[
  _Rule(
    id: 'empty_catch',
    // Matches `catch (_)` and `catch(_)` and `catch (_) { }` — Dart silent
    // catch is the single most common silent-fallback shape in this codebase.
    regex: RegExp(r'catch\s*\(\s*_\s*\)\s*\{?\s*\}?'),
    summary: 'Silent catch swallows runtime failures.',
    languages: <String>{'.dart'},
  ),
  _Rule(
    id: 'guessed_now_timestamp',
    regex: RegExp(r'\?\?\s*DateTime\.now\(\)'),
    summary: 'Guessed current time used as metadata fallback.',
    languages: <String>{'.dart'},
  ),
  _Rule(
    id: 'guessed_numeric_fallback',
    regex: RegExp(r'\?\?\s*1\.0\b|return\s+3\.5\b'),
    summary: 'Numeric fallback may hide missing required data.',
    languages: <String>{'.dart'},
  ),
  _Rule(
    id: 'literal_null_coalesce',
    // Catches the common silent-fallback shape: `expr ?? null|0|false|''|""`.
    // These reduce a Result-bearing expression to a fixed value with no log.
    regex: RegExp("\\?\\?\\s*(null|0|false|''|\"\")"),
    summary: 'Null-coalesce to literal value hides upstream None/null.',
    languages: <String>{'.dart'},
  ),
  _Rule(
    id: 'unwrap_or_literal',
    regex: RegExp(r'unwrap_or\((?:-?\d+(?:\.\d+)?|true|false)\)'),
    summary: 'Literal unwrap_or may silently coerce unknown state.',
    languages: <String>{'.rs'},
  ),
  _Rule(
    id: 'unwrap_or_default',
    regex: RegExp(r'\.unwrap_or_default\(\)'),
    summary:
        'unwrap_or_default coerces error/None to type default with no signal.',
    languages: <String>{'.rs'},
  ),
  _Rule(
    id: 'rust_drop_result',
    // `.ok();` discards a Result without logging or propagating the error.
    regex: RegExp(r'\.ok\(\)\s*;'),
    summary: 'Result dropped via .ok() — error path silently lost.',
    languages: <String>{'.rs'},
  ),
  _Rule(
    id: 'rust_let_underscore',
    // `let _ = expr;` discards return value (commonly a Result) silently.
    regex: RegExp(r'let\s+_\s*='),
    summary: 'let _ = ... discards return value (often a Result).',
    languages: <String>{'.rs'},
  ),
  _Rule(
    id: 'rust_if_let_err_underscore',
    // `if let Err(_) = expr` matches and ignores the actual error contents.
    regex: RegExp(r'if\s+let\s+Err\s*\(\s*_\s*\)\s*='),
    summary: 'if let Err(_) discards the error value.',
    languages: <String>{'.rs'},
  ),
  _Rule(
    id: 'hardcoded_location_fallback',
    regex: RegExp(r'45\.0,\s*-75\.0'),
    summary: 'Hardcoded observer location fallback.',
  ),
  _Rule(
    id: 'nonconvergence_best_guess',
    regex: RegExp(r'best guess|may not be optimal', caseSensitive: false),
    summary: 'Non-convergence treated as success.',
  ),
  _Rule(
    id: 'simulated_runtime_path',
    regex: RegExp(
      r'NullDeviceOps|simulated devices|useSimulationMode|sequencerSetSimulationMode',
    ),
    summary: 'Simulation path present in runtime code.',
    highRisk: false,
  ),
  _Rule(
    id: 'unimplemented_behavior',
    regex: RegExp(r'not yet implemented|not implemented', caseSensitive: false),
    summary: 'Runtime behavior not implemented.',
  ),
  _Rule(
    id: 'comment_best_effort',
    // Comment patterns indicating known-incomplete behavior. These are how
    // engineers self-document silent fallbacks; we surface them as findings
    // so the register tracks them explicitly rather than living in code.
    regex: RegExp(
      r'//\s*(best[- ]effort|silently ignore|for now we just|temporary|hack|placeholder)',
      caseSensitive: false,
    ),
    summary: 'Comment marks known-incomplete or best-effort behavior.',
  ),
];

void main(List<String> args) {
  final registerPath = _argValue(args, '--register') ?? _defaultRegisterPath;
  final reportPath = _argValue(args, '--report') ?? _defaultReportPath;
  final failOnUnregistered = args.contains('--fail-on-unregistered');
  final failOnOpen = args.contains('--fail-on-open');
  final failOnAnyHighRisk = args.contains('--fail-on-any-highrisk');
  // regression-pin: CI passes either --min-files <N> or the older
  // --assert-at-least-files-scanned <N>. Both names point at the same check;
  // the short form is preferred in new YAML.
  final assertMinFiles =
      _argValue(args, '--min-files') ??
      _argValue(args, '--assert-at-least-files-scanned');

  final findings = <String, String>{};
  final highRisk = <String>{};
  var filesScanned = 0;
  final workspaceRoot = _normalize(Directory.current.absolute.path);

  for (final root in _scanRoots) {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) {
      continue;
    }

    for (final entity in rootDir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }

      final normalizedPath = _toWorkspaceRelative(entity.path, workspaceRoot);
      if (!_isRuntimePath(normalizedPath) || _shouldSkip(normalizedPath)) {
        continue;
      }

      final ext = _extensionOf(normalizedPath);
      if (!_allowedExtensions.contains(ext)) {
        continue;
      }

      final stat = entity.statSync();
      if (stat.size > 2 * 1024 * 1024) {
        continue;
      }

      filesScanned++;
      final lines = _readLinesSafe(entity);
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        for (final rule in _rules) {
          if (rule.languages.isNotEmpty && !rule.languages.contains(ext)) {
            continue;
          }
          if (!rule.regex.hasMatch(line)) {
            continue;
          }
          final key = '$normalizedPath:${i + 1}:${rule.id}';
          findings[key] = line.trimRight();
          if (rule.highRisk) {
            highRisk.add(key);
          }
        }
      }
    }
  }

  final sortedKeys = findings.keys.toList()..sort();
  final reportLines = <String>[];
  for (final key in sortedKeys) {
    reportLines.add('$key:${findings[key]}');
  }
  File(reportPath).writeAsStringSync('${reportLines.join('\n')}\n');

  stdout.writeln('Behavioral audit complete.');
  stdout.writeln('Scanned $filesScanned files');
  stdout.writeln('Findings: ${sortedKeys.length} -> $reportPath');
  stdout.writeln('High-risk findings: ${highRisk.length}');

  // Coverage assertion: CI passes --assert-at-least-files-scanned=N to ensure
  // a scope regression (e.g., accidental glob change) is loud, not silent.
  if (assertMinFiles != null) {
    final required = int.tryParse(assertMinFiles);
    if (required == null) {
      stderr.writeln('Invalid --min-files value: $assertMinFiles');
      exit(2);
    }
    if (filesScanned < required) {
      stderr.writeln(
        'Behavioral audit scanned $filesScanned files; required >= $required',
      );
      exit(1);
    }
  }

  final register = _readRegister(registerPath);
  final unregistered = <String>[];
  final open = <String>[];
  for (final key in sortedKeys) {
    // File-level exemption: register row whose finding_key is the file path
    // alone (no :line:rule suffix). Used for fully auto-generated files
    // (drift/freezed/json_serializable) where every hit is mechanical and
    // line-by-line annotation is not load-bearing.
    final filePath = _filePathOf(key);
    final fileStatus = filePath == null ? null : register[filePath];
    final lineStatus = register[key];
    final status = lineStatus ?? fileStatus;
    if (status == null) {
      unregistered.add(key);
      continue;
    }
    if (!_isClosedStatus(status)) {
      open.add('$key ($status)');
    }
  }

  if (unregistered.isNotEmpty) {
    stderr.writeln(
      'Unregistered behavioral findings (${unregistered.length}):',
    );
    for (final entry in unregistered) {
      stderr.writeln('  $entry');
    }
    if (failOnUnregistered) {
      exit(1);
    }
  }

  if (open.isNotEmpty) {
    stderr.writeln('Open behavioral findings (${open.length}):');
    for (final entry in open) {
      stderr.writeln('  $entry');
    }
    if (failOnOpen) {
      exit(1);
    }
  }

  if (failOnAnyHighRisk && highRisk.isNotEmpty) {
    stderr.writeln('High-risk behavioral findings remain.');
    exit(1);
  }
}

String? _argValue(List<String> args, String key) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == key && i + 1 < args.length) {
      return args[i + 1];
    }
    if (arg.startsWith('$key=')) {
      return arg.substring(key.length + 1);
    }
  }
  return null;
}

Map<String, String> _readRegister(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return const <String, String>{};
  }

  final out = <String, String>{};
  final lines = file.readAsLinesSync();
  for (final raw in lines) {
    final line = raw.trim();
    if (!line.startsWith('|')) {
      continue;
    }
    if (line.contains('finding_key') || line.contains('---')) {
      continue;
    }
    final cols = line
        .split('|')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (cols.length < 2) {
      continue;
    }
    final key = cols[0];
    final status = cols[1].toLowerCase();
    out[key] = status;
  }
  return out;
}

bool _isClosedStatus(String status) {
  switch (status) {
    case 'done':
    case 'accepted_modeled_approximation':
    case 'explicit_unsupported':
    case 'remove':
    case 'auto_generated':
      return true;
    default:
      return false;
  }
}

/// Extracts the file-path portion of a finding key of the form
/// `<path>:<line>:<rule_id>`. Returns null if the key has no trailing
/// `:line:rule` shape (already a file-level entry).
String? _filePathOf(String key) {
  // A finding key always ends in `:<line>:<rule_id>`. We split from the right
  // twice — line numbers are ints, rule IDs are snake_case ASCII.
  final lastColon = key.lastIndexOf(':');
  if (lastColon < 0) {
    return null;
  }
  final secondColon = key.lastIndexOf(':', lastColon - 1);
  if (secondColon < 0) {
    return null;
  }
  final lineStr = key.substring(secondColon + 1, lastColon);
  if (int.tryParse(lineStr) == null) {
    return null;
  }
  return key.substring(0, secondColon);
}

List<String> _readLinesSafe(File file) {
  try {
    return const LineSplitter().convert(file.readAsStringSync());
  } catch (_) {
    try {
      final bytes = file.readAsBytesSync();
      return const LineSplitter().convert(
        utf8.decode(bytes, allowMalformed: true),
      );
    } catch (_) {
      return const <String>[];
    }
  }
}

bool _isRuntimePath(String path) {
  for (final pattern in _runtimePathPatterns) {
    if (pattern.hasMatch(path)) {
      return true;
    }
  }
  return false;
}

bool _shouldSkip(String normalizedPath) {
  // Directory-name match anchored to '/' boundaries — `production_test`
  // is NOT skipped, but any path with /test/ as a real directory IS.
  final segments = normalizedPath.split('/');
  for (final segment in segments) {
    if (_excludedDirectoryNames.contains(segment)) {
      return true;
    }
  }
  for (final substr in _excludedSubstrings) {
    if (normalizedPath.contains(substr)) {
      return true;
    }
  }
  return false;
}

String _extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  return path.substring(dot).toLowerCase();
}

String _normalize(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');

String _toWorkspaceRelative(String path, String workspaceRoot) {
  final absolute = _normalize(File(path).absolute.path);
  final lowerAbsolute = absolute.toLowerCase();
  final lowerRoot = workspaceRoot.toLowerCase();
  if (lowerAbsolute.startsWith(lowerRoot)) {
    final start = workspaceRoot.endsWith('/')
        ? workspaceRoot.length
        : workspaceRoot.length + 1;
    if (absolute.length >= start) {
      return absolute.substring(start);
    }
  }
  return _normalize(path);
}
