import 'dart:convert';
import 'dart:io';

const _defaultJsonOutputPath =
    'docs/production-readiness/migration-regression-audit.json';
const _defaultMarkdownOutputPath =
    'docs/production-readiness/migration-regression-audit.md';

const _fixturePath =
    'packages/skotiq_core/test/fixtures/synthetic_old_profile_fixtures.dart';
const _testPath =
    'packages/skotiq_core/test/services/database_migration_test.dart';
const _manualProbePath =
    'packages/skotiq_core/tool/production_migration_probe.dart';

const _requiredFixtureText = [
  'schema17WithCapturedImageMetadata',
  'schema20WithDuplicateActiveProfiles',
  'schema20WithDuplicateScienceSessionConfigs',
  'schema20WithDuplicateWeatherSettings',
  'PRAGMA user_version = 17',
  'DROP INDEX IF EXISTS idx_profiles_single_active',
  'DROP INDEX IF EXISTS idx_science_session_config_session_unique',
  'PRAGMA user_version = 20',
  'legacy FITS metadata',
  'Legacy Widefield',
  'Legacy Observatory',
  'is_active',
  'telescope_focal_length',
  'telescope_aperture',
  'science_session_config',
  'weather_settings',
  'legacy_primary',
  'legacy_duplicate',
];

const _requiredTestText = [
  'synthetic schema 17 image fixture preserves metadata cascade',
  'SyntheticOldProfileFixture.schema17WithCapturedImageMetadata',
  'Migration v18 should restore image metadata cascade delete',
  'Upgraded legacy image metadata should cascade on image delete',
  'synthetic schema 20 profile fixture normalizes active and optics',
  'SyntheticOldProfileFixture.schema20WithDuplicateActiveProfiles',
  'equals(db.schemaVersion)',
  'Migration v21 should keep only the newest active profile',
  'idx_profiles_single_active',
  'Upgraded legacy databases should reject another active',
  'telescopeFocalLength',
  'telescopeAperture',
  'focalLength',
  'aperture',
  'synthetic schema 20 science fixture deduplicates session configs',
  '.schema20WithDuplicateScienceSessionConfigs',
  'Migration v21 should dedupe science session configs',
  'idx_science_session_config_session_unique',
  'Upgraded legacy databases should reject another config',
  'synthetic schema 20 weather fixture deduplicates singleton settings',
  '.schema20WithDuplicateWeatherSettings',
  'primary singleton row on first settings access',
  'weatherSettingsDao.getOrCreateSettings',
  'legacy_primary',
  'schema 12 database upgrades to the complete current table set',
  'fresh and upgraded databases converge on the same default settings',
];

const _requiredManualProbeText = [
  'SKOTIQ_OLD_DATABASE',
  'sourceSizeBytes',
  'sourceSha256',
  'copiedSourceSha256',
  'copiedSourceSha256Matches',
  'expectedTableCount',
  'migratedTableCount',
  'defaultSettingCount',
  'Manual older-profile migration evidence probe. Synthetic migration tests remain separate.',
];

const _defaultTestCommand = 'flutter test --reporter json';
const _defaultTestWorkdir = 'packages/skotiq_core';

Future<void> main(List<String> args) async {
  final root = Directory(_argValue(args, '--root') ?? Directory.current.path);
  final jsonOut = _argValue(args, '--json-out') ?? _defaultJsonOutputPath;
  final markdownOut = _argValue(args, '--md-out') ?? _defaultMarkdownOutputPath;
  final failOnIssue = !args.contains('--no-fail-on-issue');
  final testCommand = _argValue(args, '--test-command') ?? _defaultTestCommand;
  final testWorkdir = _argValue(args, '--test-workdir') ?? _defaultTestWorkdir;
  final skipTestRun = args.contains('--skip-test-run');

  final fixture = _auditFile(
    root: root,
    path: _fixturePath,
    requiredText: _requiredFixtureText,
  );
  final tests = _auditFile(
    root: root,
    path: _testPath,
    requiredText: _requiredTestText,
  );
  final manualProbe = _auditFile(
    root: root,
    path: _manualProbePath,
    requiredText: _requiredManualProbeText,
  );

  final behavioral = skipTestRun
      ? _BehavioralRun.skipped()
      : await _runMigrationTests(
          root: root,
          command: testCommand,
          workdir: testWorkdir,
          testPath: _testPath,
        );

  final issues = [
    ...fixture.issues,
    ...tests.issues,
    ...manualProbe.issues,
    ...behavioral.issues,
  ];
  final passed = issues.isEmpty;
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'issueCount': issues.length,
    'issues': issues,
    'fixture': fixture.toJson(),
    'tests': tests.toJson(),
    'manualProbe': manualProbe.toJson(),
    'behavioral': behavioral.toJson(),
    'manualRealArtifactGatePreserved': manualProbe.passed,
    'focusedTestCommand':
        'cd packages/skotiq_core && flutter test test/services/database_migration_test.dart',
    'policy':
        'Synthetic migration fixtures reduce upgrade risk, while the checked-in v4.3.0 release-authentic database exercises the real tagged schema. The manual probe must migrate that artifact (or an older user profile) successfully.',
  };

  await File(jsonOut).parent.create(recursive: true);
  await File(
    jsonOut,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(markdownOut).parent.create(recursive: true);
  await File(markdownOut).writeAsString(
    _renderMarkdown(
      passed: passed,
      issues: issues,
      fixture: fixture,
      tests: tests,
      manualProbe: manualProbe,
      behavioral: behavioral,
    ),
  );

  stdout.writeln('Migration regression audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Issues: ${issues.length}');
  stdout.writeln('Behavioral migration tests: ${behavioral.summaryLine}');
  stdout.writeln('JSON: $jsonOut');
  stdout.writeln('Markdown: $markdownOut');

  if (failOnIssue && !passed) {
    exit(1);
  }
}

