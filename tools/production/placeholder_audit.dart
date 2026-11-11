import 'dart:io';

import 'src/audit_scope.dart';
import 'src/behavioral_scan.dart' show readLinesLenient;
import 'src/site_register.dart';

/// Placeholder/stub marker audit.
///
/// Lists every placeholder-like marker in runtime code, and the high-risk
/// subset. With `--compare-highrisk-baseline <file>` the high-risk hits are
/// compared with the triaged baseline; `--fail-on-new-highrisk` fails on any
/// hit the baseline does not cover.
///
/// The baseline is a sites file (see `src/site_register.dart`): a hit is
/// keyed by enclosing declaration and line text, with the path as a hint, so
/// moved or re-numbered code stays covered with no edit.
///
/// Maintenance flags (each rewrites the baseline, then the gate runs):
/// - `--sync-baseline`: refresh path hints, drop entries whose code is gone,
///   carry an entry to the same line text under a renamed declaration.
/// - `--accept-new-highrisk`: add every uncovered high-risk hit after review.
///   `--only <path prefix>` narrows it.
const _defaultHitsPath = '.audit_hits.txt';
const _defaultHighRiskPath = '.audit_highrisk.txt';
const _defaultAllowlistPath =
    'docs/production-readiness/placeholder-allowlist.txt';

const highRiskRule = 'highrisk';
const baselineVerdict = 'baseline';

const _baselineHeader = '''
Triaged high-risk placeholder markers. Written by tools/production/placeholder_audit.dart;
do not edit by hand (see docs/ci-gates.md, "Keeping the audit gates in step").
An entry is matched by scope + text. The path is a hint and may be stale.
''';

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

class PlaceholderScan {
  final List<String> files;

  /// `path:line:text` for every marker.
  final List<String> hits;
  final List<Finding> highRisk;

  /// `path:line:text` for the high-risk subset.
  final List<String> highRiskHits;

  const PlaceholderScan(
    this.files,
    this.hits,
    this.highRisk,
    this.highRiskHits,
  );
}

PlaceholderScan scanPlaceholders(AuditScope scope, String allowlistPath) {
  final allowlist = _loadAllowlist(allowlistPath);
  final files = <String>[];
  final hits = <String>[];
  final highRisk = <Finding>[];
  final highRiskHits = <String>[];
  for (final path in scope.runtimeFiles(extensions: _allowedExtensions)) {
    final file = File(path);
    if (file.statSync().size > 2 * 1024 * 1024) {
      continue;
    }
    files.add(path);
    final lines = readLinesLenient(file);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!_markerPattern.hasMatch(line)) {
        continue;
      }
      final entry = '$path:${i + 1}:${line.trimRight()}';
      if (_isAllowlisted(entry, allowlist)) {
        continue;
      }
      hits.add(entry);
      if (_highRiskPattern.hasMatch(line)) {
        highRiskHits.add(entry);
        highRisk.add(
          Finding(
            rule: highRiskRule,
            scope: enclosingScope(lines, i, extensionOf(path)),
            text: normalizeText(line),
            path: path,
            line: i + 1,
          ),
        );
      }
    }
  }
  return PlaceholderScan(files, hits..sort(), highRisk, highRiskHits..sort());
}

void writeBaseline(String path, List<SiteRow> rows) =>
    writeSites(path, rows, header: _baselineHeader);

void main(List<String> args) {
  final hitsPath = argValue(args, '--out-hits') ?? _defaultHitsPath;
  final highRiskPath = argValue(args, '--out-highrisk') ?? _defaultHighRiskPath;
  final compareBaseline = argValue(args, '--compare-highrisk-baseline');
  final allowlistPath = argValue(args, '--allowlist') ?? _defaultAllowlistPath;
  final failOnNewHighRisk = args.contains('--fail-on-new-highrisk');
  final failOnAnyHighRisk = args.contains('--fail-on-any-highrisk');
  final only = argValue(args, '--only');

  final scope = AuditScope.fromArgs(args);
  final scan = scanPlaceholders(scope, allowlistPath);
  _writeTextFile(hitsPath, '${scan.hits.join('\n')}\n');
  _writeTextFile(highRiskPath, '${scan.highRiskHits.join('\n')}\n');

  stdout.writeln('Runtime marker audit complete.');
  stdout.writeln('Scanned ${scan.files.length} files');
  stdout.writeln('Hits: ${scan.hits.length} -> $hitsPath');
  stdout.writeln('High-risk hits: ${scan.highRisk.length} -> $highRiskPath');

  scope.assertCoverage('Placeholder audit', scan.files, args);

  if (failOnAnyHighRisk && scan.highRisk.isNotEmpty) {
    stderr.writeln('High-risk runtime markers detected.');
    exit(1);
  }

  if (compareBaseline == null) {
    return;
  }
  if (!File(compareBaseline).existsSync()) {
    stderr.writeln('Baseline not found: $compareBaseline');
    exit(2);
  }
  var rows = readSites(compareBaseline);

  if (args.contains('--sync-baseline')) {
    final sync = syncSites(scan.highRisk, rows);
    for (final c in sync.carriedByText) {
      stdout.writeln(
        'Carried [${c.from.scope}] ${c.from.path} -> ${c.finding.display}',
      );
    }
    stdout.writeln(
      'Sync: ${sync.carriedByText.length} entries carried, '
      '${sync.keptUnmatched ? 0 : sync.unmatchedCount} dropped.',
    );
    if (sync.keptUnmatched) {
      stdout.writeln(
        'Kept ${sync.unmatchedCount} entries that match no code while '
        '${sync.unregistered.length} markers are still new. They are '
        'dropped by the next --sync-baseline once nothing is new.',
      );
    }
    rows = sync.rows;
    writeBaseline(compareBaseline, rows);
  }

  if (args.contains('--accept-new-highrisk')) {
    final pending = matchSites(
      scan.highRisk,
      rows,
    ).unregistered.where((f) => only == null || f.path.startsWith(only));
    var added = 0;
    for (final finding in pending) {
      rows.add(
        SiteRow(
          rule: highRiskRule,
          scope: finding.scope,
          text: finding.text,
          verdict: baselineVerdict,
          path: finding.path,
        ),
      );
      added++;
    }
    writeBaseline(compareBaseline, rows);
    rows = readSites(compareBaseline);
    stdout.writeln('Added $added high-risk markers to the baseline.');
  }

  final match = matchSites(scan.highRisk, rows);
  if (match.staleCount > 0) {
    stdout.writeln(
      'Prunable: ${match.staleCount} baseline entries describe code that is '
      'gone. Run with --sync-baseline to drop them.',
    );
  }
  if (match.unregistered.isEmpty) {
    stdout.writeln('No new high-risk markers compared to baseline.');
    return;
  }

  stderr.writeln(
    'Detected ${match.unregistered.length} new high-risk markers:',
  );
  for (final finding in match.unregistered) {
    stderr.writeln(
      '  ${finding.path}:${finding.line} [${finding.scope}] ${finding.text}',
    );
  }

  if (failOnNewHighRisk) {
    exit(1);
  }
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

String _normalize(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');
