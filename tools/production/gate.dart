import 'dart:io';

/// The gate: every check CI runs on a change, in one table.
///
/// Each CI job runs one stage (`--stage audits` is the Launch Gate job);
/// `melos run gate` runs every stage. Every selected check runs even after
/// another fails, and the gate exits 1 when any failed. The melos `audit:*`
/// scripts run single checks of this table (`--only <check>`).
///
/// Usage:
///   dart run tools/production/gate.dart                 # every stage
///   dart run tools/production/gate.dart --stage audits  # one stage (repeatable)
///   dart run tools/production/gate.dart --only placeholders
///   dart run tools/production/gate.dart --skip rust --out build/gate
///   dart run tools/production/gate.dart --list
///
/// `--skip` takes a stage or a check name. With `--out <dir>` each check's
/// output goes to `<dir>/<check>.log` and only the summary is printed (also
/// written to `<dir>/SUMMARY.txt`); without it, output is streamed.
///
/// Not here: the desktop build matrix and the license audit (CI only, see
/// .github/workflows/ci.yml), and the release workflows.
class Check {
  final String stage;
  final String name;
  final List<String> command;
  final String? workingDirectory;

  /// Environment variables whose values are paths relative to the repository
  /// root; the check gets them as absolute paths.
  final Map<String, String> pathEnvironment;

  /// A program the check needs that a developer machine may not have. When it
  /// is missing the check is reported as SKIPPED in the summary.
  final String? requires;

  const Check(
    this.stage,
    this.name,
    this.command, {
    this.workingDirectory,
    this.pathEnvironment = const {},
    this.requires,
  });
}

const _registerArgs = [
  '--register',
  'docs/production-readiness/behavioral-audit-register.md',
];

List<String> _tool(String name, [List<String> args = const []]) => [
  'dart',
  'run',
  'tools/production/$name.dart',
  ...args,
];

