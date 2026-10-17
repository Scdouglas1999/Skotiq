import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/placeholder_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Placeholder audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_placeholder_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(
      script,
      temp,
      outHits: 'reports/audit_hits.txt',
      outHighRisk: 'reports/audit_highrisk.txt',
    );
    final passingHits = _readLines(temp, 'reports/audit_hits.txt');
    final passingHighRisk = _readLines(temp, 'reports/audit_highrisk.txt');
    _expect(
      passingHits.length == 1 &&
          passingHits.single.contains(
            'packages/release_fixture/lib/src/info.dart',
          ),
      'passing fixture should report the non-high-risk runtime marker',
    );
    _expect(
      passingHighRisk.isEmpty,
      'allowlisted high-risk marker should not appear in high-risk output',
    );

    await _writeFailingFixture(temp);
    final failing = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: const ['--fail-on-any-highrisk'],
      allowFailure: true,
    );
    _expect(failing.exitCode == 1, 'high-risk fixture should fail');
    final failingHighRisk = _readLines(temp, '.audit_highrisk.txt');
    _expect(
      failingHighRisk.length == 1 &&
          failingHighRisk.single.contains('UnimplementedError'),
      'high-risk fixture should report the unsafe marker',
    );

    await _writeBaselineFixture(temp);
    final baselinePass = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: const [
        '--compare-highrisk-baseline',
        'baseline/highrisk.txt',
        '--fail-on-new-highrisk',
      ],
    );
    _expect(baselinePass.exitCode == 0, 'matching baseline should pass');

    await _writeFile(temp, 'apps/desktop/lib/bad.dart', '''

void unsafeRuntimeStub() {
  throw UnimplementedError('release blocker');
}
''');
    final shiftedBaselinePass = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: const [
        '--compare-highrisk-baseline',
        'baseline/highrisk.txt',
        '--fail-on-new-highrisk',
      ],
    );
    _expect(
      shiftedBaselinePass.exitCode == 0,
      'baseline comparison should ignore harmless line-number drift',
    );

    await File('${temp.path}/baseline/highrisk.txt').writeAsString('');
    final baselineFail = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: const [
        '--compare-highrisk-baseline',
        'baseline/highrisk.txt',
        '--fail-on-new-highrisk',
      ],
      allowFailure: true,
    );
    _expect(
      baselineFail.exitCode == 1,
      'new high-risk marker compared to baseline should fail',
    );

    // Path-only allowlist entries must be rejected with exit 2.
    await _writePathOnlyAllowlistFixture(temp);
    final pathOnlyResult = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      allowFailure: true,
    );
    _expect(
      pathOnlyResult.exitCode == 2,
      'path-only allowlist entries should be rejected with exit 2 '
      '(actual ${pathOnlyResult.exitCode}, stderr=${pathOnlyResult.stderr})',
    );

    stdout.writeln('Placeholder audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeFile(root, 'packages/release_fixture/lib/src/info.dart', '''
void infoOnly() {
  // TODO: improve this label later.
}
''');
  await _writeFile(root, 'packages/release_fixture/lib/src/allowed.dart', '''
void allowed() {
  throw UnimplementedError('allowlisted release fixture');
}
''');
  // Path-only allowlist entries are rejected; require path:line or
  // path:line:exact_text granularity.
  await _writeFile(
    root,
    'docs/production-readiness/placeholder-allowlist.txt',
    'packages/release_fixture/lib/src/allowed.dart:2\n',
  );
  await _writeFile(root, 'packages/release_fixture/test/bad_test.dart', '''
void ignoredTestPath() {
  throw UnimplementedError('tests are not runtime paths');
}
''');
}

Future<void> _writeFailingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeFile(root, 'apps/desktop/lib/bad.dart', '''
void unsafeRuntimeStub() {
  throw UnimplementedError('release blocker');
}
''');
}

Future<void> _writeBaselineFixture(Directory root) async {
  await _writeFailingFixture(root);
  await _writeFile(
    root,
    'baseline/highrisk.txt',
    'apps/desktop/lib/bad.dart:2:  throw UnimplementedError(\'release blocker\');\n',
  );
}

Future<void> _writePathOnlyAllowlistFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeFile(root, 'apps/desktop/lib/bad.dart', '''
void unsafeRuntimeStub() {
  throw UnimplementedError('release blocker');
}
''');
  await _writeFile(
    root,
    'docs/production-readiness/placeholder-allowlist.txt',
    'apps/desktop/lib/bad.dart\n',
  );
}

Future<void> _resetWorkspace(Directory root) async {
  for (final path in [
    'apps',
    'packages',
    'native',
    'docs',
    'reports',
    'baseline',
  ]) {
    final dir = Directory('${root.path}/$path');
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
  for (final path in ['.audit_hits.txt', '.audit_highrisk.txt']) {
    final file = File('${root.path}/$path');
    if (file.existsSync()) {
      await file.delete();
    }
  }
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  required String outHits,
  required String outHighRisk,
  List<String> extraArgs = const [],
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [
      script.path,
      '--out-hits',
      outHits,
      '--out-highrisk',
      outHighRisk,
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

Future<void> _writeFile(
  Directory root,
  String relativePath,
  String content,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

List<String> _readLines(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('Expected audit output was not written: ${file.path}');
  }
  return file
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
