import 'dart:convert';
import 'dart:io';

const _gatePath = 'docs/production-readiness/public-release-gate.json';
const _linuxPath = 'docs/production-readiness/linux-environment-probe.json';
const _hardwarePath =
    'docs/production-readiness/hardware-availability-probe.json';
const _manualMigrationPath =
    'docs/production-readiness/manual-migration-probe.json';
const _stagingPath = 'docs/production-readiness/release-staging-audit.json';
const _splitPlanPath = 'docs/production-readiness/release-pr-split-plan.json';
const _ownerMatrixPath =
    'docs/production-readiness/release-pr-owner-decision-matrix.json';
const _stagedBranchValidationPath =
    'docs/production-readiness/release-pr-staged-branch-validation.json';
const _checklistAuditPath =
    'docs/production-readiness/public-release-checklist-audit.json';
const _jsonOutputPath =
    'docs/production-readiness/public-release-blocker-inputs.json';
const _markdownOutputPath =
    'docs/production-readiness/public-release-blocker-inputs.md';

void main() async {
  final gate = _readJson(_gatePath);
  if (gate == null) {
    stderr.writeln('Missing public release gate artifact: $_gatePath');
    stderr.writeln(
      'Run: dart run melos run audit:public-release-gate --no-select',
    );
    exit(1);
  }

  final context = _EvidenceContext(
    gate: gate,
    linux: _readJson(_linuxPath),
    hardware: _readJson(_hardwarePath),
    manualMigration: _readJson(_manualMigrationPath),
    staging: _readJson(_stagingPath),
    splitPlan: _readJson(_splitPlanPath),
    ownerMatrix: _readJson(_ownerMatrixPath),
    stagedBranchValidation: _readJson(_stagedBranchValidationPath),
    checklistAudit: _readJson(_checklistAuditPath),
  );
  final gateChecks = (gate['checks'] as List? ?? const [])
      .whereType<Map>()
      .map((value) => value.cast<String, dynamic>())
      .toList();
  final blockers = <_BlockerInput>[];

  for (final check in gateChecks.where((check) => check['passed'] != true)) {
    blockers.add(_blockerInputFor(check, context));
  }

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'sourceGate': _gatePath,
    'decision': gate['decision'],
    'blockerCount': blockers.length,
    'blockers': blockers.map((blocker) => blocker.toJson()).toList(),
  };

  await File(
    _jsonOutputPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(
    _markdownOutputPath,
  ).writeAsString(_renderMarkdown(gate: gate, blockers: blockers));

  stdout.writeln('Public release blocker inputs complete.');
  stdout.writeln('Decision: ${gate['decision']}');
  stdout.writeln('Blockers: ${blockers.length}');
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');
}

