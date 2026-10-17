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
    _expect(passing['ruleCount'] == 5, 'passing fixture should run all rules');
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
    'packages/skotiq_core/lib/src/backend/disconnected_backend.dart',
    '''
class DisconnectedBackend {
  Future<void> focuserHalt(String id) async {
    throw StateError('No connected focuser');
  }

  Future<void> autofocusCancel(String id) async {
    throw StateError('No connected focuser');
  }
}
''',
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
    glob: packages/skotiq_core/lib/src/backend/ffi_backend.dart
    forbidden_pattern: 'UnimplementedError\('
    require_present: true

  - id: network_backend_unimplemented
    description: Disallow UnimplementedError in production backend paths
    glob: packages/skotiq_core/lib/src/backend/network_backend.dart
    forbidden_pattern: 'UnimplementedError\('
    require_present: true

  - id: bridge_stub_noop_log
    description: Disallow sequencer checkpoint no-op stub logging
    glob: packages/skotiq_bridge/lib/src/bridge_stub.dart
    forbidden_pattern: 'sequencer.*no-op in stub mode'
    case_sensitive: false
    require_present: true

  - id: focuser_halt_noop
    description: Disconnected backend focuserHalt must not be a no-op
    glob: packages/skotiq_core/lib/src/backend/disconnected_backend.dart
    forbidden_pattern: 'Future<void>\s+focuserHalt\s*\([^)]*\)\s*async\s*\{\s*\}'
    multi_line: true
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
