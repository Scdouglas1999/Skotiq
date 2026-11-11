import 'dart:io';

import 'behavioral_audit.dart' show readVerdicts, sitesPathFor;
import 'placeholder_audit.dart'
    show baselineVerdict, highRiskRule, scanPlaceholders, writeBaseline;
import 'src/audit_scope.dart';
import 'src/behavioral_scan.dart';
import 'src/site_register.dart';

/// One-time migration of the two line/path-keyed audit inputs to site-keyed
/// form, with a proof that every verdict in force before is in force after.
///
///   dart run tools/production/migrate_audit_registers.dart \
///     --old-register OLD_REGISTER --old-baseline OLD_BASELINE \
///     --register OUT_MD --baseline OUT_TXT --evidence DIR
void main(List<String> args) {
  final oldRegisterPath = argValue(args, '--old-register')!;
  final oldBaselinePath = argValue(args, '--old-baseline')!;
  final registerPath = argValue(args, '--register')!;
  final baselinePath = argValue(args, '--baseline')!;
  final evidence = Directory(argValue(args, '--evidence')!)
    ..createSync(recursive: true);
  final scope = AuditScope.fromArgs(args);

  _migrateRegister(scope, oldRegisterPath, registerPath, evidence);
  _migrateBaseline(scope, oldBaselinePath, baselinePath, evidence);
}

class _OldRow {
  final String key;
  final String status;
  final String owner;
  final String notes;
  _OldRow(this.key, this.status, this.owner, this.notes);

  String get verdictKey => '$status\u0000$owner\u0000$notes';
}

void _migrateRegister(
  AuditScope scope,
  String oldPath,
  String newPath,
  Directory evidence,
) {
  // Same row parsing as the old tool.
  final oldRows = <String, _OldRow>{};
  for (final raw in File(oldPath).readAsLinesSync()) {
    final line = raw.trim();
    if (!line.startsWith('|') ||
        line.contains('finding_key') ||
        line.contains('---')) {
      continue;
    }
    final cols = line
        .split('|')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    if (cols.length < 2) {
      continue;
    }
    oldRows[cols[0]] = _OldRow(
      cols[0],
      cols[1].toLowerCase(),
      cols.length > 2 ? cols[2] : '',
      cols.length > 3 ? cols.sublist(3).join(' | ') : '',
    );
  }

  final scan = scanBehavioral(scope);
  // The old tool's lookup: the line-keyed row, else the file-level row.
  _OldRow? oldRowFor(Finding f) =>
      oldRows['${f.path}:${f.line}:${f.rule}'] ?? oldRows[f.path];

  final verdictIds = <String, String>{};
  final verdictRows = <String, _OldRow>{};
  final liveOldKeys = <String>{};
  // Ids follow the old register's order so the migration is reproducible.
  final usedVerdictKeys = <String>{};
  final unregistered = <Finding>[];
  for (final finding in scan.findings) {
    final row = oldRowFor(finding);
    if (row == null) {
      unregistered.add(finding);
      continue;
    }
    liveOldKeys.add(row.key);
    usedVerdictKeys.add(row.verdictKey);
  }
  for (final row in oldRows.values) {
    if (usedVerdictKeys.contains(row.verdictKey) &&
        !verdictIds.containsKey(row.verdictKey)) {
      final id = 'V${(verdictIds.length + 1).toString().padLeft(4, '0')}';
      verdictIds[row.verdictKey] = id;
      verdictRows[id] = row;
    }
  }

  final sites = <SiteRow>[
    for (final finding in scan.findings)
      if (oldRowFor(finding) case final row?)
        SiteRow(
          rule: finding.rule,
          scope: finding.scope,
          text: finding.text,
          verdict: verdictIds[row.verdictKey]!,
          path: finding.path,
        ),
  ];

  final md = StringBuffer()
    ..writeln('# Behavioral Audit Register')
    ..writeln()
    ..writeln(
      'Reviewed verdicts for the findings of '
      '`tools/production/behavioral_audit.dart`. Each row is one verdict; '
      '`${sitesPathFor(newPath).split('/').last}` next to this file lists '
      'the code sites each verdict covers and is written by the tool. A '
      'site is matched by rule, enclosing declaration and line text, so '
      'moving code or shifting lines needs no edit here. See '
      '`docs/ci-gates.md` ("Keeping the audit gates in step").',
    )
    ..writeln()
    ..writeln(
      'Closed statuses: `done`, `accepted_modeled_approximation`, '
      '`explicit_unsupported`, `remove`, `auto_generated`. Anything else is '
      'open and fails the gate.',
    )
    ..writeln()
    ..writeln('| verdict | status | owner | notes |')
    ..writeln('| --- | --- | --- | --- |');
  for (final entry in verdictRows.entries) {
    final row = entry.value;
    md.writeln(
      '| ${entry.key} | ${row.status} | ${row.owner} | ${row.notes} |',
    );
  }
  File(newPath).writeAsStringSync(md.toString());
  writeSites(
    sitesPathFor(newPath),
    sites,
    header:
        'Reviewed behavioral-audit sites. Written by '
        'tools/production/behavioral_audit.dart;\n'
        'do not edit by hand (see docs/ci-gates.md, "Keeping the audit gates '
        'in step").\n'
        'A site is matched by rule + scope + text. The path is a hint and '
        'may be stale.',
  );

  // Proof: read the new files back through the gate's own code and compare
  // the verdict in force for every finding.
  final verdicts = readVerdicts(newPath);
  final match = matchSites(scan.findings, readSites(sitesPathFor(newPath)));
  var same = 0;
  final different = <String>[];
  for (final finding in scan.findings) {
    final before = oldRowFor(finding);
    final after = verdicts[match.assigned[finding]?.verdict];
    if (before == null && after == null) {
      continue;
    }
    if (before != null &&
        after != null &&
        before.status == after.status &&
        before.owner == after.owner &&
        before.notes == after.notes) {
      same++;
    } else {
      different.add(finding.display);
    }
  }

  // Where every old row went.
  final rowMap = StringBuffer('old_key\tfate\tverdict\n');
  var liveLine = 0, liveFile = 0, deadFileGone = 0, deadNoFinding = 0;
  for (final row in oldRows.values) {
    final isLineRow = RegExp(r':\d+:[a-z_]+$').hasMatch(row.key);
    final path = isLineRow
        ? row.key.replaceFirst(RegExp(r':\d+:[a-z_]+$'), '')
        : row.key;
    final String fate;
    if (liveOldKeys.contains(row.key)) {
      fate = 'migrated';
      isLineRow ? liveLine++ : liveFile++;
    } else if (!File(path).existsSync()) {
      fate = 'dropped: file no longer exists';
      deadFileGone++;
    } else {
      fate = 'dropped: no finding at this key';
      deadNoFinding++;
    }
    rowMap.writeln('${row.key}\t$fate\t${verdictIds[row.verdictKey] ?? ''}');
  }
  File(
    '${evidence.path}/behavioral-row-map.tsv',
  ).writeAsStringSync(rowMap.toString());

  final summary = StringBuffer()
    ..writeln('Behavioral register migration')
    ..writeln('  old rows: ${oldRows.length}')
    ..writeln(
      '    in force (cover a finding): ${liveLine + liveFile} '
      '($liveLine line-keyed, $liveFile file-level)',
    )
    ..writeln('    dropped, file no longer exists: $deadFileGone')
    ..writeln('    dropped, file exists but nothing at the key: $deadNoFinding')
    ..writeln('  findings: ${scan.findings.length}')
    ..writeln(
      '    covered before: ${scan.findings.length - unregistered.length}',
    )
    ..writeln('    covered after with identical status/owner/notes: $same')
    ..writeln('    verdict differs or lost: ${different.length}')
    ..writeln(
      '    unregistered before: ${unregistered.length}, '
      'after: ${match.unregistered.length}',
    )
    ..writeln(
      '  new register: ${verdictRows.length} verdict rows '
      '(old rows with identical status/owner/notes share one), '
      '${mergeRows(sites).length} site rows',
    );
  for (final entry in different) {
    summary.writeln('  DIFFERENT $entry');
  }
  File(
    '${evidence.path}/behavioral-summary.txt',
  ).writeAsStringSync(summary.toString());
  stdout.write(summary);
  if (different.isNotEmpty ||
      match.unregistered.length != unregistered.length) {
    exit(1);
  }
}

