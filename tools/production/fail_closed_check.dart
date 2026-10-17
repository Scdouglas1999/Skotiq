import 'dart:convert';
import 'dart:io';

const _jsonOutputPath = 'docs/production-readiness/fail-closed-audit.json';
const _markdownOutputPath = 'docs/production-readiness/fail-closed-audit.md';
const _defaultRulesPath = 'docs/production-readiness/fail_closed_rules.yaml';
const _scanRoots = <String>[
  'apps',
  'packages',
  'native/skotiq_native',
  'tools',
];

class _Rule {
  final String id;
  final String description;
  final String glob;
  final RegExp pattern;
  final String? sinceVersion;
  // require_present: true means the rule fails closed if ZERO files match
  // the glob — catches the case where a regression-pin target file was
  // renamed or deleted and the rule silently became a no-op.
  final bool requirePresent;

  const _Rule({
    required this.id,
    required this.description,
    required this.glob,
    required this.pattern,
    this.sinceVersion,
    this.requirePresent = false,
  });
}

void main(List<String> args) {
  final rulesPath = _argValue(args, '--rules') ?? _defaultRulesPath;
  // regression-pin: CI passes --min-files <N> so an accidental scope
  // shrink (e.g., a glob change that excludes a package, or a vendored
  // directory accidentally entering the exclude list) trips the gate instead
  // of silently reducing coverage.
  final assertMinFiles = _argValue(args, '--min-files');
  final rules = _loadRules(rulesPath);

  final violations = <Map<String, Object?>>[];
  final workspaceRoot = _normalize(Directory.current.absolute.path);

  // Build the candidate file list once. Globs are matched against repo-rel
  // forward-slash paths.
  final allFiles = _collectFiles(workspaceRoot);

  for (final rule in rules) {
    final globRegex = _globToRegExp(rule.glob);
    final matched = allFiles.where((path) => globRegex.hasMatch(path)).toList();
    if (matched.isEmpty) {
      if (rule.requirePresent) {
        violations.add({
          'id': rule.id,
          'description': '[MISSING FILE] ${rule.description}',
          'path': rule.glob,
          'line': null,
          'sinceVersion': rule.sinceVersion,
        });
      }
      continue;
    }

    for (final path in matched) {
      final file = File(path);
      String content;
      try {
        content = file.readAsStringSync();
      } on FileSystemException catch (e) {
        // Read failure should not silently pass — surface it as a violation
        // so a corrupt or unreadable file doesn't bypass policy.
        violations.add({
          'id': rule.id,
          'description': '[READ FAILED] ${rule.description}: ${e.message}',
          'path': path,
          'line': null,
          'sinceVersion': rule.sinceVersion,
        });
        continue;
      }
      final matches = rule.pattern.allMatches(content).toList();
      if (matches.isEmpty) {
        continue;
      }
      for (final match in matches) {
        final line = _lineFromOffset(content, match.start);
        violations.add({
          'id': rule.id,
          'description': rule.description,
          'path': path,
          'line': line,
          'sinceVersion': rule.sinceVersion,
        });
      }
    }
  }

  final report = <String, Object?>{
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'rulesPath': rulesPath,
    'ruleCount': rules.length,
    'filesScanned': allFiles.length,
    'violationCount': violations.length,
    'passed': violations.isEmpty,
    'violations': violations,
  };
  File(_jsonOutputPath).parent.createSync(recursive: true);
  File(
    _jsonOutputPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  File(_markdownOutputPath).parent.createSync(recursive: true);
  File(
    _markdownOutputPath,
  ).writeAsStringSync(_renderMarkdown(rules, violations));

  stdout.writeln('Fail-closed audit complete.');
  stdout.writeln('Rules: ${rules.length}');
  stdout.writeln('Scanned ${allFiles.length} files');
  stdout.writeln('Violations: ${violations.length}');

  // Coverage assertion is evaluated before the violation exit so a scope
  // regression is reported even when the rules happen to match nothing on
  // the shrunken file list.
  if (assertMinFiles != null) {
    final required = int.tryParse(assertMinFiles);
    if (required == null) {
      stderr.writeln('Invalid --min-files value: $assertMinFiles');
      exit(2);
    }
    if (allFiles.length < required) {
      stderr.writeln(
        'Fail-closed check scanned ${allFiles.length} files; required >= $required',
      );
      exit(1);
    }
  }

  if (violations.isEmpty) {
    stdout.writeln('Fail-closed policy checks passed.');
    stdout.writeln('JSON: $_jsonOutputPath');
    stdout.writeln('Markdown: $_markdownOutputPath');
    return;
  }

  stderr.writeln('Fail-closed policy violations detected:');
  for (final violation in violations) {
    stderr.writeln('  ${_violationDisplay(violation)}');
  }
  exit(1);
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

int _lineFromOffset(String content, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < content.length; i++) {
    if (content.codeUnitAt(i) == 10) {
      line++;
    }
  }
  return line;
}

String _renderMarkdown(
  List<_Rule> rules,
  List<Map<String, Object?>> violations,
) {
  final buffer = StringBuffer()
    ..writeln('# Fail-Closed Audit')
    ..writeln()
    ..writeln('- Rules: `${rules.length}`')
    ..writeln('- Violations: `${violations.length}`')
    ..writeln();

  if (violations.isEmpty) {
    buffer.writeln('Fail-closed policy checks passed.');
    return buffer.toString();
  }

  buffer
    ..writeln('## Violations')
    ..writeln();
  for (final violation in violations) {
    buffer.writeln('- ${_violationDisplay(violation)}');
  }
  return buffer.toString();
}

String _violationDisplay(Map<String, Object?> violation) {
  final id = violation['id'];
  final desc = violation['description'];
  final path = violation['path'];
  final line = violation['line'];
  final loc = line == null ? '$path' : '$path:$line';
  return '[$id] $desc ($loc)';
}

List<String> _collectFiles(String workspaceRoot) {
  final out = <String>[];
  for (final root in _scanRoots) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      continue;
    }
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final rel = _toWorkspaceRelative(entity.path, workspaceRoot);
      if (_isExcluded(rel)) {
        continue;
      }
      out.add(rel);
    }
  }
  out.sort();
  return out;
}

