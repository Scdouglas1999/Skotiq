import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final auditor = File(
    '${repoRoot.path}/tools/production/public_release_checklist_audit.dart',
  );
  if (!auditor.existsSync()) {
    throw StateError('Checklist auditor not found: ${auditor.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_checklist_audit_self_test_',
  );
  try {
    await _writeBlockedChecklist(temp);
    await _runAuditor(auditor, temp);
    final blockedReport = _readReport(temp);
    _expect(
      blockedReport['totalItemCount'] == 4,
      'blocked fixture should have 4 checklist items',
    );
    _expect(
      blockedReport['checkedItemCount'] == 3,
      'blocked fixture should have 3 checked items',
    );
    _expect(
      blockedReport['uncheckedItemCount'] == 1,
      'blocked fixture should have 1 unchecked item',
    );
    _expect(
      blockedReport['checkedWithoutEvidenceCount'] == 1,
      'blocked fixture should have 1 checked item without evidence',
    );
    _expect(
      blockedReport['knownLimitationsReferenced'] == true,
      'blocked fixture should reference known limitations',
    );
    _expect(
      blockedReport['supportedHardwareByPlatformReferenced'] == false,
      'blocked fixture should not reference supported hardware',
    );
    _expectListLength(blockedReport, 'checkedWithoutEvidence', 1);
    _expectListLength(blockedReport, 'uncheckedItems', 1);

    final failResult = await _runAuditor(
      auditor,
      temp,
      arguments: ['--fail-on-unchecked'],
      allowFailure: true,
    );
    _expect(
      failResult.exitCode == 1,
      '--fail-on-unchecked should fail blocked fixture',
    );

    await _writeCompleteChecklist(temp);
    await _runAuditor(auditor, temp);
    final completeReport = _readReport(temp);
    _expect(
      completeReport['totalItemCount'] == 3,
      'complete fixture should have 3 checklist items',
    );
    _expect(
      completeReport['checkedItemCount'] == 3,
      'complete fixture should have 3 checked items',
    );
    _expect(
      completeReport['uncheckedItemCount'] == 0,
      'complete fixture should have no unchecked items',
    );
    _expect(
      completeReport['checkedWithoutEvidenceCount'] == 0,
      'complete fixture should have no checked-without-evidence items',
    );
    _expect(
      completeReport['knownLimitationsReferenced'] == true,
      'complete fixture should reference known limitations',
    );
    _expect(
      completeReport['supportedHardwareByPlatformReferenced'] == true,
      'complete fixture should reference supported hardware',
    );

    await _runAuditor(auditor, temp, arguments: ['--fail-on-unchecked']);

    stdout.writeln('Public release checklist audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writeBlockedChecklist(Directory root) async {
  final file = File(
    '${root.path}/docs/production-readiness/public-release-master-checklist.md',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString('''
# Public Release Master Checklist

See docs/known-limitations.md.

## Global Release Gates

- [x] Analyzer passes.
  Evidence: `docs/production-readiness/analyzer-rollup.json`.
- [x] Checklist item has no evidence.
- [ ] Linux release build evidence exists.
  Evidence needed from Linux host.

## Final Signoff

- [X] Final signoff has evidence.
  tests=final fixture.
''');
}

Future<void> _writeCompleteChecklist(Directory root) async {
  final file = File(
    '${root.path}/docs/production-readiness/public-release-master-checklist.md',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString('''
# Public Release Master Checklist

See docs/known-limitations.md and docs/supported-hardware-by-platform.md.

## Global Release Gates

- [x] Analyzer passes.
  Evidence: `docs/production-readiness/analyzer-rollup.json`.
- [x] Linux release build evidence exists.
  manual=linux evidence fixture.

## Final Signoff

- [x] Final signoff has evidence.
  result=ship fixture.
''');
}

Future<ProcessResult> _runAuditor(
  File auditor,
  Directory workingDirectory, {
  List<String> arguments = const [],
  bool allowFailure = false,
}) async {
  final result = await Process.run('dart', [
    auditor.path,
    ...arguments,
  ], workingDirectory: workingDirectory.path);
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      'Checklist auditor failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return result;
}

Map<String, dynamic> _readReport(Directory root) {
  final report = File(
    '${root.path}/docs/production-readiness/public-release-checklist-audit.json',
  );
  return jsonDecode(report.readAsStringSync()) as Map<String, dynamic>;
}

void _expectListLength(
  Map<String, dynamic> report,
  String field,
  int expectedLength,
) {
  _expect(
    report[field] is List && (report[field] as List).length == expectedLength,
    '$field should have $expectedLength entries',
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
