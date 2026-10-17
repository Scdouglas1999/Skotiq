import 'dart:convert';
import 'dart:io';

const _scanRoots = <String>['apps', 'packages', 'native/skotiq_native'];
const _defaultHitsPath = '.audit_hits.txt';
const _defaultHighRiskPath = '.audit_highrisk.txt';
const _defaultAllowlistPath =
    'docs/production-readiness/placeholder-allowlist.txt';

const _allowedExtensions = <String>{
  '.dart',
  '.rs',
  '.swift',
  '.kt',
  '.kts',
  '.java',
  '.m',
  '.mm',
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.cs',
  '.js',
  '.ts',
  '.sh',
  '.ps1',
  '.toml',
  '.yaml',
  '.yml',
};

// Excluded directory NAMES anchored to path-segment boundaries (NOT substring
// matches), so a production module at packages/skotiq_test_utils/lib/...
// is not skipped for merely carrying a `/test/`-like fragment in its path.
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

// Substrings that genuinely identify generated code regardless of where they
// appear in the path. `frb_generated.` is a filename prefix produced by
// flutter_rust_bridge, never a hand-authored module.
const _excludedSubstrings = <String>['/frb_generated.'];

final _runtimePathPatterns = <RegExp>[
  RegExp(r'^apps/[^/]+/lib/'),
  RegExp(r'^packages/[^/]+/lib/'),
  RegExp(r'^native/skotiq_native(?:/[^/]+)+/src/'),
];

final _markerPattern = RegExp(
  r'\bTODO\b|\bFIXME\b|placeholder|\bstub\b|'
  r'UnimplementedError|not implemented|for now|no-?op|'
  // Common silent-fallback shapes:
  r'catch\s*\(\s*_\s*\)\s*\{?\s*\}?|'
  r'let\s+_\s*=|'
  r'\.unwrap_or_default\(\)|'
  r'\.ok\(\)\s*;|'
  // Dart `?? null|0|false|''|""` fallback to a fixed value.
  // Single quotes inside double-quoted Dart string require no escaping;
  // the inner `''` is the regex literal for two single quotes.
  "\\?\\?\\s*(null|0|false|''|\"\")|"
  // Comment markers that engineers use to flag known-incomplete behavior.
  r'//\s*(best[- ]effort|silently ignore|for now we just|temporary|hack|placeholder)',
  caseSensitive: false,
);

final _highRiskPattern = RegExp(
  r'UnimplementedError|not implemented|'
  r'placeholder\s*-\s*to be implemented|'
  r'for now\s+return|for now,\s*return|for now\s+we\s+\w+\s+support|'
  r'no-?op in stub mode|silent no-?op|would be\b.+stub mode|'
  r'simulator implementation for now|'
  // Empty Dart catch swallows runtime errors entirely — high-risk.
  r'catch\s*\(\s*_\s*\)\s*\{\s*\}|'
  // `.unwrap_or_default()` and `.ok();` actively discard error/None info.
  r'\.unwrap_or_default\(\)|'
  r'\.ok\(\)\s*;',
  caseSensitive: false,
);

void main(List<String> args) {
  final hitsPath = _argValue(args, '--out-hits') ?? _defaultHitsPath;
  final highRiskPath =
      _argValue(args, '--out-highrisk') ?? _defaultHighRiskPath;
  final compareBaseline = _argValue(args, '--compare-highrisk-baseline');
  final allowlistPath = _argValue(args, '--allowlist') ?? _defaultAllowlistPath;
  final failOnNewHighRisk = args.contains('--fail-on-new-highrisk');
  final failOnAnyHighRisk = args.contains('--fail-on-any-highrisk');
  // regression-pin: CI passes either --min-files <N> or the older
  // --assert-at-least-files-scanned <N>. Both names point at the same check;
  // the short form is preferred in new YAML.
  final assertMinFiles =
      _argValue(args, '--min-files') ??
      _argValue(args, '--assert-at-least-files-scanned');

  final allowlist = _loadAllowlist(allowlistPath);
  final hits = <String>{};
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
      if (!_hasAllowedExtension(normalizedPath)) {
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
        if (!_markerPattern.hasMatch(line)) {
          continue;
        }

        final trimmed = line.trimRight();
        final entry = '$normalizedPath:${i + 1}:$trimmed';
        if (_isAllowlisted(entry, allowlist)) {
          continue;
        }

        hits.add(entry);
        if (_highRiskPattern.hasMatch(line)) {
          highRisk.add(entry);
        }
      }
    }
  }

  final sortedHits = hits.toList()..sort();
  final sortedHighRisk = highRisk.toList()..sort();

  _writeTextFile(hitsPath, '${sortedHits.join('\n')}\n');
  _writeTextFile(highRiskPath, '${sortedHighRisk.join('\n')}\n');

  stdout.writeln('Runtime marker audit complete.');
  stdout.writeln('Scanned $filesScanned files');
  stdout.writeln('Hits: ${sortedHits.length} -> $hitsPath');
  stdout.writeln('High-risk hits: ${sortedHighRisk.length} -> $highRiskPath');

  // Coverage assertion: CI can pass --assert-at-least-files-scanned=N
  // so an accidental scope regression — e.g., a glob change that excludes a
  // package — fails the gate instead of silently shrinking coverage.
  if (assertMinFiles != null) {
    final required = int.tryParse(assertMinFiles);
    if (required == null) {
      stderr.writeln('Invalid --min-files value: $assertMinFiles');
      exit(2);
    }
    if (filesScanned < required) {
      stderr.writeln(
        'Placeholder audit scanned $filesScanned files; required >= $required',
      );
      exit(1);
    }
  }

  if (failOnAnyHighRisk && sortedHighRisk.isNotEmpty) {
    stderr.writeln('High-risk runtime markers detected.');
    exit(1);
  }

  if (compareBaseline == null) {
    return;
  }

  final baselineFile = File(compareBaseline);
  if (!baselineFile.existsSync()) {
    stderr.writeln('Baseline not found: $compareBaseline');
    exit(2);
  }

  final baseline = baselineFile
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map(_highRiskBaselineSignature)
      .toSet();

  final newHighRisk = sortedHighRisk
      .where((entry) => !baseline.contains(_highRiskBaselineSignature(entry)))
      .toList();
  if (newHighRisk.isEmpty) {
    stdout.writeln('No new high-risk markers compared to baseline.');
    return;
  }

  stderr.writeln('Detected ${newHighRisk.length} new high-risk markers:');
  for (final entry in newHighRisk) {
    stderr.writeln('  $entry');
  }

  if (failOnNewHighRisk) {
    exit(1);
  }
}

