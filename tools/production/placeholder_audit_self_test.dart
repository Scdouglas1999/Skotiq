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

    // Moving the file keeps the baseline entry attached with no edit.
    await _moveFile(
      temp,
      'apps/desktop/lib/bad.dart',
      'packages/release_fixture/lib/src/moved/worse.dart',
    );
    final movedPass = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: _compareArgs,
    );
    _expect(movedPass.exitCode == 0, 'a moved file should stay covered');

    // The same text in a different function is a new, unreviewed marker.
    await _writeFile(temp, 'apps/desktop/lib/other.dart', '''

void anotherStub() {
  throw UnimplementedError('release blocker');
}
''');
    final newSite = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: _compareArgs,
      allowFailure: true,
    );
    _expect(
      newSite.exitCode == 1 &&
          newSite.stderr.toString().contains('apps/desktop/lib/other.dart:3'),
      'a new marker should fail and be named (stderr=${newSite.stderr})',
    );

    // Deleting the code leaves a prunable entry that one command drops.
    await Directory('${temp.path}/apps').delete(recursive: true);
    await Directory('${temp.path}/packages').delete(recursive: true);
    final deletedPass = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: _compareArgs,
    );
    _expect(
      deletedPass.exitCode == 0 &&
          deletedPass.stdout.toString().contains('Prunable: 1'),
      'deleted code should leave the gate green and report a prunable entry',
    );
    await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: [..._compareArgs, '--sync-baseline'],
    );
    _expect(
      !File(
        '${temp.path}/baseline/highrisk.txt',
      ).readAsStringSync().contains('UnimplementedError'),
      '--sync-baseline should drop the entry for deleted code',
    );

    // --accept-new-highrisk records a reviewed marker in the baseline.
    await _writeBaselineFixture(temp);
    await File('${temp.path}/baseline/highrisk.txt').writeAsString('');
    await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: [..._compareArgs, '--accept-new-highrisk'],
    );
    final acceptedPass = await _runAudit(
      script,
      temp,
      outHits: '.audit_hits.txt',
      outHighRisk: '.audit_highrisk.txt',
      extraArgs: _compareArgs,
    );
    _expect(acceptedPass.exitCode == 0, 'an accepted marker should pass');

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
    'path\tscope\trule\tcount\tverdict\ttext\n'
        'apps/desktop/lib/bad.dart\tunsafeRuntimeStub\thighrisk\t1\tbaseline\t'
        "throw UnimplementedError('release blocker');\n",
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
      // The fixtures are judged against the repository's real scan scope.
      '--scope',
      '${Directory.current.path}/docs/production-readiness/audit-scope.yaml',
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

const _compareArgs = [
  '--compare-highrisk-baseline',
  'baseline/highrisk.txt',
  '--fail-on-new-highrisk',
];

Future<void> _moveFile(Directory root, String from, String to) async {
  final source = File('${root.path}/$from');
  await _writeFile(root, to, source.readAsStringSync());
  await source.delete();
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
