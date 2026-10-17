import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/dependency_hygiene.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Dependency hygiene audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_dependency_hygiene_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/dependency-hygiene.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['packageCount'] == 2,
      'passing fixture should scan packages',
    );
    _expect(
      passing['violationCount'] == 0,
      'passing fixture should have no dependency violations',
    );
    final packages = passing['packages'] as List? ?? const [];
    _expect(
      packages.any(
        (pkg) =>
            pkg['packageName'] == 'good_app' &&
            pkg['missingDirectDependencies'].isEmpty,
      ),
      'passing fixture should report good_app with no missing dependencies',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/dependency-hygiene.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    _expect(
      failing['violationCount'] == 1,
      'failing fixture should report one dependency violation',
    );
    final violations = failing['violations'] as List? ?? const [];
    _expect(
      violations.single['dependencyName'] == 'collection',
      'failing fixture should identify the undeclared package import',
    );

    stdout.writeln('Dependency hygiene self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeFile(root, 'apps/good_app/pubspec.yaml', '''
name: good_app
dependencies:
  meta: any
dev_dependencies:
  test: any
''');
  await _writeFile(root, 'apps/good_app/lib/main.dart', '''
import 'package:meta/meta.dart';
import 'package:good_app/main.dart';

@visibleForTesting
void entrypoint() {}
''');
  await _writeFile(root, 'packages/no_lib/pubspec.yaml', '''
name: no_lib
dependencies:
  path: any
''');
}

Future<void> _writeFailingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeFile(root, 'apps/bad_app/pubspec.yaml', '''
name: bad_app
dependencies:
  meta: any
''');
  await _writeFile(root, 'apps/bad_app/lib/main.dart', '''
import 'package:collection/collection.dart';

void entrypoint() {
  const DeepCollectionEquality().equals([], []);
}
''');
}

Future<void> _resetWorkspace(Directory root) async {
  for (final path in ['apps', 'packages', 'docs']) {
    final dir = Directory('${root.path}/$path');
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path],
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