bool _isExcluded(String path) {
  // Skip generated, vendored, or build output. These mirror the excludes
  // used by behavioral_audit / placeholder_audit.
  const excludedSegments = <String>{
    '.dart_tool',
    '.git',
    '.worktrees',
    'build',
    'target',
    'coverage',
    'generated',
    'frb_dump',
  };
  final segments = path.split('/');
  for (final seg in segments) {
    if (excludedSegments.contains(seg)) {
      return true;
    }
  }
  if (path.contains('/frb_generated.')) {
    return true;
  }
  return false;
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

// ---------------------------------------------------------------------------
// Glob → RegExp
//
// Supports `**` (any chars including `/`), `*` (any chars except `/`),
// `?` (single char), and bracket character classes. No brace expansion.
// ---------------------------------------------------------------------------
RegExp _globToRegExp(String glob) {
  final buf = StringBuffer('^');
  var i = 0;
  while (i < glob.length) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        buf.write('.*');
        i += 2;
        continue;
      }
      buf.write('[^/]*');
      i++;
      continue;
    }
    if (c == '?') {
      buf.write('[^/]');
      i++;
      continue;
    }
    if (RegExp(r'[.\\+(){}|^$]').hasMatch(c)) {
      buf.write('\\');
      buf.write(c);
      i++;
      continue;
    }
    buf.write(c);
    i++;
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}

