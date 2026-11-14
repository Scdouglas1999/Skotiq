import 'dart:io';

import 'src/audit_scope.dart';
import 'src/behavioral_scan.dart';
import 'src/site_register.dart';

/// Behavioral audit gate.
///
/// Every silent-fallback shape in runtime code (see `src/behavioral_scan.dart`
/// for the rules) must carry a reviewed verdict. Two files hold the review:
///
/// - the register (`--register`, Markdown): one row per verdict —
///   `| verdict | status | owner | notes |`. People write this.
/// - the sites file (`--sites`, default `<register>.sites.tsv`): one row per
///   reviewed site, pointing at a verdict. The tool writes this.
///
/// A site is keyed by rule, enclosing declaration and line text; its path is a
/// hint. Moved or re-numbered code keeps its verdict with no edit.
///
/// Gate flags: `--fail-on-unregistered`, `--fail-on-open`,
/// `--fail-on-any-highrisk`, `--min-files N`.
///
/// Maintenance flags (each rewrites the sites file, then the gate runs):
/// - `--sync`: refresh path hints, drop rows whose code is gone, and carry a
///   verdict to the same line text under a renamed declaration.
///   `--carry-edited` also follows a line edited in place when it is the only
///   candidate in its declaration.
/// - `--accept-new <verdict>`: register every unregistered finding under an
///   existing verdict. `--only <path prefix>` narrows it.
/// - `--prune-verdicts`: remove register rows no site points at.
const _defaultRegisterPath =
    'docs/production-readiness/behavioral-audit-register.md';
const _defaultReportPath = '.behavioral_audit_hits.txt';

const _sitesHeader = '''
Reviewed behavioral-audit sites. Written by tools/production/behavioral_audit.dart;
do not edit by hand (see docs/ci-gates.md, "Keeping the audit gates in step").
A site is matched by rule + scope + text. The path is a hint and may be stale.
''';

const _closedStatuses = <String>{
  'done',
  'accepted_modeled_approximation',
  'explicit_unsupported',
  'remove',
  'auto_generated',
};