_BlockerInput _blockerInputFor(
  Map<String, dynamic> check,
  _EvidenceContext context,
) {
  final id = check['id']?.toString() ?? 'unknown';
  final label = check['label']?.toString() ?? id;
  final detail = check['detail']?.toString() ?? '';

  switch (id) {
    case 'windows_bundle':
      return _BlockerInput(
        id: id,
        label: label,
        category: 'packaging',
        localStatus: detail,
        requiredInput:
            'A current Windows x64 release bundle built from the exact release candidate on a Windows runner.',
        acceptanceCriteria: [
          '`dart run melos run build:desktop:windows --no-select` succeeds on Windows for the release candidate.',
          'The bundle contains every required executable, DLL, Flutter asset, and embedded dashboard asset.',
          'The bundle audit reports bundleExists=true, missingRequiredFileCount=0, disallowedFileCount=0, and passed=true.',
        ],
        rerunCommands: [
          'dart run melos run build:desktop:windows --no-select',
          'dart run melos run audit:windows-bundle --no-select',
          'dart run melos run audit:public-release-gate --no-select',
        ],
        expectedEvidence: [
          'apps/desktop/build/windows/x64/runner/Release/skotiq_desktop.exe',
          'docs/production-readiness/windows-bundle-audit.json',
          'docs/production-readiness/windows-bundle-audit.md',
        ],
        currentGateDetail: detail,
      );
    case 'release_staging':
      final branch = context.staging?['currentBranch']?.toString() ?? 'unknown';
      final entryCount = _intValue(context.staging?['entryCount']);
      final untrackedCritical = _intValue(
        context.staging?['untrackedReleaseCriticalCount'],
      );
      final bucketCount = _intValue(context.splitPlan?['bucketCount']);
      final ownerGroups =
          context.ownerMatrix?['decisionGroups'] as Map<String, dynamic>?;
      final mustShipGroup = ownerGroups?['must_ship'] as Map?;
      final matrixPathCount = _intValue(mustShipGroup?['pathCount']);
      final validationPassed = context.stagedBranchValidation?['passed'];
      return _BlockerInput(
        id: id,
        label: label,
        category: 'process',
        localStatus:
            'Current branch is $branch with $entryCount dirty entries and $untrackedCritical untracked release-critical entries. Split plan has $bucketCount buckets. Owner matrix must_ship paths=$matrixPathCount. Latest staged-branch validation passed=$validationPassed.',
        requiredInput:
            'Owner decision on must ship, generated only, binary/evidence, and defer/exclude bucket lists, then a clean non-main release branch/PR validated against that matrix.',
        acceptanceCriteria: [
          'Work is on a non-main release branch.',
          '`dart run melos run audit:release-staging --no-select` reports entryCount=0 and untrackedReleaseCriticalCount=0 for the final PR workspace, or the final PR contains only intentionally staged release files with exclusions documented.',
          'The owner matrix lists every split-plan bucket under must_ship, generated_only, binary_evidence, or defer_exclude.',
          '`dart run melos run audit:release-pr-staged-branch --no-select -- --mode=index` or the branch-mode equivalent passes before PR creation.',
          'The PR description links the staged bucket pathspecs, uses the draft description for each bucket, and explains any excluded bucket.',
        ],
        rerunCommands: [
          'dart run melos run audit:release-staging --no-select',
          'dart run melos run audit:release-pr-plan --no-select',
          'dart run melos run audit:release-pr-owner-matrix --no-select',
          'dart run melos run audit:release-pr-staged-branch --no-select -- --mode=index',
          'dart run melos run audit:release-pr-staged-branch --no-select -- --mode=branch --base=main',
          'dart run melos run audit:public-release-gate --no-select',
        ],
        expectedEvidence: [
          'docs/production-readiness/release-staging-audit.json',
          'docs/production-readiness/release-pr-split-plan.json',
          'docs/production-readiness/release-pr-owner-decision-matrix.json',
          'docs/production-readiness/release-pr-owner-decision-matrix.md',
          'docs/production-readiness/release-pr-staged-branch-validation.json',
          'docs/production-readiness/release-pr-pathspecs/*.txt',
          'GitHub PR URL or local branch/review record',
        ],
        currentGateDetail: detail,
      );
    case 'linux_release_build':
      return _linuxBlocker(check, context);
    case 'hardware_control_smoke':
      return _hardwareBlocker(check, context);
    case 'manual_migration':
      return _manualMigrationBlocker(check, context);
    case 'second_device_lan_firewall':
      return _secondDeviceBlocker(check);
    case 'real_remote_control_actions':
      return _realControlBlocker(check, context);
    case 'final_checklist':
      return _finalChecklistBlocker(check, context);
    default:
      return _BlockerInput(
        id: id,
        label: label,
        category: 'unknown',
        localStatus: detail,
        requiredInput: 'Direct evidence that satisfies this gate check.',
        acceptanceCriteria: ['Gate check passes with direct evidence.'],
        rerunCommands: [
          'dart run melos run audit:public-release-gate --no-select',
        ],
        expectedEvidence: [check['evidence']?.toString() ?? 'unknown'],
        currentGateDetail: detail,
      );
  }
}