// ---------------------------------------------------------------------------
// Minimal YAML loader for this schema
//
// Only handles the structure produced by docs/production-readiness/
// fail_closed_rules.yaml. We deliberately do not depend on package:yaml
// because the rest of tools/production/ avoids dev-dependencies, and the
// schema is small enough to parse directly.
//
// Supported:
//   rules:
//     - id: foo
//       description: "..."
//       description: >-
//         folded scalar across multiple lines
//       glob: path/to/**
//       forbidden_pattern: 'regex'
//       case_sensitive: false
//       multi_line: true
//       require_present: true
//       since_version: 2.5.0
// ---------------------------------------------------------------------------
List<_Rule> _loadRules(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Fail-closed rules file not found: $path');
    exit(2);
  }

  final lines = file.readAsLinesSync();
  final rules = <_Rule>[];
  Map<String, dynamic>? current;
  String? currentFoldedKey;
  String? currentFoldedValue;
  var inRulesList = false;

  void flushRule() {
    if (currentFoldedKey != null && current != null) {
      current![currentFoldedKey!] = (currentFoldedValue ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      currentFoldedKey = null;
      currentFoldedValue = null;
    }
    if (current != null) {
      rules.add(_buildRule(path, current!));
      current = null;
    }
  }

  for (var lineNumber = 0; lineNumber < lines.length; lineNumber++) {
    final raw = lines[lineNumber];
    final stripped = raw.replaceAll('\t', '  ');
    final trimmed = stripped.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }

    final indent = stripped.length - stripped.trimLeft().length;

    if (indent == 0 && trimmed == 'rules:') {
      inRulesList = true;
      continue;
    }
    if (!inRulesList) {
      continue;
    }

    // List item begin: `- id: foo` or `- key: value`
    if (trimmed.startsWith('- ')) {
      flushRule();
      current = <String, dynamic>{};
      final kv = trimmed.substring(2).trim();
      _consumeKeyValue(
        kv,
        current!,
        onFolded: (key) {
          currentFoldedKey = key;
          currentFoldedValue = '';
        },
      );
      continue;
    }

    if (current == null) {
      continue;
    }

    // Continuation of a folded scalar (`>-`): collect lines that are indented
    // deeper than the key.
    if (currentFoldedKey != null) {
      // Folded continuation lines are indented more than the key. The first
      // non-empty line not deeper than indent 6 (`      `) terminates the
      // folded block.
      if (indent >= 8) {
        currentFoldedValue = '${currentFoldedValue ?? ''} ${trimmed}'.trim();
        continue;
      } else {
        // Terminate folded scalar and re-process this line as a new key.
        current![currentFoldedKey!] = (currentFoldedValue ?? '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        currentFoldedKey = null;
        currentFoldedValue = null;
        // fall through
      }
    }

    _consumeKeyValue(
      trimmed,
      current!,
      onFolded: (key) {
        currentFoldedKey = key;
        currentFoldedValue = '';
      },
    );
  }

  flushRule();

  if (rules.isEmpty) {
    stderr.writeln('Fail-closed rules file contains no rules: $path');
    exit(2);
  }
  return rules;
}

void _consumeKeyValue(
  String line,
  Map<String, dynamic> target, {
  required void Function(String key) onFolded,
}) {
  final colon = line.indexOf(':');
  if (colon < 0) {
    return;
  }
  final key = line.substring(0, colon).trim();
  final rawValue = line.substring(colon + 1).trim();
  if (rawValue.isEmpty) {
    return;
  }
  if (rawValue == '>-' ||
      rawValue == '>' ||
      rawValue == '|' ||
      rawValue == '|-') {
    onFolded(key);
    return;
  }
  target[key] = _stripQuotes(rawValue);
}

String _stripQuotes(String value) {
  if (value.length >= 2) {
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

_Rule _buildRule(String rulesPath, Map<String, dynamic> map) {
  final id = (map['id'] ?? '').toString();
  final description = (map['description'] ?? '').toString();
  final glob = (map['glob'] ?? '').toString();
  final patternStr = (map['forbidden_pattern'] ?? '').toString();
  if (id.isEmpty || glob.isEmpty || patternStr.isEmpty) {
    stderr.writeln(
      'Invalid rule in $rulesPath: id, glob, and forbidden_pattern are required '
      '(got id="$id" glob="$glob" pattern="$patternStr").',
    );
    exit(2);
  }
  final caseSensitive = _parseBool(map['case_sensitive'], defaultValue: true);
  final multiLine = _parseBool(map['multi_line'], defaultValue: false);
  final requirePresent = _parseBool(
    map['require_present'],
    defaultValue: false,
  );
  final RegExp regex;
  try {
    regex = RegExp(
      patternStr,
      caseSensitive: caseSensitive,
      multiLine: multiLine,
    );
  } on FormatException catch (e) {
    stderr.writeln('Invalid regex in rule "$id" ($rulesPath): ${e.message}');
    exit(2);
  }
  return _Rule(
    id: id,
    description: description.isEmpty ? id : description,
    glob: glob,
    pattern: regex,
    sinceVersion: map['since_version']?.toString(),
    requirePresent: requirePresent,
  );
}

bool _parseBool(Object? value, {required bool defaultValue}) {
  if (value == null) {
    return defaultValue;
  }
  final s = value.toString().toLowerCase();
  if (s == 'true' || s == 'yes' || s == '1') {
    return true;
  }
  if (s == 'false' || s == 'no' || s == '0') {
    return false;
  }
  return defaultValue;
}
