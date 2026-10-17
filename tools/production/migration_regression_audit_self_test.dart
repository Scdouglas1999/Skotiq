import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/migration_regression_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Migration regression audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_migration_regression_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    // Presence-only cases skip the behavioral run; the behavioral path is
    // exercised separately below against a real runnable test.
    await _runAudit(script, temp, skipTestRun: true);
    final passing = _readJson(
      temp,
      'docs/production-readiness/migration-regression-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['issueCount'] == 0,
      'passing fixture should have no issues',
    );
    _expect(
      passing['manualRealArtifactGatePreserved'] == true,
      'passing fixture should preserve manual real-artifact gate',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(
      script,
      temp,
      allowFailure: true,
      skipTestRun: true,
    );
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/migration-regression-audit.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    final issues = (failing['issues'] as List? ?? const []).join('\n');
    _expect(
      issues.contains('synthetic_old_profile_fixtures.dart is missing'),
      'failing report should include fixture coverage issue',
    );
    _expect(
      issues.contains('database_migration_test.dart is missing'),
      'failing report should include migration test coverage issue',
    );
    _expect(
      issues.contains('production_migration_probe.dart is missing'),
      'failing report should include manual probe separation issue',
    );

    await _runBehavioralCases(script);

    stdout.writeln('Migration regression audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

/// Verifies the behavioral guarantee: the audit runs the referenced migration
/// test and goes red when that test fails. A self-contained runnable test
/// stands in for `database_migration_test.dart` so the check is fast and does
/// not require the full app toolchain, while exercising the same code path
/// (process exit code -> audit issue) that the real suite drives in CI.
Future<void> _runBehavioralCases(File script) async {
  final temp = await Directory.systemTemp.createTemp(
    'skotiq_migration_regression_audit_behavioral_',
  );
  try {
    await _writePassingFixture(temp);
    await _writeFile(temp, 'pubspec.yaml', '''
name: skotiq_migration_audit_behavioral_fixture
environment:
  sdk: '>=3.0.0 <4.0.0'
dev_dependencies:
  test: any
''');
    final getResult = await Process.run('dart', [
      'pub',
      'get',
    ], workingDirectory: temp.path);
    _expect(
      getResult.exitCode == 0,
      'behavioral fixture pub get should succeed:\n${getResult.stderr}',
    );

    Future<Map<String, dynamic>> runWithMigrationTest(String body) async {
      // The audit reads this same file for both the substring-presence check
      // and the behavioral run, so the runnable test must also carry the
      // required named cases to keep the presence check green and isolate the
      // behavioral signal under test.
      await _writeFile(
        temp,
        'packages/skotiq_core/test/services/database_migration_test.dart',
        '$body\n${_requiredTestPresenceLiterals()}',
      );
      await _runAudit(
        script,
        temp,
        allowFailure: true,
        extraArgs: const [
          '--test-command',
          'dart test --reporter json',
          '--test-workdir',
          '.',
        ],
      );
      return _readJson(
        temp,
        'docs/production-readiness/migration-regression-audit.json',
      );
    }

    // Intact assertion: the audit's behavioral run is green.
    final greenReport = await runWithMigrationTest('''
import 'package:test/test.dart';

void main() {
  test('migration preserves the upgraded value', () {
    expect(2 + 2, equals(4));
  });
}
''');
    final greenBehavioral =
        greenReport['behavioral'] as Map<String, dynamic>? ?? const {};
    _expect(
      greenBehavioral['ran'] == true,
      'behavioral run should execute when not skipped',
    );
    _expect(
      greenBehavioral['passed'] == true,
      'intact migration test should keep the behavioral run green',
    );
    _expect(
      (greenBehavioral['passedCount'] as num? ?? 0) >= 1,
      'intact migration test should report at least one passing test',
    );

    // Gut the assertion: the same test now fails, so the audit must fail too.
    final redReport = await runWithMigrationTest('''
import 'package:test/test.dart';

void main() {
  test('migration preserves the upgraded value', () {
    // Assertion gutted: the migration invariant is no longer checked.
    expect(2 + 2, equals(5));
  });
}
''');
    _expect(
      redReport['passed'] == false,
      'gutting the migration test assertion must fail the audit',
    );
    final redBehavioral =
        redReport['behavioral'] as Map<String, dynamic>? ?? const {};
    _expect(
      redBehavioral['passed'] == false,
      'gutted migration test should fail the behavioral run',
    );
    _expect(
      (redBehavioral['exitCode'] as num? ?? 0) != 0,
      'gutted migration test should yield a non-zero test exit code',
    );
    final redIssues = (redReport['issues'] as List? ?? const []).join('\n');
    _expect(
      redIssues.contains('Behavioral migration tests failed'),
      'gutted migration test should surface a behavioral failure issue',
    );
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _writeFile(
    root,
    'packages/skotiq_core/test/fixtures/synthetic_old_profile_fixtures.dart',
    '''
class SyntheticOldProfileFixture {
  Future<void> schema17WithCapturedImageMetadata() async {
    'PRAGMA user_version = 17';
    'legacy FITS metadata';
  }

  Future<void> schema20WithDuplicateActiveProfiles() async {
    'DROP INDEX IF EXISTS idx_profiles_single_active';
    'PRAGMA user_version = 20';
    'Legacy Widefield';
    'Legacy Observatory';
    'is_active';
    'telescope_focal_length';
    'telescope_aperture';
  }

  Future<void> schema20WithDuplicateScienceSessionConfigs() async {
    'DROP INDEX IF EXISTS idx_science_session_config_session_unique';
    'PRAGMA user_version = 20';
    'science_session_config';
  }

  Future<void> schema20WithDuplicateWeatherSettings() async {
    'PRAGMA user_version = 20';
    'weather_settings';
    'legacy_primary';
    'legacy_duplicate';
  }
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/test/services/database_migration_test.dart',
    '''
void main() {
  'synthetic schema 17 image fixture preserves metadata cascade';
  'SyntheticOldProfileFixture.schema17WithCapturedImageMetadata';
  'Migration v18 should restore image metadata cascade delete';
  'Upgraded legacy image metadata should cascade on image delete';
  'synthetic schema 20 profile fixture normalizes active and optics';
  'SyntheticOldProfileFixture.schema20WithDuplicateActiveProfiles';
  'equals(db.schemaVersion)';
  'Migration v21 should keep only the newest active profile';
  'idx_profiles_single_active';
  'Upgraded legacy databases should reject another active';
  'telescopeFocalLength';
  'telescopeAperture';
  'focalLength';
  'aperture';
  'synthetic schema 20 science fixture deduplicates session configs';
  '.schema20WithDuplicateScienceSessionConfigs';
  'Migration v21 should dedupe science session configs';
  'idx_science_session_config_session_unique';
  'Upgraded legacy databases should reject another config';
  'synthetic schema 20 weather fixture deduplicates singleton settings';
  '.schema20WithDuplicateWeatherSettings';
  'primary singleton row on first settings access';
  'weatherSettingsDao.getOrCreateSettings';
  'legacy_primary';
  'schema 12 database upgrades to the complete current table set';
  'fresh and upgraded databases converge on the same default settings';
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/tool/production_migration_probe.dart',
    '''
void main() {
  'SKOTIQ_OLD_DATABASE';
  'sourceSizeBytes';
  'sourceSha256';
  'copiedSourceSha256';
  'copiedSourceSha256Matches';
  'expectedTableCount';
  'migratedTableCount';
  'defaultSettingCount';
  'Manual older-profile migration evidence probe. Synthetic migration tests remain separate.';
}
''',
  );
}

Future<void> _writeFailingFixture(Directory root) async {
  await _writeFile(
    root,
    'packages/skotiq_core/test/fixtures/synthetic_old_profile_fixtures.dart',
    'class SyntheticOldProfileFixture {}',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/test/services/database_migration_test.dart',
    'void main() {}',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/tool/production_migration_probe.dart',
    'void main() {}',
  );
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
  bool skipTestRun = false,
  List<String> extraArgs = const [],
}) async {
  final result = await Process.run(
    'dart',
    [
      script.path,
      '--root',
      root.path,
      if (skipTestRun) '--skip-test-run',
      ...extraArgs,
    ],
    workingDirectory: root.path,
    runInShell: Platform.isWindows,
  );
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      '${script.path} failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return result;
}

/// The named cases the audit's substring check requires of the migration test
/// file, emitted as a comment so a runnable behavioral test still satisfies the
/// presence check without those strings affecting test execution.
String _requiredTestPresenceLiterals() {
  const required = [
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
  return required.map((line) => '// $line').join('\n');
}

Future<void> _writeFile(
  Directory root,
  String relativePath,
  String content,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Map<String, dynamic> _readJson(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('Expected report was not written: ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
