import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/fail_closed_check.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Fail-closed audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_fail_closed_check_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/fail-closed-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(passing['ruleCount'] == 3, 'passing fixture should run all rules');
    _expect(
      passing['violationCount'] == 0,
      'passing fixture should have no fail-closed violations',
    );

    await _writeForbiddenPatternFixture(temp);
    final patternResult = await _runAudit(script, temp, allowFailure: true);
    _expect(patternResult.exitCode == 1, 'forbidden pattern should fail');
    final patternFailure = _readJson(
      temp,
      'docs/production-readiness/fail-closed-audit.json',
    );
    _expect(
      patternFailure['violationCount'] == 1,
      'forbidden pattern fixture should report one violation',
    );
    final patternViolations = patternFailure['violations'] as List? ?? const [];
    _expect(
      patternViolations.single['description'].toString().contains(
        'UnimplementedError',
      ),
      'forbidden pattern fixture should identify the failed rule',
    );

    await _writeMissingFileFixture(temp);
    final missingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(missingResult.exitCode == 1, 'missing file should fail');
    final missingFailure = _readJson(
      temp,
      'docs/production-readiness/fail-closed-audit.json',
    );
    final missingViolations = missingFailure['violations'] as List? ?? const [];
    _expect(
      missingViolations.any(
        (violation) =>
            violation['description'].toString().contains('[MISSING FILE]'),
      ),
      'missing file fixture should report a missing production file',
    );

    // A rule that names a declaration covers the library's part files.
    await _writePassingFixture(temp);
    await _writeFile(
      temp,
      'packages/skotiq_core/lib/src/backend/ffi_backend.dart',
      "part 'ffi_backend/operations.dart';\n\nclass FfiBackend {}\n",
    );
    await _writeFile(
      temp,
      'packages/skotiq_core/lib/src/backend/ffi_backend/operations.dart',
      "part of '../ffi_backend.dart';\n\n"
          "void connect() => throw UnimplementedError('later');\n",
    );
    final partResult = await _runAudit(script, temp, allowFailure: true);
    _expect(partResult.exitCode == 1, 'a part-file violation should fail');
    final partViolations =
        _readJson(
              temp,
              'docs/production-readiness/fail-closed-audit.json',
            )['violations']
            as List;
    _expect(
      partViolations.single['path'] ==
          'packages/skotiq_core/lib/src/backend/ffi_backend/operations.dart',
      'the violation should name the part file, got $partViolations',
    );

    // The rule follows the declaration when its library moves.
    await Directory(
      '${temp.path}/packages/skotiq_core/lib/src/backend',
    ).rename('${temp.path}/packages/skotiq_core/lib/src/native_backend');
    await _writeFile(
      temp,
      'packages/skotiq_core/lib/src/backend/network_backend.dart',
      'class NetworkBackend {}\n',
    );
    final movedResult = await _runAudit(script, temp, allowFailure: true);
    final movedViolations =
        _readJson(
              temp,
              'docs/production-readiness/fail-closed-audit.json',
            )['violations']
            as List;
    _expect(
      movedResult.exitCode == 1 &&
          movedViolations.single['path'] ==
              'packages/skotiq_core/lib/src/native_backend/ffi_backend/operations.dart',
      'a moved library should still be checked, got $movedViolations',
    );

    // A declaration that no longer exists fails instead of checking nothing.
    await _writeFile(
      temp,
      'packages/skotiq_core/lib/src/native_backend/ffi_backend.dart',
      'class RenamedBackend {}\n',
    );
    final goneResult = await _runAudit(script, temp, allowFailure: true);
    final goneViolations =
        _readJson(
              temp,
              'docs/production-readiness/fail-closed-audit.json',
            )['violations']
            as List;
    _expect(
      goneResult.exitCode == 1 &&
          goneViolations.any(
            (v) =>
                v['id'] == 'ffi_backend_unimplemented' &&
                v['description'].toString().contains('[MISSING FILE]'),
          ),
      'a missing declaration should fail, got $goneViolations',
    );

    stdout.writeln('Fail-closed audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeRequiredFiles(root, bridgeStub: 'void bridgeStub() {}\n');
}

Future<void> _writeForbiddenPatternFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeRequiredFiles(
    root,
    bridgeStub: '''
void bridgeStub() {
  throw UnimplementedError('unsafe production stub');
}
''',
  );
}

Future<void> _writeMissingFileFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeRequiredFiles(root, bridgeStub: 'void bridgeStub() {}\n');
  await File(
    '${root.path}/packages/skotiq_core/lib/src/backend/network_backend.dart',
  ).delete();
}

Future<void> _writeRequiredFiles(
  Directory root, {
  required String bridgeStub,
}) async {
  await _writeFile(
    root,
    'docs/production-readiness/fail_closed_rules.yaml',
    _rulesFixture,
  );
  await _writeFile(
    root,
    'packages/skotiq_bridge/lib/src/bridge_stub.dart',
    bridgeStub,
  );
  // Every policy root has to contribute files.
  await _writeFile(root, 'apps/desktop/lib/main.dart', 'void main() {}\n');
  await _writeFile(root, 'native/skotiq_native/bridge/src/lib.rs', '\n');
  await _writeFile(root, 'tools/production/tool.dart', 'void main() {}\n');
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/backend/ffi_backend.dart',
    'class FfiBackend {}\n',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/backend/network_backend.dart',
    'class NetworkBackend {}\n',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/database/daos/targets_dao.dart',
    'class TargetsDao {}\n',
  );
}

const _rulesFixture = r'''
rules:
  - id: bridge_unimplemented
    description: Disallow UnimplementedError in production backend paths
    glob: packages/skotiq_bridge/lib/src/bridge_stub.dart
    forbidden_pattern: 'UnimplementedError\('
    require_present: true

  - id: ffi_backend_unimplemented
    description: Disallow UnimplementedError in production backend paths
    declares: FfiBackend
    forbidden_pattern: 'UnimplementedError\('
    require_present: true

  - id: network_backend_unimplemented
    description: Disallow UnimplementedError in production backend paths
    glob: packages/skotiq_core/lib/src/backend/network_backend.dart
    forbidden_pattern: 'UnimplementedError\('
    require_present: true
''';

Future<void> _resetWorkspace(Directory root) async {
  for (final path in ['packages', 'docs']) {
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
    [
      script.path,
      // The fixtures are judged against the repository's real scan scope.
      '--scope',
      '${Directory.current.path}/docs/production-readiness/audit-scope.yaml',
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
