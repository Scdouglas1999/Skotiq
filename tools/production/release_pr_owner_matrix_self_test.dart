import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final matrixGenerator = File(
    '${repoRoot.path}/tools/production/release_pr_owner_matrix.dart',
  );
  final validator = File(
    '${repoRoot.path}/tools/production/release_pr_staged_branch_validator.dart',
  );
  if (!matrixGenerator.existsSync()) {
    throw StateError(
      'Owner matrix generator not found: ${matrixGenerator.path}',
    );
  }
  if (!validator.existsSync()) {
    throw StateError('Staged branch validator not found: ${validator.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_release_pr_owner_matrix_self_test_',
  );
  try {
    await _prepareGitWorkspace(temp);
    await _writeFixturePlan(temp);
    await _runDartScript(matrixGenerator, temp);

    final matrix = _readJson(
      temp,
      'docs/production-readiness/release-pr-owner-decision-matrix.json',
    );
    _expect(matrix['entryCount'] == 7, 'matrix should preserve entry count');
    _expectGroup(matrix, 'must_ship', 2);
    _expectGroup(matrix, 'generated_only', 2);
    _expectGroup(matrix, 'binary_evidence', 1);
    _expectGroup(matrix, 'defer_exclude', 2);
    _expectRelatedReleaseList(
      matrix,
      'must_ship',
      'docs/production-readiness/release-pr-lists/01-must-ship.txt',
      2,
    );
    _expectRelatedReleaseList(
      matrix,
      'generated_only',
      'docs/production-readiness/release-pr-lists/02-generated-only.txt',
      2,
    );
    _expectRelatedReleaseList(
      matrix,
      'binary_evidence',
      'docs/production-readiness/release-pr-lists/03-binary-evidence.txt',
      1,
    );
    _expectRelatedReleaseList(
      matrix,
      'defer_exclude',
      'docs/production-readiness/release-pr-lists/04-defer-exclude.txt',
      2,
    );
    _expectDraftCommand(
      matrix,
      'out-of-release-scope-review',
      'git restore --staged --pathspec-from-file=docs/production-readiness/release-pr-pathspecs/05.txt',
    );

    await _stageFixturePaths(temp, [
      'tools/production/release_gate.dart',
      'apps/desktop/lib/headless_api_server.dart',
      'packages/skotiq_core/lib/src/database/database.g.dart',
      'packages/skotiq_bridge/lib/src/frb_generated.dart',
      'docs/production-readiness/smoke.png',
    ]);
    final valid = await _runDartScript(validator, temp);
    _expect(valid.exitCode == 0, 'complete staged plan should pass');
    var validation = _readJson(
      temp,
      'docs/production-readiness/release-pr-staged-branch-validation.json',
    );
    _expectCoverage(validation, 'must_ship', 'complete', observed: 2);
    _expectCoverage(validation, 'generated_only', 'complete', observed: 2);
    _expectCoverage(validation, 'binary_evidence', 'complete', observed: 1);
    _expectCoverage(validation, 'defer_exclude', 'clean', observed: 0);
    _expect(
      (validation['matrixIntegrity'] as Map)['sourceSplitPlanMatches'] == true,
      'validator should confirm matrix source split plan freshness',
    );
    _expectStageCommands(
      temp,
      validation,
      'must_ship',
      'git add --pathspec-from-file=docs/production-readiness/release-pr-pathspecs/03.txt',
    );
    _expectStageCommands(
      temp,
      validation,
      'defer_exclude',
      'git restore --staged --pathspec-from-file=docs/production-readiness/release-pr-pathspecs/05.txt',
    );

    await _resetIndex(temp);
    await _stageFixturePaths(temp, [
      'tools/production/release_gate.dart',
      'apps/desktop/lib/headless_api_server.dart',
      'packages/skotiq_core/lib/src/database/database.g.dart',
      'docs/production-readiness/smoke.png',
    ]);
    final partialGenerated = await _runDartScript(
      validator,
      temp,
      allowFailure: true,
    );
    _expect(
      partialGenerated.exitCode == 1,
      'partial generated group should fail validation',
    );
    validation = _readJson(
      temp,
      'docs/production-readiness/release-pr-staged-branch-validation.json',
    );
    _expectCoverage(validation, 'generated_only', 'partial', observed: 1);

    await _resetIndex(temp);
    await _stageFixturePaths(temp, [
      'tools/production/release_gate.dart',
      'apps/desktop/lib/headless_api_server.dart',
      'scratch/research.txt',
    ]);
    final forbidden = await _runDartScript(validator, temp, allowFailure: true);
    _expect(
      forbidden.exitCode == 1,
      'defer/exclude paths should fail validation',
    );
    validation = _readJson(
      temp,
      'docs/production-readiness/release-pr-staged-branch-validation.json',
    );
    _expectCoverage(
      validation,
      'defer_exclude',
      'forbidden_present',
      observed: 1,
    );

    await _resetIndex(temp);
    await File(
      '${temp.path}/docs/production-readiness/release-pr-pathspecs/01.txt',
    ).writeAsString(
      'packages/skotiq_core/lib/src/database/database.g.dart\n',
    );
    await _stageFixturePaths(temp, [
      'tools/production/release_gate.dart',
      'apps/desktop/lib/headless_api_server.dart',
      'packages/skotiq_core/lib/src/database/database.g.dart',
      'packages/skotiq_bridge/lib/src/frb_generated.dart',
      'docs/production-readiness/smoke.png',
    ]);
    final stalePathspec = await _runDartScript(
      validator,
      temp,
      allowFailure: true,
    );
    _expect(
      stalePathspec.exitCode == 1,
      'stale pathspec files should fail validation',
    );
    validation = _readJson(
      temp,
      'docs/production-readiness/release-pr-staged-branch-validation.json',
    );
    final staleIssues = (validation['issues'] as List? ?? const []).join('\n');
    _expect(
      staleIssues.contains('is missing matrix paths'),
      'stale pathspec validation should explain missing matrix paths',
    );

    await _runBucketPolicyFixture(
      root: temp,
      matrixGenerator: matrixGenerator,
      validator: validator,
    );

    await _runBranchModeFixture(
      root: temp,
      matrixGenerator: matrixGenerator,
      validator: validator,
    );

    stdout.writeln('Release PR owner matrix self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

void _expectDraftCommand(
  Map<String, dynamic> matrix,
  String bucketId,
  String expectedCommand,
) {
  final drafts = matrix['draftPullRequests'] as List? ?? const [];
  for (final rawDraft in drafts) {
    final draft = rawDraft as Map<String, dynamic>;
    if (draft['bucketId'] != bucketId) continue;
    _expect(
      draft['stageCommand'] == expectedCommand,
      'draft $bucketId should use owner command $expectedCommand',
    );
    _expect(
      (draft['body']?.toString() ?? '').contains(expectedCommand),
      'draft $bucketId body should include owner command $expectedCommand',
    );
    return;
  }
  throw StateError('missing draft PR entry for bucket $bucketId');
}

Future<void> _runBucketPolicyFixture({
  required Directory root,
  required File matrixGenerator,
  required File validator,
}) async {
  final policyRoot = Directory('${root.path}/bucket-policy-fixture');
  await policyRoot.create(recursive: true);
  await _prepareGitWorkspace(policyRoot);
  await _writeFixturePlan(policyRoot);
  final planFile = File(
    '${policyRoot.path}/docs/production-readiness/release-pr-split-plan.json',
  );
  final plan = jsonDecode(planFile.readAsStringSync()) as Map<String, dynamic>;
  final generatedBucket = (plan['buckets'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((bucket) => bucket['id'] == 'generated-files');
  final paths = (generatedBucket['paths'] as List).cast<Map<String, dynamic>>();
  paths.first['generated'] = false;
  await planFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(plan),
  );

  await _runDartScript(matrixGenerator, policyRoot);
  await _stageFixturePaths(policyRoot, [
    'tools/production/release_gate.dart',
    'apps/desktop/lib/headless_api_server.dart',
    'packages/skotiq_core/lib/src/database/database.g.dart',
    'packages/skotiq_bridge/lib/src/frb_generated.dart',
    'docs/production-readiness/smoke.png',
  ]);
  final validationResult = await _runDartScript(
    validator,
    policyRoot,
    allowFailure: true,
  );
  _expect(
    validationResult.exitCode == 1,
    'generated bucket policy violations should fail validation',
  );
  final validation = _readJson(
    policyRoot,
    'docs/production-readiness/release-pr-staged-branch-validation.json',
  );
  final issues = (validation['issues'] as List? ?? const []).join('\n');
  _expect(
    issues.contains('Generated-only bucket contains non-generated paths'),
    'bucket policy validation should explain generated-only contamination',
  );
}

Future<void> _runBranchModeFixture({
  required Directory root,
  required File matrixGenerator,
  required File validator,
}) async {
  final branchRoot = Directory('${root.path}/branch-mode-fixture');
  await branchRoot.create(recursive: true);
  await _prepareGitWorkspace(branchRoot);
  await _writeFixturePlan(branchRoot);
  await _runDartScript(matrixGenerator, branchRoot);

  await _runGit(branchRoot, ['branch', 'base']);
  await _writePaths(branchRoot, [
    'tools/production/release_gate.dart',
    'apps/desktop/lib/headless_api_server.dart',
    'packages/skotiq_core/lib/src/database/database.g.dart',
    'packages/skotiq_bridge/lib/src/frb_generated.dart',
    'docs/production-readiness/smoke.png',
  ]);
  await _runGit(branchRoot, [
    'add',
    'tools/production/release_gate.dart',
    'apps/desktop/lib/headless_api_server.dart',
    'packages/skotiq_core/lib/src/database/database.g.dart',
    'packages/skotiq_bridge/lib/src/frb_generated.dart',
    'docs/production-readiness/smoke.png',
  ]);
  await _runGit(branchRoot, ['commit', '-m', 'fixture release branch']);

  final branchValidation = await _runDartScript(
    validator,
    branchRoot,
    arguments: ['--mode=branch', '--base=base'],
  );
  _expect(branchValidation.exitCode == 0, 'complete branch diff should pass');
  final validation = _readJson(
    branchRoot,
    'docs/production-readiness/release-pr-staged-branch-validation.json',
  );
  _expect(validation['mode'] == 'branch', 'branch report should record mode');
  _expect(validation['base'] == 'base', 'branch report should record base');
  _expectCoverage(validation, 'must_ship', 'complete', observed: 2);
  _expectCoverage(validation, 'generated_only', 'complete', observed: 2);
  _expectCoverage(validation, 'binary_evidence', 'complete', observed: 1);

  await _writePaths(branchRoot, ['unplanned/new_file.txt']);
  await _runGit(branchRoot, ['add', 'unplanned/new_file.txt']);
  await _runGit(branchRoot, ['commit', '-m', 'fixture unplanned path']);
  final unplannedStrict = await _runDartScript(
    validator,
    branchRoot,
    arguments: ['--mode=branch', '--base=base'],
    allowFailure: true,
  );
  _expect(
    unplannedStrict.exitCode == 1,
    'unplanned branch paths should fail by default',
  );

  final unplannedAllowed = await _runDartScript(
    validator,
    branchRoot,
    arguments: ['--mode=branch', '--base=base', '--allow-new-paths'],
  );
  _expect(
    unplannedAllowed.exitCode == 0,
    'unplanned branch paths should warn when explicitly allowed',
  );
  final allowedValidation = _readJson(
    branchRoot,
    'docs/production-readiness/release-pr-staged-branch-validation.json',
  );
  final warnings = allowedValidation['warnings'] as List? ?? const [];
  _expect(
    warnings.any((warning) => warning.toString().contains('Unplanned paths')),
    'allow-new-paths branch validation should record an unplanned-path warning',
  );
}

Future<void> _prepareGitWorkspace(Directory root) async {
  await _runGit(root, ['init']);
  await _runGit(root, [
    'config',
    'user.email',
    'release-self-test@example.com',
  ]);
  await _runGit(root, ['config', 'user.name', 'Release Self Test']);
  await File('${root.path}/README.md').writeAsString('base\n');
  await _runGit(root, ['add', 'README.md']);
  await _runGit(root, ['commit', '-m', 'seed fixture']);
}

Future<void> _writeFixturePlan(Directory root) async {
  final plan = {
    'generatedAt': '2026-05-05T00:00:00.000000Z',
    'sourceStagingAudit':
        'docs/production-readiness/release-staging-audit.json',
    'sourceGeneratedAt': '2026-05-04T00:00:00.000000Z',
    'currentBranch': 'main',
    'head': 'fixture',
    'entryCount': 7,
    'bucketCount': 5,
    'releaseLists': [
      _releaseList(
        id: 'must-ship',
        title: 'Must Ship',
        pathspec: 'docs/production-readiness/release-pr-lists/01-must-ship.txt',
        count: 2,
      ),
      _releaseList(
        id: 'generated-only',
        title: 'Generated Only',
        pathspec:
            'docs/production-readiness/release-pr-lists/02-generated-only.txt',
        count: 2,
      ),
      _releaseList(
        id: 'binary-evidence',
        title: 'Binary And Evidence',
        pathspec:
            'docs/production-readiness/release-pr-lists/03-binary-evidence.txt',
        count: 1,
      ),
      _releaseList(
        id: 'defer-exclude',
        title: 'Defer Or Exclude',
        pathspec:
            'docs/production-readiness/release-pr-lists/04-defer-exclude.txt',
        count: 2,
      ),
    ],
    'buckets': [
      _bucket(
        id: 'generated-files',
        title: 'Generated Files',
        pathspec: 'docs/production-readiness/release-pr-pathspecs/01.txt',
        paths: [
          'packages/skotiq_core/lib/src/database/database.g.dart',
          'packages/skotiq_bridge/lib/src/frb_generated.dart',
        ],
        generated: 2,
      ),
      _bucket(
        id: 'binary-and-evidence-artifacts',
        title: 'Binary And Evidence Artifacts',
        pathspec: 'docs/production-readiness/release-pr-pathspecs/02.txt',
        paths: ['docs/production-readiness/smoke.png'],
        binary: 1,
      ),
      _bucket(
        id: 'release-infra-evidence',
        title: 'Release Infrastructure And Evidence',
        pathspec: 'docs/production-readiness/release-pr-pathspecs/03.txt',
        paths: ['tools/production/release_gate.dart'],
      ),
      _bucket(
        id: 'headless-remote-api',
        title: 'Headless Remote API And Dashboard',
        pathspec: 'docs/production-readiness/release-pr-pathspecs/04.txt',
        paths: ['apps/desktop/lib/headless_api_server.dart'],
      ),
      _bucket(
        id: 'out-of-release-scope-review',
        title: 'Out Of Release Scope Review',
        pathspec: 'docs/production-readiness/release-pr-pathspecs/05.txt',
        paths: ['scratch/research.txt', 'goal.txt'],
      ),
    ],
  };

  final output = File(
    '${root.path}/docs/production-readiness/release-pr-split-plan.json',
  );
  await output.parent.create(recursive: true);
  await output.writeAsString(const JsonEncoder.withIndent('  ').convert(plan));
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-pathspecs/01.txt',
    [
      'packages/skotiq_core/lib/src/database/database.g.dart',
      'packages/skotiq_bridge/lib/src/frb_generated.dart',
    ],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-pathspecs/02.txt',
    ['docs/production-readiness/smoke.png'],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-pathspecs/03.txt',
    ['tools/production/release_gate.dart'],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-pathspecs/04.txt',
    ['apps/desktop/lib/headless_api_server.dart'],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-pathspecs/05.txt',
    ['scratch/research.txt', 'goal.txt'],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-lists/01-must-ship.txt',
    [
      'tools/production/release_gate.dart',
      'apps/desktop/lib/headless_api_server.dart',
    ],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-lists/02-generated-only.txt',
    [
      'packages/skotiq_core/lib/src/database/database.g.dart',
      'packages/skotiq_bridge/lib/src/frb_generated.dart',
    ],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-lists/03-binary-evidence.txt',
    ['docs/production-readiness/smoke.png'],
  );
  await _writePathspec(
    root,
    'docs/production-readiness/release-pr-lists/04-defer-exclude.txt',
    ['scratch/research.txt', 'goal.txt'],
  );
}

Future<void> _writePathspec(
  Directory root,
  String relativePath,
  List<String> paths,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString('${paths.join('\n')}\n');
}

Map<String, Object?> _bucket({
  required String id,
  required String title,
  required String pathspec,
  required List<String> paths,
  int generated = 0,
  int binary = 0,
}) {
  return {
    'id': id,
    'title': title,
    'intent': 'Fixture intent for $title.',
    'recommendedAction': 'Fixture recommendation for $title.',
    'pathspecFile': pathspec,
    'stageCommand': 'git add --pathspec-from-file=$pathspec',
    'trackedChangeCount': 0,
    'untrackedCount': paths.length,
    'deletedCount': 0,
    'generatedCount': generated,
    'binaryCount': binary,
    'releaseCriticalCount': paths.length,
    'categoryCounts': {'fixture': paths.length},
    'paths': [
      for (final path in paths)
        {
          'status': '??',
          'indexStatus': '?',
          'worktreeStatus': '?',
          'path': path,
          'category': 'fixture',
          'untracked': true,
          'deleted': false,
          'generated': generated > 0,
          'binary': binary > 0,
          'releaseCritical': true,
        },
    ],
  };
}

Map<String, Object?> _releaseList({
  required String id,
  required String title,
  required String pathspec,
  required int count,
}) {
  return {
    'id': id,
    'title': title,
    'description': 'Fixture decision list for $title.',
    'pathspecFile': pathspec,
    'count': count,
  };
}

Future<void> _stageFixturePaths(Directory root, List<String> paths) async {
  await _writePaths(root, paths);
  await _runGit(root, ['add', ...paths]);
}

Future<void> _writePaths(Directory root, List<String> paths) async {
  for (final path in paths) {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    if (!file.existsSync()) {
      await file.writeAsString('fixture\n');
    }
  }
}

Future<void> _resetIndex(Directory root) async {
  await _runGit(root, ['reset', '--mixed']);
}

Future<ProcessResult> _runDartScript(
  File script,
  Directory workingDirectory, {
  List<String> arguments = const [],
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path, ...arguments],
    workingDirectory: workingDirectory.path,
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

Future<void> _runGit(Directory workingDirectory, List<String> args) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: workingDirectory.path,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'git ${args.join(' ')} failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

Map<String, dynamic> _readJson(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('Expected report was not written: ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _expectGroup(
  Map<String, dynamic> matrix,
  String id,
  int expectedPathCount,
) {
  final groups = matrix['decisionGroups'] as Map<String, dynamic>? ?? const {};
  final group = groups[id] as Map<String, dynamic>?;
  _expect(group != null, 'missing decision group $id');
  _expect(
    group!['pathCount'] == expectedPathCount,
    'group $id should have $expectedPathCount paths',
  );
}

void _expectRelatedReleaseList(
  Map<String, dynamic> matrix,
  String id,
  String expectedPathspec,
  int expectedCount,
) {
  final groups = matrix['decisionGroups'] as Map<String, dynamic>? ?? const {};
  final group = groups[id] as Map<String, dynamic>?;
  _expect(group != null, 'missing decision group $id');
  _expect(
    group!['relatedReleaseListFile'] == expectedPathspec,
    'group $id should reference related release list $expectedPathspec',
  );
  _expect(
    group['relatedReleaseListPathCount'] == expectedCount,
    'group $id should report related release list count $expectedCount',
  );

  final releaseLists = matrix['releaseLists'] as Map<String, dynamic>? ?? {};
  final releaseList = releaseLists[id] as Map<String, dynamic>?;
  _expect(releaseList != null, 'missing release list summary for $id');
  _expect(
    releaseList!['pathspecFile'] == expectedPathspec,
    'release list $id should reference $expectedPathspec',
  );
}

void _expectCoverage(
  Map<String, dynamic> validation,
  String id,
  String expectedStatus, {
  required int observed,
}) {
  final groups = validation['decisionGroupCoverage'] as List? ?? const [];
  for (final rawGroup in groups) {
    final group = rawGroup as Map<String, dynamic>;
    if (group['id'] != id) continue;
    _expect(
      group['status'] == expectedStatus,
      'coverage group $id should have status $expectedStatus',
    );
    _expect(
      group['observedPathCount'] == observed,
      'coverage group $id should have $observed observed paths',
    );
    return;
  }
  throw StateError('missing validation coverage group: $id');
}

void _expectStageCommands(
  Directory root,
  Map<String, dynamic> validation,
  String id,
  String expectedCommand,
) {
  final groups = validation['nextStageCommands'] as List? ?? const [];
  for (final rawGroup in groups) {
    final group = rawGroup as Map<String, dynamic>;
    if (group['groupId'] != id) continue;
    final commands = group['commands'] as List? ?? const [];
    _expect(
      commands.contains(expectedCommand),
      'stage command group $id should include $expectedCommand',
    );
    final markdown = File(
      '${root.path}/docs/production-readiness/'
      'release-pr-staged-branch-validation.md',
    ).readAsStringSync();
    _expect(
      markdown.contains(expectedCommand),
      'validation markdown should include $expectedCommand',
    );
    return;
  }
  throw StateError('missing next stage command group: $id');
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