/// Runs the behavioral migration test suite and reports its outcome.
///
/// A green substring audit is meaningless if the migration tests themselves
/// fail, so the suite's process exit code is authoritative: any non-zero exit
/// (or a failed test in the JSON reporter stream) becomes an audit issue and
/// turns the whole audit red.
Future<_BehavioralRun> _runMigrationTests({
  required Directory root,
  required String command,
  required String workdir,
  required String testPath,
}) async {
  final parts = command.split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) {
    return _BehavioralRun.unrun('Empty --test-command.');
  }
  final executable = parts.first;
  final commandArgs = parts.skip(1).toList();
  final testFile = File('${root.path}/$testPath');
  if (!testFile.existsSync()) {
    return _BehavioralRun.unrun(
      'Migration test file is missing, cannot run behavioral suite: $testPath',
    );
  }
  final workingDir = Directory('${root.path}/$workdir');

  ProcessResult result;
  try {
    result = await Process.run(
      executable,
      [...commandArgs, testFile.absolute.path],
      workingDirectory: workingDir.existsSync() ? workingDir.path : root.path,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (e) {
    return _BehavioralRun.unrun(
      'Failed to launch migration test command `$command`: ${e.message}',
    );
  }

  final counts = _parseTestReporter(result.stdout.toString());
  return _BehavioralRun(
    command: '$command $testPath',
    exitCode: result.exitCode,
    passedCount: counts.passed,
    failedCount: counts.failed,
    stderrTail: _tail(result.stderr.toString()),
  );
}

class _TestCounts {
  final int passed;
  final int failed;
  const _TestCounts(this.passed, this.failed);
}

/// Parses the `--reporter json` stream of `dart`/`flutter test`.
///
/// Each non-hidden `testDone` event carries a `result` of success/failure/
/// error. Hidden events (loading suites, etc.) are ignored.
_TestCounts _parseTestReporter(String stdout) {
  var passed = 0;
  var failed = 0;
  for (final line in const LineSplitter().convert(stdout)) {
    if (line.isEmpty || !line.startsWith('{')) {
      continue;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) {
      continue;
    }
    if (decoded['type'] != 'testDone' || decoded['hidden'] == true) {
      continue;
    }
    if (decoded['result'] == 'success') {
      passed++;
    } else {
      failed++;
    }
  }
  return _TestCounts(passed, failed);
}

String _tail(String value, {int maxLines = 20}) {
  final lines = const LineSplitter()
      .convert(value)
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.length <= maxLines) {
    return lines.join('\n');
  }
  return lines.sublist(lines.length - maxLines).join('\n');
}

class _BehavioralRun {
  /// Whether the suite was actually executed (false when skipped or unrunnable).
  final bool ran;
  final String? command;
  final int? exitCode;
  final int passedCount;
  final int failedCount;
  final String? stderrTail;

  /// Issues surfaced when the suite could not run or did not pass cleanly.
  final List<String> issues;

  const _BehavioralRun._({
    required this.ran,
    required this.command,
    required this.exitCode,
    required this.passedCount,
    required this.failedCount,
    required this.stderrTail,
    required this.issues,
  });