_BlockerInput _linuxBlocker(
  Map<String, dynamic> check,
  _EvidenceContext context,
) {
  final linux = context.linux;
  final checks = (linux?['checks'] as List? ?? const [])
      .whereType<Map>()
      .map((value) => value.cast<String, dynamic>())
      .toList();
  final failedRequired = checks
      .where(
        (item) =>
            item['requiredForLinuxBuild'] == true && item['exitCode'] != 0,
      )
      .map(
        (item) =>
            '${item['id']}: ${_firstNonEmpty([item['stderr']?.toString(), item['stdout']?.toString()])}',
      )
      .toList();
  final dockerFailure = checks
      .where((item) => item['id'] == 'docker_version' && item['exitCode'] != 0)
      .map(
        (item) => _firstNonEmpty([
          item['stderr']?.toString(),
          item['stdout']?.toString(),
        ]),
      )
      .firstOrNull;

  return _BlockerInput(
    id: check['id']?.toString() ?? 'linux_release_build',
    label: check['label']?.toString() ?? 'Linux release build/package evidence',
    category: 'packaging',
    localStatus:
        'linuxBuildEnvironmentAvailable=${linux?['linuxBuildEnvironmentAvailable']}; wslUsable=${linux?['wslUsable']}; dockerUsable=${linux?['dockerUsable']}. ${failedRequired.join(' ')} ${dockerFailure ?? ''}'
            .trim(),
    requiredInput:
        'A working Linux build environment, either repaired WSL Ubuntu, Docker Desktop Linux engine, or another Linux host/CI runner.',
    acceptanceCriteria: [
      '`dart run melos run build:desktop:linux --no-select` succeeds on Linux.',
      'Linux package/runtime artifact is recorded with path, size, hash, and native library/permission notes from the package metadata generator or CI workflow.',
      'Linux-launched headless/dashboard smoke evidence exists from that Linux artifact.',
    ],
    rerunCommands: [
      'dart run melos run audit:public-release-external-evidence --no-select',
      'dart run melos run audit:linux-environment --no-select',
      'dart run melos run build:desktop:linux --no-select',
      'dart run melos run audit:linux-release-package-metadata --no-select',
      'dart run melos run audit:public-release-gate --no-select',
    ],
    expectedEvidence: [
      'docs/production-readiness/linux-release-build-evidence.json',
      'docs/production-readiness/linux-release-package-metadata.json',
      'docs/production-readiness/external-evidence-templates/linux-release-build-evidence.template.json',
      'docs/production-readiness/public-release-external-evidence.json',
      'docs/production-readiness/linux-environment-probe.json',
      '.github/workflows/linux-release-build.yml workflow run and uploaded artifact metadata',
      'Linux build log',
      'Linux package artifact path/hash',
      'Linux runtime/headless smoke log',
    ],
    currentGateDetail: check['detail']?.toString() ?? '',
  );
}

_BlockerInput _hardwareBlocker(
  Map<String, dynamic> check,
  _EvidenceContext context,
) {
  final missingAny =
      (context.hardware?['missingRealOrSimulatorDeviceTypes'] as List? ??
              context.hardware?['missingDeviceTypes'] as List? ??
              const [])
          .map((value) => value.toString())
          .toList();
  final missingNonSimulator =
      (context.hardware?['missingNonSimulatorDeviceTypes'] as List? ?? const [])
          .map((value) => value.toString())
          .toList();
  final availableAny = <String>[];
  final availableNonSimulator = <String>[];
  final deviceTypes = context.hardware?['deviceTypes'] as Map<String, dynamic>?;
  if (deviceTypes != null) {
    for (final entry in deviceTypes.entries) {
      final data = entry.value as Map<String, dynamic>;
      if (_intValue(data['deviceCount']) > 0) {
        availableAny.add(entry.key);
      }
      if (_intValue(data['nonSimulatorCount']) > 0) {
        availableNonSimulator.add(entry.key);
      }
    }
  }

  return _BlockerInput(
    id: check['id']?.toString() ?? 'hardware_control_smoke',
    label: check['label']?.toString() ?? 'Full hardware/control smoke',
    category: 'functionality',
    localStatus:
        'Real-or-simulator classes available here: ${availableAny.join(', ')}. Missing real-or-simulator classes: ${missingAny.join(', ')}. Non-simulator classes available here: ${availableNonSimulator.join(', ')}. Missing non-simulator classes: ${missingNonSimulator.join(', ')}. Discovery is not command/control smoke.',
    requiredInput:
        'A rig, simulator-backed environment, or remote host that exposes camera, mount, focuser, filter wheel, rotator, guider, dome, weather, and safety monitor classes, plus permission to run safe control commands.',
    acceptanceCriteria: [
      'Every required device class is discoverable as real or simulator-backed for the smoke environment.',
      'Connect/disconnect is exercised for each required class.',
      'Safe read/status command is exercised for each required class.',
      'Safe control command is exercised where applicable, such as camera short exposure, focuser small move, filter position query/change, rotator angle query/change, guider status, dome status/open-close or simulator equivalent, weather read, and safety state read.',
      'The smoke log records device IDs, driver types, command results, and any intentionally skipped unsafe action.',
    ],
    rerunCommands: [
      'dart run melos run audit:public-release-external-evidence --no-select',
      'dart run melos run audit:hardware-availability --no-select',
      'dart run melos run audit:public-release-gate --no-select',
    ],
    expectedEvidence: [
      'docs/production-readiness/full-hardware-control-smoke-evidence.json',
      'docs/production-readiness/external-evidence-templates/full-hardware-control-smoke-evidence.template.json',
      'docs/production-readiness/public-release-external-evidence.json',
      'docs/production-readiness/hardware-availability-probe.json',
      'Full hardware/control smoke log with command results',
      'Screenshots or exported dashboard/device-state evidence if manually driven',
    ],
    currentGateDetail: check['detail']?.toString() ?? '',
  );
}