void main(List<String> args) {
  final registerPath = argValue(args, '--register') ?? _defaultRegisterPath;
  final sitesPath = argValue(args, '--sites') ?? sitesPathFor(registerPath);
  final reportPath = argValue(args, '--report') ?? _defaultReportPath;
  final failOnUnregistered = args.contains('--fail-on-unregistered');
  final failOnOpen = args.contains('--fail-on-open');
  final failOnAnyHighRisk = args.contains('--fail-on-any-highrisk');
  final acceptVerdict = argValue(args, '--accept-new');
  final only = argValue(args, '--only');

  final scope = AuditScope.fromArgs(args);
  final scan = scanBehavioral(scope);
  final findings = scan.findings;

  final report = findings.toList()
    ..sort((a, b) {
      final byPath = a.path.compareTo(b.path);
      return byPath != 0 ? byPath : a.line.compareTo(b.line);
    });
  File(reportPath).writeAsStringSync(
    '${report.map((f) => '${f.path}:${f.line}:${f.rule}:${f.text}').join('\n')}\n',
  );

  stdout.writeln('Behavioral audit complete.');
  stdout.writeln('Scanned ${scan.files.length} files');
  stdout.writeln('Findings: ${findings.length} -> $reportPath');
  stdout.writeln('High-risk findings: ${scan.highRisk.length}');

  scope.assertCoverage('Behavioral audit', scan.files, args);

  var verdicts = readVerdicts(registerPath);
  var rows = readSites(sitesPath);
  // Open rows are paired first so a closed row can never absorb the finding
  // an open one is about.
  int rank(SiteRow row) => _isClosed(verdicts[row.verdict]) ? 1 : 0;

  if (args.contains('--sync')) {
    final sync = syncSites(
      findings,
      rows,
      carryEdited: args.contains('--carry-edited'),
      rank: rank,
    );
    for (final c in sync.carriedByText) {
      stdout.writeln(
        'Carried ${c.from.verdict} [${c.from.scope}] ${c.from.path} -> '
        '${c.finding.display}',
      );
    }
    for (final c in sync.carriedEdited) {
      stdout.writeln(
        'Carried ${c.from.verdict} across an edit: "${c.from.text}" -> '
        '${c.finding.display}',
      );
    }
    stdout.writeln(
      'Sync: ${sync.carriedByText.length + sync.carriedEdited.length} '
      'verdicts carried, '
      '${sync.keptUnmatched ? 0 : sync.unmatchedCount} rows dropped.',
    );
    if (sync.keptUnmatched) {
      stdout.writeln(
        'Kept ${sync.unmatchedCount} rows that match no code: '
        '${sync.unregistered.length} findings are still unregistered and '
        'may be that code after an edit (--carry-edited). They are dropped '
        'by the next --sync once nothing is unregistered.',
      );
    }
    rows = sync.rows;
    writeSites(sitesPath, rows, header: _sitesHeader);
  }

  if (acceptVerdict != null) {
    if (!verdicts.containsKey(acceptVerdict)) {
      stderr.writeln(
        'Verdict "$acceptVerdict" is not in $registerPath. Add its row '
        '(| $acceptVerdict | status | owner | notes |) first.',
      );
      exit(2);
    }
    final pending = matchSites(
      findings,
      rows,
      rank: rank,
    ).unregistered.where((f) => only == null || f.path.startsWith(only));
    var added = 0;
    for (final finding in pending) {
      rows.add(
        SiteRow(
          rule: finding.rule,
          scope: finding.scope,
          text: finding.text,
          verdict: acceptVerdict,
          path: finding.path,
        ),
      );
      added++;
    }
    writeSites(sitesPath, rows, header: _sitesHeader);
    rows = readSites(sitesPath);
    stdout.writeln('Registered $added findings under $acceptVerdict.');
  }

  if (args.contains('--prune-verdicts')) {
    final used = rows.map((row) => row.verdict).toSet();
    final removed = _pruneVerdicts(registerPath, used);
    verdicts = readVerdicts(registerPath);
    stdout.writeln('Removed $removed unused verdict rows from $registerPath.');
  }

  final match = matchSites(findings, rows, rank: rank);
  final unregistered = match.unregistered.map((f) => f.display).toList();
  final open = <String>[];
  for (final entry in match.assigned.entries) {
    final verdict = verdicts[entry.value.verdict];
    if (verdict == null) {
      unregistered.add(
        '${entry.key.display} (verdict ${entry.value.verdict} is not in '
        '$registerPath)',
      );
    } else if (!_isClosed(verdict)) {
      open.add('${entry.key.display} (${verdict.status})');
    }
  }

  stdout.writeln(
    'Registered: ${match.assigned.length} '
    '(${match.moved} matched away from their recorded path)',
  );
  if (match.staleCount > 0) {
    stdout.writeln(
      'Prunable: ${match.staleCount} site rows describe code that is gone. '
      'Run with --sync to drop them.',
    );
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

  if (failOnAnyHighRisk && scan.highRisk.isNotEmpty) {
    stderr.writeln('High-risk behavioral findings remain.');
    exit(1);
  }
}

String sitesPathFor(String registerPath) {
  final stem = registerPath.endsWith('.md')
      ? registerPath.substring(0, registerPath.length - 3)
      : registerPath;
  return '$stem.sites.tsv';
}

class Verdict {
  final String status;
  final String owner;
  final String notes;
  const Verdict(this.status, this.owner, this.notes);
}

bool _isClosed(Verdict? verdict) =>
    verdict != null && _closedStatuses.contains(verdict.status);

/// Splits a register table row into trimmed cells, or null for anything that
/// is not a verdict row (prose, the header, the separator).
List<String>? _verdictCells(String raw) {
  final line = raw.trim();
  if (!line.startsWith('|')) {
    return null;
  }
  final cells = line
      .split('|')
      .map((cell) => cell.trim())
      .where((cell) => cell.isNotEmpty)
      .toList();
  if (cells.length < 2 ||
      cells.first == 'verdict' ||
      cells.every((cell) => RegExp(r'^:?-+:?$').hasMatch(cell))) {
    return null;
  }
  return cells;
}

Map<String, Verdict> readVerdicts(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return const <String, Verdict>{};
  }
  final out = <String, Verdict>{};
  for (final raw in file.readAsLinesSync()) {
    final cells = _verdictCells(raw);
    if (cells == null) {
      continue;
    }
    if (out.containsKey(cells[0])) {
      stderr.writeln('Duplicate verdict id "${cells[0]}" in $path');
      exit(2);
    }
    out[cells[0]] = Verdict(
      cells[1].toLowerCase(),
      cells.length > 2 ? cells[2] : '',
      cells.length > 3 ? cells.sublist(3).join(' | ') : '',
    );
  }
  return out;
}

int _pruneVerdicts(String path, Set<String> used) {
  final file = File(path);
  if (!file.existsSync()) {
    return 0;
  }
  var removed = 0;
  final kept = <String>[];
  for (final raw in file.readAsLinesSync()) {
    final cells = _verdictCells(raw);
    if (cells != null && !used.contains(cells[0])) {
      removed++;
      continue;
    }
    kept.add(raw);
  }
  if (removed > 0) {
    file.writeAsStringSync('${kept.join('\n')}\n');
  }
  return removed;
}