final List<Check> checks = [
  // Analyze job.
  Check('analyze', 'ui-tokens', [
    'python3',
    'tools/production/ui_tokens/audit_ui_tokens.py',
  ]),
  Check('analyze', 'ui-tokens:self-test', [
    'python3',
    '-m',
    'unittest',
    'discover',
    '-s',
    'tools/production/ui_tokens',
    '-p',
    'test_audit_ui_tokens.py',
  ]),
  Check('analyze', 'nebula-light', [
    'python3',
    'tools/catalog_prep/nebula_light/test_build_nebula_light.py',
  ]),
  Check('analyze', 'release-scripts', [
    'python3',
    '-m',
    'unittest',
    'discover',
    '-s',
    'scripts',
    '-p',
    'test_*.py',
  ]),
  Check('analyze', 'live-rig-driver', [
    'python3',
    '-m',
    'unittest',
    'discover',
    '-s',
    'tools/live_rig',
    '-p',
    'test_*.py',
  ]),
  Check('analyze', 'dependency-hygiene', _tool('dependency_hygiene')),
  Check('analyze', 'version-consistency', _tool('version_consistency_audit')),
  Check(
    'analyze',
    'version-consistency:self-test',
    _tool('version_consistency_audit_self_test'),
  ),
  Check('analyze', 'analyze-production', _tool('analyzer_rollup')),
  // Every workspace folder, tests and tools included (analyze-production
  // judges shipped code only, with its own policy; the hub stage analyzes
  // server/skotiq_hub after resolving it).
  Check('analyze', 'analyze-all', [
    'dart',
    'analyze',
    'packages',
    'apps',
    'tools',
  ]),

  // Launch Gate job: the audit gates and their self-tests.
  Check(
    'audits',
    'placeholders',
    _tool('placeholder_audit', [
      '--fail-on-new-highrisk',
      '--compare-highrisk-baseline',
      'docs/production-readiness/highrisk-baseline.txt',
    ]),
  ),
  Check(
    'audits',
    'behavioral',
    _tool('behavioral_audit', [
      ..._registerArgs,
      '--fail-on-unregistered',
      '--fail-on-open',
    ]),
  ),
  Check('audits', 'fail-closed', _tool('fail_closed_check')),
  Check('audits', 'behavioral:self-test', _tool('behavioral_audit_self_test')),
  Check(
    'audits',
    'placeholders:self-test',
    _tool('placeholder_audit_self_test'),
  ),
  Check(
    'audits',
    'fail-closed:self-test',
    _tool('fail_closed_check_self_test'),
  ),
  Check('audits', 'bridge-boundary', _tool('bridge_boundary_audit')),
  Check(
    'audits',
    'bridge-boundary:self-test',
    _tool('bridge_boundary_audit_self_test'),
  ),
  Check('audits', 'architecture', _tool('architecture_rules_audit')),
  Check(
    'audits',
    'architecture:self-test',
    _tool('architecture_rules_audit_self_test'),
  ),
  Check(
    'audits',
    'headless-api-contract',
    _tool('headless_api_contract_audit'),
  ),
  Check(
    'audits',
    'headless-route-policy',
    _tool('headless_route_policy_audit'),
  ),
  Check(
    'audits',
    'headless-response-helpers',
    _tool('headless_response_helper_audit'),
  ),
  Check(
    'audits',
    'headless-response-helpers:self-test',
    _tool('headless_response_helper_audit_self_test'),
  ),
  Check('audits', 'migration-regression', _tool('migration_regression_audit')),
  Check(
    'audits',
    'migration-regression:self-test',
    _tool('migration_regression_audit_self_test'),
  ),
  Check('audits', 'docs-links', _tool('docs_link_audit')),
  Check('audits', 'docs-links:self-test', _tool('docs_link_audit_self_test')),
  Check('audits', 'release-docs', _tool('release_docs_audit')),
  Check(
    'audits',
    'release-docs:self-test',
    _tool('release_docs_audit_self_test'),
  ),
  Check(
    'audits',
    'analyzer-rollup:self-test',
    _tool('analyzer_rollup_self_test'),
  ),
  Check(
    'audits',
    'dependency-hygiene:self-test',
    _tool('dependency_hygiene_self_test'),
  ),
  Check(
    'audits',
    'ui-consistency:self-test',
    _tool('ui_consistency_audit_self_test'),
  ),
  Check(
    'audits',
    'oversized-files:self-test',
    _tool('oversized_file_audit_self_test'),
  ),
  Check(
    'audits',
    'narrative-comments:self-test',
    _tool('narrative_comment_audit_self_test'),
  ),
  Check(
    'audits',
    'developer-quality:self-test',
    _tool('developer_quality_audit_self_test'),
  ),
  Check(
    'audits',
    'windows-bundle:self-test',
    _tool('windows_bundle_audit_self_test'),
  ),
  Check(
    'audits',
    'headless-windows-smoke:self-test',
    _tool('headless_windows_smoke_self_test'),
  ),
  Check(
    'audits',
    'linux-release-package-metadata:self-test',
    _tool('linux_release_package_metadata_self_test'),
  ),
  Check(
    'audits',
    'linux-release-workflow:self-test',
    _tool('linux_release_workflow_audit_self_test'),
  ),
  Check(
    'audits',
    'settings-search-index:self-test',
    _tool('settings_search_index_gen_self_test'),
  ),
  // Reports: these print counts for review and exit 0 unless given a budget.
  Check('audits', 'design-tokens', _tool('design_tokens_audit')),
  Check('audits', 'ui-consistency', _tool('ui_consistency_audit')),
  Check('audits', 'oversized-files', _tool('oversized_file_audit')),
  Check('audits', 'narrative-comments', _tool('narrative_comment_audit')),

  // Dart Tests job. Golden pixel-diff tests are host-specific and excluded
  // (melos run test:golden runs them on the baseline host).
  Check('dart-tests', 'flutter-tests', [
    'dart',
    'run',
    'melos',
    'exec',
    '--concurrency=1',
    '--flutter',
    '--',
    'flutter',
    'test',
    '--exclude-tags',
    'golden',
    '--file-reporter',
    'json:test-results.json',
  ]),
  Check('dart-tests', 'pure-dart-tests', [
    'dart',
    'run',
    'melos',
    'exec',
    '--concurrency=1',
    '--no-flutter',
    '--dir-exists=test',
    '--',
    'dart',
    'test',
  ]),
  Check(
    'dart-tests',
    'manual-migration',
    [
      'flutter',
      'test',
      'tool/production_migration_probe.dart',
      '--dart-define=REQUIRE_MIGRATION_ARTIFACT=true',
    ],
    workingDirectory: 'packages/skotiq_core',
    pathEnvironment: {
      'SKOTIQ_OLD_DATABASE':
          'packages/skotiq_core/test/fixtures/skotiq-v4.3.0-profile.db',
    },
  ),

  // Constellation Hub job (the hub is not a melos package).
  Check('hub', 'hub-pub-get', [
    'dart',
    'pub',
    'get',
  ], workingDirectory: 'server/skotiq_hub'),
  Check('hub', 'hub-analyze', [
    'dart',
    'analyze',
    '--fatal-infos',
  ], workingDirectory: 'server/skotiq_hub'),
  Check('hub', 'hub-tests', [
    'dart',
    'test',
  ], workingDirectory: 'server/skotiq_hub'),

  // Format Check job.
  Check('format', 'dart-format', [
    'dart',
    'run',
    'melos',
    'exec',
    '--',
    'dart',
    'format',
    '.',
    '--set-exit-if-changed',
    '--output=none',
  ]),
  Check('format', 'rust-format', ['bash', 'scripts/rust_checks.sh', 'fmt']),

  // Rust jobs (Linux and Windows) and Cargo Duplicate Versions. The CI Rust
  // jobs call scripts/rust_checks.sh directly, since they set up no Dart.
  Check('rust', 'rust-clippy', ['bash', 'scripts/rust_checks.sh', 'clippy']),
  Check('rust', 'rust-tests', ['bash', 'scripts/rust_checks.sh', 'test']),
  Check('rust', 'cargo-duplicates', [
    'bash',
    'scripts/rust_checks.sh',
    'duplicates',
  ], requires: 'jq'),
  // Not run in CI (the runners have no codegen installed).
  Check('codegen', 'bridge-codegen', [
    'bash',
    'scripts/check_bridge_codegen.sh',
  ], requires: 'flutter_rust_bridge_codegen'),
  // CI runs this through EmbarkStudios/cargo-deny-action (Rust License Audit).
  Check('rust', 'rust-licenses', [
    'cargo',
    'deny',
    '--manifest-path',
    'native/skotiq_native/Cargo.toml',
    '--all-features',
    'check',
    'licenses',
  ], requires: 'cargo-deny'),
];