_BlockerInput _manualMigrationBlocker(
  Map<String, dynamic> check,
  _EvidenceContext context,
) {
  final migration = context.manualMigration;
  return _BlockerInput(
    id: check['id']?.toString() ?? 'manual_migration',
    label:
        check['label']?.toString() ??
        'Older release-authentic profile/database migration',
    category: 'data-integrity',
    localStatus:
        'artifactProvided=${migration?['artifactProvided']}; migrationVerified=${migration?['migrationVerified']}. ${migration?['blocker'] ?? ''}',
    requiredInput:
        'An older release-authentic Skotiq SQLite database/profile artifact that can be copied and migrated by the probe.',
    acceptanceCriteria: [
      'Probe runs against a temporary copy of an older release-authentic database/profile.',
      '`artifactProvided=true` and `migrationVerified=true` in `manual-migration-probe.json`.',
      'Report records source path, source size, source SHA256, original user_version, final user_version, current table set, and required default settings.',
      'Synthetic old-schema/profile migration regression tests pass without using real user data.',
    ],
    rerunCommands: [
      'cd packages/skotiq_core && flutter test test/services/database_migration_test.dart',
      r'$env:SKOTIQ_OLD_DATABASE="<path-to-old-skotiq.sqlite>"; dart run melos run audit:manual-migration --no-select',
      'dart run melos run audit:public-release-gate --no-select',
    ],
    expectedEvidence: [
      'packages/skotiq_core/test/fixtures/synthetic_old_profile_fixtures.dart',
      'packages/skotiq_core/test/services/database_migration_test.dart',
      'docs/production-readiness/manual-migration-probe.json',
      'docs/production-readiness/manual-migration-probe.md',
      'Path or secure reference to the source old database artifact',
    ],
    currentGateDetail: check['detail']?.toString() ?? '',
  );
}

_BlockerInput _secondDeviceBlocker(Map<String, dynamic> check) {
  return _BlockerInput(
    id: check['id']?.toString() ?? 'second_device_lan_firewall',
    label: check['label']?.toString() ?? 'Second-device LAN/firewall smoke',
    category: 'networking',
    localStatus:
        'Local non-loopback and Android emulator-host-alias smokes exist, but no second physical device/browser evidence exists.',
    requiredInput:
        'A second physical phone, tablet, or laptop on the same LAN, with the Windows firewall/router path used exactly as a real user would use it.',
    acceptanceCriteria: [
      'Packaged Windows headless server is reached from the second device over the LAN IP, not localhost or emulator alias.',
      'Dashboard loads with HTML/CSS/JS assets.',
      'Authenticated token flow succeeds and missing/wrong token fails.',
      'WebSocket connects and reconnect behavior is observed or logged.',
      'Evidence records server LAN URL, client device type, network path, timestamp, and screenshots/logs.',
    ],
    rerunCommands: [
      'dart run melos run audit:public-release-external-evidence --no-select',
      'dart run melos run smoke:headless-lan:windows',
      'dart run melos run audit:public-release-gate --no-select',
    ],
    expectedEvidence: [
      'docs/production-readiness/second-device-lan-firewall-smoke-evidence.json',
      'docs/production-readiness/external-evidence-templates/second-device-lan-firewall-smoke-evidence.template.json',
      'docs/production-readiness/public-release-external-evidence.json',
      'Second-device browser screenshot or mobile screenshot',
      'Server log showing second-device client IP',
      'Manual smoke notes with firewall/router path',
      'docs/production-readiness/public-release-audit-report.md update',
    ],
    currentGateDetail: check['detail']?.toString() ?? '',
  );
}

