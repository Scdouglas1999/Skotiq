import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final stagingAuditor = File(
    '${repoRoot.path}/tools/production/release_staging_audit.dart',
  );
  final prPlanner = File(
    '${repoRoot.path}/tools/production/release_pr_split_plan.dart',
  );
  if (!stagingAuditor.existsSync()) {
    throw StateError(
      'Release staging auditor not found: ${stagingAuditor.path}',
    );
  }
  if (!prPlanner.existsSync()) {
    throw StateError('Release PR planner not found: ${prPlanner.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_release_staging_pr_plan_self_test_',
  );
  try {
    await _prepareGitWorkspace(temp);
    await _writeDirtyFixture(temp);

    await _runDartScript(stagingAuditor, temp);
    final staging = _readJson(
      temp,
      'docs/production-readiness/release-staging-audit.json',
    );
    _expect(staging['entryCount'] == 8, 'staging audit should find 8 entries');
    _expect(
      staging['modifiedCount'] == 2,
      'staging audit should find 2 tracked changes',
    );
    _expect(
      staging['deletedCount'] == 1,
      'staging audit should find 1 deleted tracked file',
    );
    _expect(
      staging['untrackedCount'] == 6,
      'staging audit should find 6 untracked entries',
    );
    _expect(
      staging['binaryCount'] == 1,
      'staging audit should find 1 binary entry',
    );
    _expect(
      staging['generatedCount'] == 1,
      'staging audit should find 1 generated entry',
    );
    _expect(
      staging['untrackedReleaseCriticalCount'] == 5,
      'staging audit should find 5 untracked release-critical entries',
    );
    _expectCategory(staging, 'release-tooling', 1);
    _expectCategory(staging, 'headless-remote', 1);
    _expectCategory(staging, 'generated', 1);
    _expectCategory(staging, 'release-evidence-binary', 1);
    _expectCategory(staging, 'bridge', 1);
    _expectCategory(staging, 'tooling', 1);
    _expectCategory(staging, 'other', 2);

    final stalePathspec = File(
      '${temp.path}/docs/production-readiness/release-pr-pathspecs/99-stale.txt',
    );
    await stalePathspec.parent.create(recursive: true);
    await stalePathspec.writeAsString('stale/path.txt\n');
    final staleDraft = File(
      '${temp.path}/docs/production-readiness/release-pr-drafts/99-stale.md',
    );
    await staleDraft.parent.create(recursive: true);
    await staleDraft.writeAsString('# stale\n');
    final staleReleaseList = File(
      '${temp.path}/docs/production-readiness/release-pr-lists/99-stale.txt',
    );
    await staleReleaseList.parent.create(recursive: true);
    await staleReleaseList.writeAsString('stale/path.txt\n');

    await _runDartScript(prPlanner, temp);
    final plan = _readJson(
      temp,
      'docs/production-readiness/release-pr-split-plan.json',
    );
    _expect(
      plan['entryCount'] == staging['entryCount'],
      'PR plan entry count should match staging audit',
    );
    _expect(
      plan['untrackedReleaseCriticalCount'] == 5,
      'PR plan should preserve untracked release-critical count',
    );
    _expect(plan['bucketCount'] == 7, 'PR plan should create 7 buckets');
    _expect(
      !stalePathspec.existsSync(),
      'planner should remove stale pathspecs',
    );
    _expect(
      !staleDraft.existsSync(),
      'planner should remove stale draft descriptions',
    );
    _expect(
      !staleReleaseList.existsSync(),
      'planner should remove stale release decision lists',
    );

    final stagedPaths = _pathsFromStaging(staging);
    final plannedPaths = _pathsFromPlan(plan);
    _expectSetEquals(
      stagedPaths,
      plannedPaths,
      'PR plan should assign every staged audit path exactly once',
    );
    _expectBucket(plan, 'generated-files', [
      'packages/skotiq_core/lib/src/database/database.g.dart',
    ]);
    _expectBucket(plan, 'binary-and-evidence-artifacts', [
      'docs/production-readiness/smoke.png',
    ]);
    _expectBucket(plan, 'release-infra-evidence', [
      'tools/production/release_gate_fixture.dart',
    ]);
    _expectBucket(plan, 'headless-remote-api', [
      'apps/desktop/web_dashboard/js/api.js',
    ]);
    _expectBucket(plan, 'native-driver-bridge', [
      'packages/skotiq_bridge/lib/src/api.dart',
    ]);
    _expectBucket(plan, 'tests-and-support-tooling', [
      'scripts/deleted_tool.ps1',
    ]);
    _expectBucket(plan, 'out-of-release-scope-review', [
      'README.md',
      'scratch/research.txt',
    ]);
    _expectPathspecsMatchBuckets(temp, plan);
    _expectDraftDescriptionsMatchBuckets(temp, plan);
    _expectReleaseListsMatchPlan(temp, plan);

    final failOnDirty = await _runDartScript(
      stagingAuditor,
      temp,
      arguments: ['--fail-on-dirty'],
      allowFailure: true,
    );
    _expect(
      failOnDirty.exitCode == 1,
      '--fail-on-dirty should fail when the fixture is dirty',
    );
    final failOnUntrackedCritical = await _runDartScript(
      stagingAuditor,
      temp,
      arguments: ['--fail-on-untracked-critical'],
      allowFailure: true,
    );
    _expect(
      failOnUntrackedCritical.exitCode == 1,
      '--fail-on-untracked-critical should fail for release-critical untracked paths',
    );

    stdout.writeln('Release staging and PR split plan self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
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
  await File('${root.path}/scripts/deleted_tool.ps1')
      .create(recursive: true)
      .then((file) => file.writeAsString('Write-Host base\n'));
  await Directory(
    '${root.path}/docs/production-readiness',
  ).create(recursive: true);
  await _runGit(root, ['add', 'README.md', 'scripts/deleted_tool.ps1']);
  await _runGit(root, ['commit', '-m', 'seed fixture']);
}

Future<void> _writeDirtyFixture(Directory root) async {
  await File('${root.path}/README.md').writeAsString('changed\n');
  await File('${root.path}/scripts/deleted_tool.ps1').delete();
  await File('${root.path}/tools/production/release_gate_fixture.dart')
      .create(recursive: true)
      .then((file) => file.writeAsString('void main() {}\n'));
  await File('${root.path}/apps/desktop/web_dashboard/js/api.js')
      .create(recursive: true)
      .then((file) => file.writeAsString('console.log("fixture");\n'));
  await File(
    '${root.path}/packages/skotiq_core/lib/src/database/database.g.dart',
  ).create(recursive: true).then((file) => file.writeAsString('// generated\n'));
  await File(
    '${root.path}/docs/production-readiness/smoke.png',
  ).writeAsBytes([1, 2, 3]);
  await File('${root.path}/packages/skotiq_bridge/lib/src/api.dart')
      .create(recursive: true)
      .then((file) => file.writeAsString('class Fixture {}\n'));
  await File('${root.path}/scratch/research.txt')
      .create(recursive: true)
      .then((file) => file.writeAsString('not release scope\n'));
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

Set<String> _pathsFromStaging(Map<String, dynamic> staging) {
  final categories = staging['categories'] as Map<String, dynamic>? ?? const {};
  final paths = <String>{};
  for (final category in categories.values) {
    final value = category as Map<String, dynamic>? ?? const {};
    for (final entry in value['paths'] as List? ?? const []) {
      paths.add((entry as Map<String, dynamic>)['path'] as String);
    }
  }
  return paths;
}

Set<String> _pathsFromPlan(Map<String, dynamic> plan) {
  final paths = <String>{};
  for (final bucket in plan['buckets'] as List? ?? const []) {
    final bucketMap = bucket as Map<String, dynamic>;
    for (final entry in bucketMap['paths'] as List? ?? const []) {
      final path = (entry as Map<String, dynamic>)['path'] as String;
      _expect(paths.add(path), 'path was assigned to multiple buckets: $path');
    }
  }
  return paths;
}

void _expectCategory(
  Map<String, dynamic> staging,
  String category,
  int expectedCount,
) {
  final categories = staging['categories'] as Map<String, dynamic>? ?? const {};
  final value = categories[category] as Map<String, dynamic>?;
  _expect(value != null, 'missing category: $category');
  _expect(
    value!['count'] == expectedCount,
    'category $category should have $expectedCount entries',
  );
}

void _expectBucket(
  Map<String, dynamic> plan,
  String id,
  List<String> expectedPaths,
) {
  final bucket = _bucketById(plan, id);
  _expect(bucket != null, 'missing bucket: $id');
  final paths = [
    for (final entry in bucket!['paths'] as List? ?? const [])
      (entry as Map<String, dynamic>)['path'] as String,
  ];
  _expectSetEquals(
    expectedPaths.toSet(),
    paths.toSet(),
    'bucket $id paths should match fixture',
  );
}

void _expectPathspecsMatchBuckets(Directory root, Map<String, dynamic> plan) {
  for (final rawBucket in plan['buckets'] as List? ?? const []) {
    final bucket = rawBucket as Map<String, dynamic>;
    final pathspecFile = File('${root.path}/${bucket['pathspecFile']}');
    _expect(
      pathspecFile.existsSync(),
      'pathspec should exist for bucket ${bucket['id']}',
    );
    final pathspecPaths = LineSplitter.split(
      pathspecFile.readAsStringSync(),
    ).where((line) => line.isNotEmpty).toSet();
    final bucketPaths = {
      for (final entry in bucket['paths'] as List? ?? const [])
        (entry as Map<String, dynamic>)['path'] as String,
    };
    _expectSetEquals(
      bucketPaths,
      pathspecPaths,
      'pathspec should match bucket ${bucket['id']}',
    );
  }
}

void _expectReleaseListsMatchPlan(Directory root, Map<String, dynamic> plan) {
  final allListPaths = <String>{};
  final plannedPaths = _pathsFromPlan(plan);
  final lists = plan['releaseLists'] as List? ?? const [];
  _expect(lists.length == 4, 'planner should emit four release lists');

  for (final rawList in lists) {
    final list = rawList as Map<String, dynamic>;
    final listFile = File('${root.path}/${list['pathspecFile']}');
    _expect(
      listFile.existsSync(),
      'release list should exist for ${list['id']}',
    );
    final pathspecPaths = LineSplitter.split(
      listFile.readAsStringSync(),
    ).where((line) => line.isNotEmpty).toSet();
    _expect(
      pathspecPaths.length == list['count'],
      'release list count should match pathspec for ${list['id']}',
    );
    for (final path in pathspecPaths) {
      _expect(allListPaths.add(path), 'path was assigned to multiple lists');
    }
  }

  _expectSetEquals(
    plannedPaths,
    allListPaths,
    'release decision lists should cover every planned path exactly once',
  );

  _expectReleaseListContains(
    plan,
    'generated-only',
    'packages/skotiq_core/lib/src/database/database.g.dart',
  );
  _expectReleaseListContains(
    plan,
    'binary-evidence',
    'docs/production-readiness/smoke.png',
  );
  _expectReleaseListContains(
    plan,
    'must-ship',
    'tools/production/release_gate_fixture.dart',
  );
  _expectReleaseListContains(plan, 'defer-exclude', 'scratch/research.txt');
}

void _expectReleaseListContains(
  Map<String, dynamic> plan,
  String id,
  String expectedPath,
) {
  for (final rawList in plan['releaseLists'] as List? ?? const []) {
    final list = rawList as Map<String, dynamic>;
    if (list['id'] != id) continue;
    final paths = {
      for (final rawPath in list['paths'] as List? ?? const [])
        (rawPath as Map<String, dynamic>)['path'] as String,
    };
    _expect(
      paths.contains(expectedPath),
      'release list $id should contain $expectedPath',
    );
    return;
  }
  throw StateError('missing release list: $id');
}

void _expectDraftDescriptionsMatchBuckets(
  Directory root,
  Map<String, dynamic> plan,
) {
  for (final rawBucket in plan['buckets'] as List? ?? const []) {
    final bucket = rawBucket as Map<String, dynamic>;
    final draftFile = File('${root.path}/${bucket['draftDescriptionFile']}');
    _expect(
      draftFile.existsSync(),
      'draft description should exist for bucket ${bucket['id']}',
    );
    final draft = draftFile.readAsStringSync();
    _expect(
      draft.contains('# PR '),
      'draft description should include a PR title for bucket ${bucket['id']}',
    );
    _expect(
      draft.contains('## Stage Command'),
      'draft description should include a stage command for bucket ${bucket['id']}',
    );
    _expect(
      draft.contains(bucket['pathspecFile'] as String),
      'draft description should reference the pathspec for bucket ${bucket['id']}',
    );
    _expect(
      draft.contains('## Verification'),
      'draft description should include verification tasks for bucket ${bucket['id']}',
    );
  }
}

Map<String, dynamic>? _bucketById(Map<String, dynamic> plan, String id) {
  for (final bucket in plan['buckets'] as List? ?? const []) {
    final bucketMap = bucket as Map<String, dynamic>;
    if (bucketMap['id'] == id) {
      return bucketMap;
    }
  }
  return null;
}

void _expectSetEquals(
  Set<String> expected,
  Set<String> actual,
  String message,
) {
  final missing = expected.difference(actual);
  final unexpected = actual.difference(expected);
  _expect(
    missing.isEmpty && unexpected.isEmpty,
    '$message; missing=$missing unexpected=$unexpected',
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
