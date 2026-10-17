import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final auditor = File(
    '${repoRoot.path}/tools/production/public_release_completion_audit.dart',
  );
  if (!auditor.existsSync()) {
    throw StateError('Completion auditor not found: ${auditor.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_completion_audit_self_test_',
  );
  try {
    await _prepareWorkspace(temp);

    await _writeBlockedFixture(temp);
    await _runAuditor(auditor, temp);
    final blockedReport = _readReport(temp);
    _expect(
      blockedReport['decision'] == 'NOT_ACHIEVED',
      'blocked fixture decision should be NOT_ACHIEVED',
    );
    _expect(
      blockedReport['gateDecision'] == 'NOT_READY',
      'blocked fixture gateDecision should stay NOT_READY',
    );
    _expect(
      blockedReport['completeCount'] == 0,
      'blocked fixture completeCount should be 0',
    );
    _expect(
      blockedReport['blockedOrIncompleteCount'] == 7,
      'blocked fixture should have 7 blocked/incomplete checks',
    );
    _expectSourceArtifacts(blockedReport);
    _expectCheckStatus(
      blockedReport,
      'split_generated_binary_native',
      'in_progress',
    );
    _expectStructuredBlockerInput(
      blockedReport,
      'linux_release_build',
      contains: 'fixture input for linux_release_build',
    );
    _expectStructuredBlockerInput(
      blockedReport,
      'integrated_remote_headless',
      contains: 'fixture input for second_device_lan_firewall',
    );
    _expectStructuredBlockerInput(
      blockedReport,
      'integrated_remote_headless',
      contains: 'fixture input for real_remote_control_actions',
    );

    await _writeAchievedFixture(temp);
    await _runAuditor(auditor, temp);
    final achievedReport = _readReport(temp);
    _expect(
      achievedReport['decision'] == 'ACHIEVED',
      'achieved fixture decision should be ACHIEVED',
    );
    _expect(
      achievedReport['completionDecision'] == 'ACHIEVED',
      'completionDecision should mirror decision',
    );
    _expect(
      achievedReport['gateDecision'] == 'READY',
      'achieved fixture gateDecision should stay READY',
    );
    _expect(
      achievedReport['ready'] == true,
      'achieved fixture ready should be true',
    );
    _expect(
      achievedReport['completeCount'] == 7,
      'achieved fixture completeCount should be 7',
    );
    _expect(
      achievedReport['blockedOrIncompleteCount'] == 0,
      'achieved fixture should have no blocked/incomplete checks',
    );
    _expectCheckStatus(
      achievedReport,
      'split_generated_binary_native',
      'complete',
    );

    stdout.writeln('Public release completion audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _prepareWorkspace(Directory root) async {
  await Directory(
    '${root.path}/docs/production-readiness',
  ).create(recursive: true);
  await Directory(
    '${root.path}/docs/production-readiness/release-pr-pathspecs',
  ).create(recursive: true);
  await File('${root.path}/goal.txt').writeAsString('''
**P0 Before Public Release**
- Create a clean release branch/PR from the dirty worktree so the final artifact is reviewable.
- Split generated/binary/native changes from Dart/UI changes where possible.
- Do a Linux release build on an actual Linux environment, not inferred from Windows.
- Run a full hardware smoke pass with real or simulator-backed camera, mount, focuser, filter wheel, rotator, guider, dome, weather, and safety devices.
- Verify upgrade/migration from an older Skotiq profile/database.
- Verify headless auth, LAN opt-in, dashboard, mobile remote client, and WebSocket reconnect behavior together.
- Produce a release checklist with known unsupported-by-platform items clearly documented.
''');
}

Future<void> _writeBlockedFixture(Directory root) async {
  await _writeJson(root, 'docs/production-readiness/public-release-gate.json', {
    'decision': 'NOT_READY',
    'ready': false,
    'checks': [
      _gateCheck('release_staging', false),
      _gateCheck('linux_release_build', false),
      _gateCheck('hardware_control_smoke', false),
      _gateCheck('manual_migration', false),
      _gateCheck('mobile_remote_smoke', true),
      _gateCheck('mobile_reconnect_smoke', true),
      _gateCheck('second_device_lan_firewall', false),
      _gateCheck('real_remote_control_actions', false),
      _gateCheck('final_checklist', false),
    ],
  });
  await _writeJson(
    root,
    'docs/production-readiness/public-release-blocker-inputs.json',
    {
      'blockers': [
        for (final id in [
          'release_staging',
          'linux_release_build',
          'hardware_control_smoke',
          'manual_migration',
          'second_device_lan_firewall',
          'real_remote_control_actions',
          'final_checklist',
        ])
          {
            'id': id,
            'requiredInput': 'fixture input for $id',
            'rerunCommands': ['dart run fixture:$id'],
            'acceptanceCriteria': ['fixture acceptance for $id'],
            'expectedEvidence': ['docs/production-readiness/$id.json'],
          },
      ],
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/public-release-external-evidence.json',
    {'passedCount': 0, 'checkCount': 5},
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-staging-audit.json',
    {
      'currentBranch': 'main',
      'entryCount': 797,
      'untrackedReleaseCriticalCount': 263,
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-pr-split-plan.json',
    {'bucketCount': 10, 'entryCount': 797},
  );
  await _writeJson(
    root,
    'docs/production-readiness/public-release-checklist-audit.json',
    {
      'uncheckedItemCount': 284,
      'checkedWithoutEvidenceCount': 0,
      'knownLimitationsReferenced': true,
      'supportedHardwareByPlatformReferenced': true,
    },
  );
}

Future<void> _writeAchievedFixture(Directory root) async {
  await _writeJson(root, 'docs/production-readiness/public-release-gate.json', {
    'decision': 'READY',
    'ready': true,
    'checks': [
      _gateCheck('release_staging', true),
      _gateCheck('linux_release_build', true),
      _gateCheck('hardware_control_smoke', true),
      _gateCheck('manual_migration', true),
      _gateCheck('mobile_remote_smoke', true),
      _gateCheck('mobile_reconnect_smoke', true),
      _gateCheck('second_device_lan_firewall', true),
      _gateCheck('real_remote_control_actions', true),
      _gateCheck('final_checklist', true),
    ],
  });
  await _writeJson(
    root,
    'docs/production-readiness/public-release-blocker-inputs.json',
    {'blockers': []},
  );
  await _writeJson(
    root,
    'docs/production-readiness/public-release-external-evidence.json',
    {'passedCount': 5, 'checkCount': 5},
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-staging-audit.json',
    {
      'currentBranch': 'release/public-readiness',
      'entryCount': 0,
      'untrackedReleaseCriticalCount': 0,
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-pr-split-plan.json',
    {'bucketCount': 10, 'entryCount': 0},
  );
  await _writeJson(
    root,
    'docs/production-readiness/public-release-checklist-audit.json',
    {
      'uncheckedItemCount': 0,
      'checkedWithoutEvidenceCount': 0,
      'knownLimitationsReferenced': true,
      'supportedHardwareByPlatformReferenced': true,
    },
  );
  await File('${root.path}/docs/known-limitations.md')
      .create(recursive: true)
      .then((file) => file.writeAsString('# Known Limitations\n'));
  await File(
    '${root.path}/docs/supported-hardware-by-platform.md',
  ).writeAsString('# Supported Hardware By Platform\n');
  await File(
    '${root.path}/docs/production-readiness/release-pr-pathspecs/01-fixture.txt',
  ).writeAsString('# fixture\n');
}

Map<String, Object?> _gateCheck(String id, bool passed) => {
  'id': id,
  'label': id,
  'passed': passed,
  'evidence': 'docs/production-readiness/$id.json',
  'detail': passed ? 'fixture passed' : 'fixture blocked',
};

Future<void> _writeJson(
  Directory root,
  String relativePath,
  Object? data,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

Future<void> _runAuditor(File auditor, Directory workingDirectory) async {
  final result = await Process.run('dart', [
    auditor.path,
  ], workingDirectory: workingDirectory.path);
  if (result.exitCode != 0) {
    throw StateError(
      'Completion auditor failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

Map<String, dynamic> _readReport(Directory root) {
  final report = File(
    '${root.path}/docs/production-readiness/public-release-completion-audit.json',
  );
  return jsonDecode(report.readAsStringSync()) as Map<String, dynamic>;
}

void _expectCheckStatus(
  Map<String, dynamic> report,
  String id,
  String expectedStatus,
) {
  final checks = (report['promptToArtifactChecklist'] as List)
      .cast<Map<String, dynamic>>();
  final check = checks.singleWhere((item) => item['id'] == id);
  _expect(
    check['status'] == expectedStatus,
    '$id should have status $expectedStatus, got ${check['status']}',
  );
}

void _expectStructuredBlockerInput(
  Map<String, dynamic> report,
  String id, {
  required String contains,
}) {
  final checks = (report['promptToArtifactChecklist'] as List)
      .cast<Map<String, dynamic>>();
  final check = checks.singleWhere((item) => item['id'] == id);
  _expect(
    check['requiredInput'].toString().contains(contains),
    '$id requiredInput should contain $contains, got ${check['requiredInput']}',
  );
  _expect(
    check['rerunCommands'] is List &&
        (check['rerunCommands'] as List).isNotEmpty,
    '$id should expose rerunCommands',
  );
  _expect(
    check['acceptanceCriteria'] is List &&
        (check['acceptanceCriteria'] as List).isNotEmpty,
    '$id should expose acceptanceCriteria',
  );
  _expect(
    check['expectedEvidence'] is List &&
        (check['expectedEvidence'] as List).isNotEmpty,
    '$id should expose expectedEvidence',
  );
}

void _expectSourceArtifacts(Map<String, dynamic> report) {
  final artifacts = (report['sourceArtifacts'] as List?) ?? const [];
  _expect(artifacts.length == 9, 'sourceArtifacts should list 9 artifacts');
  _expect(
    artifacts.any(
      (artifact) =>
          artifact is Map &&
          artifact['path'] ==
              'docs/production-readiness/public-release-gate.json' &&
          artifact['exists'] == true,
    ),
    'sourceArtifacts should include the public release gate artifact',
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