_BlockerInput _realControlBlocker(
  Map<String, dynamic> check,
  _EvidenceContext context,
) {
  final missingAny =
      (context.hardware?['missingRealOrSimulatorDeviceTypes'] as List? ??
              context.hardware?['missingDeviceTypes'] as List? ??
              const [])
          .map((value) => value.toString())
          .toList();
  return _BlockerInput(
    id: check['id']?.toString() ?? 'real_remote_control_actions',
    label: check['label']?.toString() ?? 'Real remote-control actions',
    category: 'functionality',
    localStatus:
        'No artifact proves remote control commands against real or simulator-backed devices. Current host is also missing ${missingAny.join(', ')} real-or-simulator classes.',
    requiredInput:
        'Permission and a safe test window to issue actual remote control actions from dashboard/mobile/headless APIs against real or simulator-backed devices.',
    acceptanceCriteria: [
      'Remote client sends at least one safe command per applicable device class.',
      'Server logs include request IDs, client key/token scope, action, route, and completion status for high-risk commands.',
      'Device state after each command is read back and recorded.',
      'Unsafe real-world commands are either performed in simulator mode or explicitly skipped with a safety reason.',
    ],
    rerunCommands: [
      'dart run melos run audit:public-release-external-evidence --no-select',
      'dart run melos run audit:hardware-availability --no-select',
      'dart run melos run audit:public-release-gate --no-select',
    ],
    expectedEvidence: [
      'docs/production-readiness/real-remote-control-actions-evidence.json',
      'docs/production-readiness/external-evidence-templates/real-remote-control-actions-evidence.template.json',
      'docs/production-readiness/public-release-external-evidence.json',
      'Remote-control smoke log with command/result pairs',
      'Dashboard/mobile screenshots showing connected state and command results',
      'Server audit log excerpt for high-risk commands',
    ],
    currentGateDetail: check['detail']?.toString() ?? '',
  );
}

_BlockerInput _finalChecklistBlocker(
  Map<String, dynamic> check,
  _EvidenceContext context,
) {
  final audit = context.checklistAudit;
  final unchecked = _intValue(audit?['uncheckedItemCount']);
  final checked = _intValue(audit?['checkedItemCount']);
  final total = _intValue(audit?['totalItemCount']);
  final checkedWithoutEvidence = _intValue(
    audit?['checkedWithoutEvidenceCount'],
  );
  final knownLimitationsReferenced =
      audit?['knownLimitationsReferenced'] == true;
  final supportedHardwareReferenced =
      audit?['supportedHardwareByPlatformReferenced'] == true;
  final localStatus = audit == null
      ? 'Checklist audit artifact is missing.'
      : 'Checklist items=$total checked=$checked unchecked=$unchecked checkedWithoutEvidence=$checkedWithoutEvidence knownLimitationsReferenced=$knownLimitationsReferenced supportedHardwareByPlatformReferenced=$supportedHardwareReferenced.';
  return _BlockerInput(
    id: check['id']?.toString() ?? 'final_checklist',
    label: check['label']?.toString() ?? 'Final release checklist/sign-off',
    category: 'process',
    localStatus: localStatus,
    requiredInput:
        'Reviewer sign-off evidence for every remaining checklist item, or explicit release-scope removal for items that cannot be satisfied.',
    acceptanceCriteria: [
      'Every completed checklist item has evidence notes.',
      'Every unchecked release-blocking item is resolved, hidden, or removed from scope.',
      'Known unsupported-by-platform items are referenced in the known limitations and supported hardware docs.',
      'Final ship/no-ship decision records date, reviewer, commit/hash, and known limitations.',
      '`audit:public-release-gate` reports `Decision: READY`.',
    ],
    rerunCommands: [
      'dart run melos run audit:public-release-external-evidence --no-select',
      'dart run melos run audit:public-release-checklist --no-select',
      'dart run melos run audit:public-release-gate --no-select',
    ],
    expectedEvidence: [
      'docs/production-readiness/final-release-signoff-evidence.json',
      'docs/production-readiness/external-evidence-templates/final-release-signoff-evidence.template.json',
      'docs/production-readiness/public-release-external-evidence.json',
      'docs/production-readiness/public-release-master-checklist.md',
      'docs/production-readiness/public-release-checklist-audit.json',
      'docs/production-readiness/public-release-gate.json',
      'Final release decision record',
    ],
    currentGateDetail: check['detail']?.toString() ?? '',
  );
}