void _migrateBaseline(
  AuditScope scope,
  String oldPath,
  String newPath,
  Directory evidence,
) {
  // Same signature as the old tool: path + trimmed text, line number ignored.
  String signature(String entry) {
    final match = RegExp(r'^([^:]+):\d+:(.*)$').firstMatch(entry);
    return match == null ? entry : '${match.group(1)}:${match.group(2)}';
  }

  final oldLines = File(oldPath)
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final oldSignatures = oldLines.map(signature).toSet();

  final scan = scanPlaceholders(scope, '/nonexistent-allowlist');
  final usedSignatures = <String>{};
  final rows = <SiteRow>[];
  final uncoveredBefore = <String>[];
  for (var i = 0; i < scan.highRisk.length; i++) {
    final finding = scan.highRisk[i];
    // highRiskHits is sorted; rebuild the old entry text from the file.
    final raw = File(finding.path).readAsLinesSync()[finding.line - 1];
    final sig = signature('${finding.path}:${finding.line}:${raw.trimRight()}');
    if (oldSignatures.contains(sig)) {
      usedSignatures.add(sig);
      rows.add(
        SiteRow(
          rule: highRiskRule,
          scope: finding.scope,
          text: finding.text,
          verdict: baselineVerdict,
          path: finding.path,
        ),
      );
    } else {
      uncoveredBefore.add(finding.display);
    }
  }
  writeBaseline(newPath, rows);

  final match = matchSites(scan.highRisk, readSites(newPath));
  final dead = oldLines
      .where((line) => !usedSignatures.contains(signature(line)))
      .toList();
  final summary = StringBuffer()
    ..writeln('High-risk baseline migration')
    ..writeln(
      '  old entries: ${oldLines.length} '
      '(${oldSignatures.length} distinct signatures)',
    )
    ..writeln('    in force (cover a hit): ${usedSignatures.length}')
    ..writeln('    dropped, cover nothing: ${dead.length}')
    ..writeln('  high-risk hits: ${scan.highRisk.length}')
    ..writeln(
      '    covered before: '
      '${scan.highRisk.length - uncoveredBefore.length}',
    )
    ..writeln('    covered after: ${match.assigned.length}')
    ..writeln(
      '    new (uncovered) before: ${uncoveredBefore.length}, '
      'after: ${match.unregistered.length}',
    );
  for (final line in dead) {
    summary.writeln('  DROPPED $line');
  }
  for (final line in uncoveredBefore) {
    summary.writeln('  UNCOVERED $line');
  }
  File(
    '${evidence.path}/baseline-summary.txt',
  ).writeAsStringSync(summary.toString());
  stdout.write(summary);
  final sameSet =
      match.unregistered
          .map((f) => f.display)
          .toSet()
          .containsAll(uncoveredBefore) &&
      match.unregistered.length == uncoveredBefore.length;
  if (!sameSet) {
    exit(1);
  }
}