List<String> get stages => {for (final check in checks) check.stage}.toList();

const _valueFlags = {'--stage', '--only', '--skip', '--out'};

Future<void> main(List<String> args) async {
  for (var i = 0; i < args.length; i++) {
    if (_valueFlags.contains(args[i]) && i + 1 < args.length) {
      i++;
    } else if (args[i] != '--list') {
      stderr.writeln('gate: unknown argument "${args[i]}"');
      exit(2);
    }
  }
  final selectedStages = _values(args, '--stage');
  final only = _values(args, '--only');
  final skip = _values(args, '--skip');
  final out = _values(args, '--out').lastOrNull;

  for (final name in [...selectedStages, ...skip]) {
    if (!stages.contains(name) && !checks.any((c) => c.name == name)) {
      stderr.writeln('gate: no stage or check named "$name"');
      exit(2);
    }
  }
  for (final name in only) {
    if (!checks.any((c) => c.name == name)) {
      stderr.writeln('gate: no check named "$name"');
      exit(2);
    }
  }

  final selected = [
    for (final check in checks)
      if ((only.isEmpty || only.contains(check.name)) &&
          (selectedStages.isEmpty || selectedStages.contains(check.stage)) &&
          !skip.contains(check.stage) &&
          !skip.contains(check.name))
        check,
  ];

  if (args.contains('--list')) {
    for (final check in checks) {
      stdout.writeln(
        '${check.stage.padRight(11)} ${check.name.padRight(42)} '
        '${check.command.join(' ')}',
      );
    }
    return;
  }
  if (selected.isEmpty) {
    stderr.writeln('gate: nothing selected');
    exit(2);
  }

  final root = Directory.current.path;
  final outDir = out == null ? null : Directory(out);
  outDir?.createSync(recursive: true);
  final onCi = Platform.environment['GITHUB_ACTIONS'] == 'true';
  final results = <String>[];
  var failed = 0;

  for (final check in selected) {
    final requires = check.requires;
    if (requires != null && !await _onPath(requires)) {
      results.add('SKIPPED ${check.name} ($requires is not installed)');
      continue;
    }
    final watch = Stopwatch()..start();
    final environment = {
      for (final entry in check.pathEnvironment.entries)
        entry.key: '$root/${entry.value}',
    };
    final logFile = outDir == null
        ? null
        : File('${outDir.path}/${check.name.replaceAll(':', '_')}.log');
    if (onCi) stdout.writeln('::group::${check.name}');
    if (logFile == null) {
      stdout.writeln('== ${check.name}: ${check.command.join(' ')}');
    }
    final int code;
    try {
      final process = await Process.start(
        check.command.first,
        check.command.skip(1).toList(),
        workingDirectory: check.workingDirectory == null
            ? root
            : '$root/${check.workingDirectory}',
        environment: environment,
        runInShell: Platform.isWindows,
        mode: logFile == null
            ? ProcessStartMode.inheritStdio
            : ProcessStartMode.normal,
      );
      if (logFile != null) {
        final sink = logFile.openWrite();
        await Future.wait([
          process.stdout.forEach(sink.add),
          process.stderr.forEach(sink.add),
        ]);
        await sink.close();
      }
      code = await process.exitCode;
    } on ProcessException catch (error) {
      if (onCi) stdout.writeln('::endgroup::');
      results.add('FAIL    ${check.name} (could not start: ${error.message})');
      failed++;
      continue;
    }
    if (onCi) stdout.writeln('::endgroup::');
    final seconds = (watch.elapsedMilliseconds / 1000).toStringAsFixed(0);
    if (code == 0) {
      results.add('PASS    ${check.name} (${seconds}s)');
    } else {
      failed++;
      final where = logFile == null ? '' : ', log ${logFile.path}';
      results.add('FAIL    ${check.name} (exit $code, ${seconds}s$where)');
      if (onCi) {
        stdout.writeln(
          '::error::gate check ${check.name} failed (exit $code): '
          '${check.command.join(' ')}',
        );
      }
    }
  }

  final skipped = results.where((r) => r.startsWith('SKIPPED')).length;
  final summary = [
    ...results,
    '${selected.length - failed - skipped} passed, $failed failed, '
        '$skipped skipped.',
  ].join('\n');
  stdout.writeln('\n$summary');
  if (outDir != null) {
    File('${outDir.path}/SUMMARY.txt').writeAsStringSync('$summary\n');
  }
  if (failed > 0) exit(1);
}

List<String> _values(List<String> args, String flag) => [
  for (var i = 0; i < args.length - 1; i++)
    if (args[i] == flag) args[i + 1],
];

Future<bool> _onPath(String program) async {
  final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
    program,
  ], runInShell: Platform.isWindows);
  return result.exitCode == 0;
}
