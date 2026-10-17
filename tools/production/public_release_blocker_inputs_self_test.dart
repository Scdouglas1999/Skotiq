import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final auditor = File(
    '${repoRoot.path}/tools/production/public_release_blocker_inputs.dart',
  );
  if (!auditor.existsSync()) {
    throw StateError('Blocker input auditor not found: ${auditor.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_blocker_inputs_self_test_',
  );
  try {
    await _prepareWorkspace(temp);

    await _writeBlockedFixture(temp);
    await _runAuditor(auditor, temp);
    final blockedReport = _readReport(temp);
    _expect(
      blockedReport['decision'] == 'NOT_READY',
      'blocked fixture decision should be NOT_READY',
    );
    _expect(
      blockedReport['blockerCount'] == 8,
      'blocked fixture should emit 8 blockers',
    );
    for (final id in _requiredBlockerIds) {
      final blocker = _blockerById(blockedReport, id);
      _expectNonEmpty(blocker, 'requiredInput');
      _expectNonEmptyList(blocker, 'acceptanceCriteria');
      _expectNonEmptyList(blocker, 'rerunCommands');
      _expectNonEmptyList(blocker, 'expectedEvidence');
      _expectNonEmpty(blocker, 'currentGateDetail');
    }
    final staging = _blockerById(blockedReport, 'release_staging');
    _expect(
      staging['localStatus'].toString().contains('42 dirty entries'),
      'release staging localStatus should include dirty count',
    );
    final finalChecklist = _blockerById(blockedReport, 'final_checklist');
    _expect(
      finalChecklist['localStatus'].toString().contains('unchecked=284'),
      'final checklist localStatus should include unchecked count',
    );

    await _writeReadyFixture(temp);
    await _runAuditor(auditor, temp);
    final readyReport = _readReport(temp);
    _expect(
      readyReport['decision'] == 'READY',
      'ready fixture decision should be READY',
    );
    _expect(
      readyReport['blockerCount'] == 0,
      'ready fixture should emit no blockers',
    );

    stdout.writeln('Public release blocker inputs self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _prepareWorkspace(Directory root) async {
  await Directory(
    '${root.path}/docs/production-readiness',
  ).create(recursive: true);
}

Future<void> _writeBlockedFixture(Directory root) async {
  await _writeJson(root, 'docs/production-readiness/public-release-gate.json', {
    'decision': 'NOT_READY',
    'checks': [
      _gateCheck('windows_bundle', false),
      _gateCheck('release_staging', false),
      _gateCheck('linux_release_build', false),
      _gateCheck('hardware_control_smoke', false),
      _gateCheck('manual_migration', false),
      _gateCheck('second_device_lan_firewall', false),
      _gateCheck('real_remote_control_actions', false),
      _gateCheck('final_checklist', false),
      _gateCheck('production_analyzer', true),
    ],
  });
  await _writeJson(
    root,
    'docs/production-readiness/linux-environment-probe.json',
    {
      'linuxBuildEnvironmentAvailable': false,
      'wslUsable': false,
      'dockerUsable': false,
      'checks': [
        {
          'id': 'wsl_status',
          'requiredForLinuxBuild': true,
          'exitCode': 1,
          'stderr': 'WSL unavailable',
        },
        {'id': 'docker_version', 'exitCode': 1, 'stderr': 'Docker unavailable'},
      ],
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/hardware-availability-probe.json',
    {
      'missingRealOrSimulatorDeviceTypes': ['rotator', 'dome'],
      'missingNonSimulatorDeviceTypes': ['rotator', 'dome'],
      'deviceTypes': {
        'camera': {'deviceCount': 1, 'nonSimulatorCount': 1},
        'mount': {'deviceCount': 1, 'nonSimulatorCount': 0},
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/manual-migration-probe.json',
    {
      'artifactProvided': false,
      'migrationVerified': false,
      'blocker': 'fixture old database missing',
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-staging-audit.json',
    {
      'currentBranch': 'main',
      'entryCount': 42,
      'untrackedReleaseCriticalCount': 7,
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-pr-split-plan.json',
    {'bucketCount': 10, 'entryCount': 42},
  );
  await _writeJson(
    root,
    'docs/production-readiness/public-release-checklist-audit.json',
    {
      'totalItemCount': 284,
      'checkedItemCount': 0,
      'uncheckedItemCount': 284,
      'checkedWithoutEvidenceCount': 0,
      'knownLimitationsReferenced': true,
      'supportedHardwareByPlatformReferenced': true,
    },
  );
}

Future<void> _writeReadyFixture(Directory root) async {
  await _writeJson(root, 'docs/production-readiness/public-release-gate.json', {
    'decision': 'READY',
    'checks': [
      for (final id in [..._requiredBlockerIds, 'production_analyzer'])
        _gateCheck(id, true),
    ],
  });
}

Map<String, Object?> _gateCheck(String id, bool passed) => {
  'id': id,
  'label': id,
  'passed': passed,
  'evidence': 'docs/production-readiness/$id.json',
  'detail': passed ? 'fixture passed' : 'fixture blocked detail for $id',
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
      'Blocker input auditor failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

Map<String, dynamic> _readReport(Directory root) {
  final report = File(
    '${root.path}/docs/production-readiness/public-release-blocker-inputs.json',
  );
  return jsonDecode(report.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _blockerById(Map<String, dynamic> report, String id) {
  final blockers = (report['blockers'] as List).cast<Map<String, dynamic>>();
  return blockers.singleWhere((blocker) => blocker['id'] == id);
}

void _expectNonEmpty(Map<String, dynamic> value, String field) {
  _expect(
    value[field]?.toString().trim().isNotEmpty == true,
    '${value['id']} should have non-empty $field',
  );
}

void _expectNonEmptyList(Map<String, dynamic> value, String field) {
  _expect(
    value[field] is List && (value[field] as List).isNotEmpty,
    '${value['id']} should have non-empty $field',
  );
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

const _requiredBlockerIds = [
  'windows_bundle',
  'release_staging',
  'linux_release_build',
  'hardware_control_smoke',
  'manual_migration',
  'second_device_lan_firewall',
  'real_remote_control_actions',
  'final_checklist',
];
