import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File('${repoRoot.path}/tools/production/analyzer_rollup.dart');
  if (!script.existsSync()) {
    throw StateError('Analyzer rollup not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_analyzer_rollup_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runRollup(script, temp);
    final passing = _readJson(temp, 'reports/analyzer-rollup.json');
    final passingSummary = passing['summary'] as Map<String, dynamic>;
    final passingProduction =
        passingSummary['production'] as Map<String, dynamic>;
    _expect(
      passing['analyzerExitCode'] == 0,
      'passing fixture analyzer should exit cleanly',
    );
    _expect(
      passingSummary['failed'] == false &&
          passingProduction['errors'] == 0 &&
          passingProduction['warnings'] == 0,
      'passing fixture should have no production analyzer issues',
    );

    await _writeExcludedErrorFixture(temp);
    await _runRollup(script, temp);
    final excluded = _readJson(temp, 'reports/analyzer-rollup.json');
    final excludedSummary = excluded['summary'] as Map<String, dynamic>;
    final excludedAll = excludedSummary['all'] as Map<String, dynamic>;
    final excludedProduction =
        excludedSummary['production'] as Map<String, dynamic>;
    _expect(
      (excluded['analyzerExitCode'] as num).toInt() != 0,
      'excluded fixture should still record the analyzer process failure',
    );
    _expect(
      excludedSummary['failed'] == false &&
          (excludedAll['errors'] as num).toInt() > 0 &&
          excludedProduction['errors'] == 0,
      'excluded test-only errors should not fail the production policy',
    );

    await _writeFailingProductionFixture(temp);
    final failingResult = await _runRollup(script, temp, allowFailure: true);
    _expect(
      failingResult.exitCode == 1,
      'production analyzer error should fail the rollup',
    );
    final failing = _readJson(temp, 'reports/analyzer-rollup.json');
    final failingSummary = failing['summary'] as Map<String, dynamic>;
    final failingProduction =
        failingSummary['production'] as Map<String, dynamic>;
    _expect(
      failingSummary['failed'] == true &&
          (failingProduction['errors'] as num).toInt() > 0,
      'failing fixture should report production analyzer errors',
    );

    stdout.writeln('Analyzer rollup self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writePackage(root, 'apps/good_app', 'void main() {}\n');
  await _writePackage(root, 'packages/good_pkg', 'int answer() => 42;\n');
}

Future<void> _writeExcludedErrorFixture(Directory root) async {
  await _writePassingFixture(root);
  await _writeFile(
    root,
    'apps/good_app/test/bad_test.dart',
    'void main() { missingTestOnlySymbol; }\n',
  );
}

Future<void> _writeFailingProductionFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writePackage(
    root,
    'apps/bad_app',
    'void main() { missingProductionSymbol; }\n',
  );
  await _writePackage(root, 'packages/good_pkg', 'int answer() => 42;\n');
}

Future<void> _writePackage(
  Directory root,
  String packagePath,
  String dartContent,
) async {
  final packageName = packagePath.split('/').last;
  await _writeFile(root, '$packagePath/pubspec.yaml', '''
name: $packageName
environment:
  sdk: '>=3.0.0 <4.0.0'
''');
  await _writeFile(root, '$packagePath/lib/main.dart', dartContent);
}

Future<void> _resetWorkspace(Directory root) async {
  for (final path in ['apps', 'packages', 'docs', 'reports']) {
    final dir = Directory('${root.path}/$path');
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
  await Directory('${root.path}/apps').create(recursive: true);
  await Directory('${root.path}/packages').create(recursive: true);
}

Future<ProcessResult> _runRollup(
  File script,
  Directory root, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path, '--report', 'reports/analyzer-rollup.json'],
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