  factory _BehavioralRun({
    required String command,
    required int exitCode,
    required int passedCount,
    required int failedCount,
    String? stderrTail,
  }) {
    final issues = <String>[];
    if (exitCode != 0) {
      issues.add(
        'Behavioral migration tests failed (exit $exitCode, '
        'passed=$passedCount failed=$failedCount): `$command`'
        '${stderrTail != null && stderrTail.isNotEmpty ? '\n$stderrTail' : ''}',
      );
    } else if (passedCount == 0) {
      issues.add(
        'Behavioral migration tests reported no passing tests (exit 0): '
        '`$command`',
      );
    }
    return _BehavioralRun._(
      ran: true,
      command: command,
      exitCode: exitCode,
      passedCount: passedCount,
      failedCount: failedCount,
      stderrTail: stderrTail,
      issues: issues,
    );
  }

  /// The behavioral run was explicitly skipped (e.g. presence-only self-test).
  factory _BehavioralRun.skipped() => const _BehavioralRun._(
    ran: false,
    command: null,
    exitCode: null,
    passedCount: 0,
    failedCount: 0,
    stderrTail: null,
    issues: [],
  );

  /// The suite could not be launched; treated as an audit issue, never green.
  factory _BehavioralRun.unrun(String reason) => _BehavioralRun._(
    ran: false,
    command: null,
    exitCode: null,
    passedCount: 0,
    failedCount: 0,
    stderrTail: null,
    issues: [reason],
  );

  bool get passed => ran && issues.isEmpty;

  String get summaryLine {
    if (!ran) {
      return issues.isEmpty ? 'skipped' : 'not run (${issues.length} issue(s))';
    }
    return 'exit=$exitCode passed=$passedCount failed=$failedCount';
  }

  Map<String, Object?> toJson() => {
    'ran': ran,
    'command': command,
    'exitCode': exitCode,
    'passedCount': passedCount,
    'failedCount': failedCount,
    'passed': passed,
    'issues': issues,
  };
}

_FileAudit _auditFile({
  required Directory root,
  required String path,
  required List<String> requiredText,
}) {
  final file = File('${root.path}/$path');
  if (!file.existsSync()) {
    return _FileAudit(
      path: path,
      exists: false,
      sizeBytes: 0,
      missingText: requiredText,
    );
  }
  final text = file.readAsStringSync();
  return _FileAudit(
    path: path,
    exists: true,
    sizeBytes: file.lengthSync(),
    missingText: [
      for (final required in requiredText)
        if (!text.contains(required)) required,
    ],
  );
}

String _renderMarkdown({
  required bool passed,
  required List<String> issues,
  required _FileAudit fixture,
  required _FileAudit tests,
  required _FileAudit manualProbe,
  required _BehavioralRun behavioral,
}) {
  final buffer = StringBuffer()
    ..writeln('# Migration Regression Audit')
    ..writeln()
    ..writeln('- Passed: `$passed`')
    ..writeln('- Issues: `${issues.length}`')
    ..writeln('- Behavioral migration tests: `${behavioral.summaryLine}`')
    ..writeln()
    ..writeln(
      'This audit runs the synthetic old-schema/profile migration test suite and fails on a non-zero test exit, in addition to verifying that the fixtures and named cases are present. The separate manual probe migrates a release-authentic v4.3.0 database artifact.',
    )
    ..writeln()
    ..writeln('## Required Files')
    ..writeln()
    ..writeln('| File | Exists | Missing required text |')
    ..writeln('| --- | --- | ---: |')
    ..writeln(
      '| `${fixture.path}` | `${fixture.exists}` | `${fixture.missingText.length}` |',
    )
    ..writeln(
      '| `${tests.path}` | `${tests.exists}` | `${tests.missingText.length}` |',
    )
    ..writeln(
      '| `${manualProbe.path}` | `${manualProbe.exists}` | `${manualProbe.missingText.length}` |',
    )
    ..writeln()
    ..writeln('## Focused Verification')
    ..writeln()
    ..writeln(
      '`cd packages/skotiq_core && flutter test test/services/database_migration_test.dart`',
    );

  if (issues.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Issues')
      ..writeln();
    for (final issue in issues) {
      buffer.writeln('- $issue');
    }
  }

  return buffer.toString();
}

String? _argValue(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == name && i + 1 < args.length) {
      return args[i + 1];
    }
    if (arg.startsWith('$name=')) {
      return arg.substring(name.length + 1);
    }
  }
  return null;
}

class _FileAudit {
  final String path;
  final bool exists;
  final int sizeBytes;
  final List<String> missingText;

  const _FileAudit({
    required this.path,
    required this.exists,
    required this.sizeBytes,
    required this.missingText,
  });

  bool get passed => exists && missingText.isEmpty;

  List<String> get issues {
    if (!exists) {
      return ['Missing required file: $path'];
    }
    return [
      for (final text in missingText) '$path is missing required text: `$text`',
    ];
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'exists': exists,
    'sizeBytes': sizeBytes,
    'missingText': missingText,
    'missingTextCount': missingText.length,
    'passed': passed,
  };
}