String _renderMarkdown({
  required Map<String, dynamic> gate,
  required List<_BlockerInput> blockers,
}) {
  final buffer = StringBuffer()
    ..writeln('# Public Release Blocker Inputs')
    ..writeln()
    ..writeln('- Source gate: `$_gatePath`')
    ..writeln('- Gate decision: `${gate['decision']}`')
    ..writeln('- Open blockers: `${blockers.length}`')
    ..writeln()
    ..writeln(
      'This artifact lists the exact missing input or evidence needed to clear each current public-release blocker. It does not satisfy the blockers by itself.',
    )
    ..writeln()
    ..writeln('## Summary')
    ..writeln()
    ..writeln('| Blocker | Category | Required input |')
    ..writeln('| --- | --- | --- |');

  for (final blocker in blockers) {
    buffer.writeln(
      '| ${blocker.label} | ${blocker.category} | ${_escapeTable(blocker.requiredInput)} |',
    );
  }

  for (final blocker in blockers) {
    buffer
      ..writeln()
      ..writeln('## ${blocker.label}')
      ..writeln()
      ..writeln('- ID: `${blocker.id}`')
      ..writeln('- Category: `${blocker.category}`')
      ..writeln('- Current gate detail: ${blocker.currentGateDetail}')
      ..writeln('- Local status: ${blocker.localStatus}')
      ..writeln('- Required input: ${blocker.requiredInput}')
      ..writeln()
      ..writeln('Acceptance criteria:');
    for (final criterion in blocker.acceptanceCriteria) {
      buffer.writeln('- $criterion');
    }
    buffer
      ..writeln()
      ..writeln('Rerun commands:');
    for (final command in blocker.rerunCommands) {
      buffer.writeln('- `$command`');
    }
    buffer
      ..writeln()
      ..writeln('Expected evidence:');
    for (final evidence in blocker.expectedEvidence) {
      buffer.writeln('- `$evidence`');
    }
  }

  return buffer.toString();
}

Map<String, dynamic>? _readJson(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

int _intValue(Object? value) => (value as num?)?.toInt() ?? -1;

String _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return '';
}

String _escapeTable(String value) {
  return value.replaceAll('|', r'\|').replaceAll('\n', ' ');
}

class _EvidenceContext {
  final Map<String, dynamic> gate;
  final Map<String, dynamic>? linux;
  final Map<String, dynamic>? hardware;
  final Map<String, dynamic>? manualMigration;
  final Map<String, dynamic>? staging;
  final Map<String, dynamic>? splitPlan;
  final Map<String, dynamic>? ownerMatrix;
  final Map<String, dynamic>? stagedBranchValidation;
  final Map<String, dynamic>? checklistAudit;

  const _EvidenceContext({
    required this.gate,
    required this.linux,
    required this.hardware,
    required this.manualMigration,
    required this.staging,
    required this.splitPlan,
    required this.ownerMatrix,
    required this.stagedBranchValidation,
    required this.checklistAudit,
  });
}

class _BlockerInput {
  final String id;
  final String label;
  final String category;
  final String localStatus;
  final String requiredInput;
  final List<String> acceptanceCriteria;
  final List<String> rerunCommands;
  final List<String> expectedEvidence;
  final String currentGateDetail;

  const _BlockerInput({
    required this.id,
    required this.label,
    required this.category,
    required this.localStatus,
    required this.requiredInput,
    required this.acceptanceCriteria,
    required this.rerunCommands,
    required this.expectedEvidence,
    required this.currentGateDetail,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'category': category,
    'currentGateDetail': currentGateDetail,
    'localStatus': localStatus,
    'requiredInput': requiredInput,
    'acceptanceCriteria': acceptanceCriteria,
    'rerunCommands': rerunCommands,
    'expectedEvidence': expectedEvidence,
  };
}