String _highRiskBaselineSignature(String entry) {
  final match = RegExp(r'^([^:]+):\d+:(.*)$').firstMatch(entry);
  if (match == null) {
    return entry;
  }
  return '${match.group(1)}:${match.group(2)}';
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

void _writeTextFile(String path, String content) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

class _AllowlistEntry {
  // Full normalized line: either `path:line` or `path:line:trimmed_text`.
  // Path-only entries are rejected at load time — they whitelisted
  // every line in the file forever and were a foot-gun for false negatives.
  final String fullEntry;
  final String path;
  final int line;
  final String? exactText;

  _AllowlistEntry({
    required this.fullEntry,
    required this.path,
    required this.line,
    required this.exactText,
  });
}

List<_AllowlistEntry> _loadAllowlist(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return const <_AllowlistEntry>[];
  }

  final entries = <_AllowlistEntry>[];
  final rawLines = file.readAsLinesSync();
  for (var lineNumber = 0; lineNumber < rawLines.length; lineNumber++) {
    final raw = rawLines[lineNumber].trim();
    if (raw.isEmpty || raw.startsWith('#')) {
      continue;
    }
    final normalized = _normalize(raw);
    final firstColon = normalized.indexOf(':');
    if (firstColon < 0) {
      // Path-only entry — reject loudly rather than silently widening the
      // allowlist to a whole file.
      stderr.writeln(
        'Invalid allowlist entry at $path:${lineNumber + 1}: '
        '"$raw" — path-only entries are not allowed. '
        'Use "path:line" or "path:line:exact_text" for granularity.',
      );
      exit(2);
    }
    final secondColon = normalized.indexOf(':', firstColon + 1);
    final pathPart = normalized.substring(0, firstColon);
    final String linePart;
    final String? textPart;
    if (secondColon < 0) {
      linePart = normalized.substring(firstColon + 1);
      textPart = null;
    } else {
      linePart = normalized.substring(firstColon + 1, secondColon);
      textPart = normalized.substring(secondColon + 1);
    }
    final lineNo = int.tryParse(linePart);
    if (lineNo == null) {
      stderr.writeln(
        'Invalid allowlist entry at $path:${lineNumber + 1}: '
        '"$raw" — second segment must be a line number, got "$linePart". '
        'Use "path:line" or "path:line:exact_text".',
      );
      exit(2);
    }
    entries.add(
      _AllowlistEntry(
        fullEntry: normalized,
        path: pathPart,
        line: lineNo,
        exactText: textPart,
      ),
    );
  }
  return entries;
}

bool _isAllowlisted(String entry, List<_AllowlistEntry> allowlist) {
  if (allowlist.isEmpty) {
    return false;
  }
  final normalizedEntry = _normalize(entry);
  // Format from main loop: path:line:trimmed_text
  final firstColon = normalizedEntry.indexOf(':');
  final secondColon = firstColon >= 0
      ? normalizedEntry.indexOf(':', firstColon + 1)
      : -1;
  if (firstColon < 0 || secondColon < 0) {
    return false;
  }
  final entryPath = normalizedEntry.substring(0, firstColon);
  final entryLineStr = normalizedEntry.substring(firstColon + 1, secondColon);
  final entryText = normalizedEntry.substring(secondColon + 1);
  final entryLineNo = int.tryParse(entryLineStr);
  if (entryLineNo == null) {
    return false;
  }

  for (final candidate in allowlist) {
    if (candidate.path != entryPath || candidate.line != entryLineNo) {
      continue;
    }
    if (candidate.exactText == null) {
      // path:line entry — allow regardless of exact text.
      return true;
    }
    if (candidate.exactText == entryText) {
      return true;
    }
  }
  return false;
}

bool _hasAllowedExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) {
    return false;
  }
  final ext = path.substring(dot).toLowerCase();
  return _allowedExtensions.contains(ext);
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
  // Directory-name match: only path SEGMENTS named exactly "test" / "example"
  // / etc. are excluded. Production modules whose paths happen to contain
  // those words as a substring (e.g., `skotiq_test_utils`) are scanned.
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
