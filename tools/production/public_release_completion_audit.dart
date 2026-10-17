import 'dart:convert';
import 'dart:io';

const _goalPath = 'goal.txt';
const _gatePath = 'docs/production-readiness/public-release-gate.json';
const _blockerInputsPath =
    'docs/production-readiness/public-release-blocker-inputs.json';
const _externalEvidencePath =
    'docs/production-readiness/public-release-external-evidence.json';
const _stagingPath = 'docs/production-readiness/release-staging-audit.json';
const _splitPlanPath = 'docs/production-readiness/release-pr-split-plan.json';
const _ownerMatrixPath =
    'docs/production-readiness/release-pr-owner-decision-matrix.json';
const _stagedBranchValidationPath =
    'docs/production-readiness/release-pr-staged-branch-validation.json';
const _checklistAuditPath =
    'docs/production-readiness/public-release-checklist-audit.json';
const _jsonOutputPath =
    'docs/production-readiness/public-release-completion-audit.json';
const _markdownOutputPath =
    'docs/production-readiness/public-release-completion-audit.md';

void main() async {
  final goalText = File(_goalPath).existsSync()
      ? File(_goalPath).readAsStringSync()
      : '';
  final gate = _readRequiredJson(_gatePath);
  final blockerInputs = _readOptionalJson(_blockerInputsPath);
  final externalEvidence = _readOptionalJson(_externalEvidencePath);
  final staging = _readOptionalJson(_stagingPath);
  final splitPlan = _readOptionalJson(_splitPlanPath);
  final ownerMatrix = _readOptionalJson(_ownerMatrixPath);
  final stagedBranchValidation = _readOptionalJson(_stagedBranchValidationPath);
  final checklistAudit = _readOptionalJson(_checklistAuditPath);

  final checks = _buildChecks(
    gate: gate,
    blockerInputs: blockerInputs,
    externalEvidence: externalEvidence,
    staging: staging,
    splitPlan: splitPlan,
    ownerMatrix: ownerMatrix,
    stagedBranchValidation: stagedBranchValidation,
    checklistAudit: checklistAudit,
  );
  final blocked = checks.where((check) => check.status != 'complete').toList();
  final ready = gate['ready'] == true && blocked.isEmpty;
  final decision = ready ? 'ACHIEVED' : 'NOT_ACHIEVED';
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'objectiveSource': _goalPath,
    'objectiveSummary':
        'Prepare Skotiq for public release with direct evidence for the P0 release gates in goal.txt.',
    'sourceArtifacts': _sourceArtifacts(
      gate: gate,
      blockerInputs: blockerInputs,
      externalEvidence: externalEvidence,
      staging: staging,
      splitPlan: splitPlan,
      ownerMatrix: ownerMatrix,
      stagedBranchValidation: stagedBranchValidation,
      checklistAudit: checklistAudit,
    ),
    'decision': decision,
    'gateDecision': gate['decision'],
    'ready': ready,
    'completeCount': checks.where((check) => check.status == 'complete').length,
    'blockedOrIncompleteCount': blocked.length,
    'promptToArtifactChecklist': checks.map((check) => check.toJson()).toList(),
    'goalSectionsObserved': _extractGoalSections(goalText),
    'completionDecision': decision,
    'completionDetail': ready
        ? 'All P0 requirements have direct evidence and the public-release gate is ready.'
        : 'One or more P0 requirements remain blocked or weakly verified.',
  };

  await File(
    _jsonOutputPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(
    _markdownOutputPath,
  ).writeAsString(_renderMarkdown(report: report, checks: checks));

  stdout.writeln('Public release completion audit complete.');
  stdout.writeln(
    'Decision: ${report['decision']}: ${report['completionDetail']}',
  );
  stdout.writeln('Complete P0 checks: ${report['completeCount']}');
  stdout.writeln(
    'Blocked/incomplete P0 checks: ${report['blockedOrIncompleteCount']}',
  );
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');
}

List<Map<String, Object?>> _sourceArtifacts({
  required Map<String, dynamic> gate,
  required Map<String, dynamic>? blockerInputs,
  required Map<String, dynamic>? externalEvidence,
  required Map<String, dynamic>? staging,
  required Map<String, dynamic>? splitPlan,
  required Map<String, dynamic>? ownerMatrix,
  required Map<String, dynamic>? stagedBranchValidation,
  required Map<String, dynamic>? checklistAudit,
}) => [
  _sourceArtifact(_goalPath, null),
  _sourceArtifact(_gatePath, gate),
  _sourceArtifact(_blockerInputsPath, blockerInputs),
  _sourceArtifact(_externalEvidencePath, externalEvidence),
  _sourceArtifact(_stagingPath, staging),
  _sourceArtifact(_splitPlanPath, splitPlan),
  _sourceArtifact(_ownerMatrixPath, ownerMatrix),
  _sourceArtifact(_stagedBranchValidationPath, stagedBranchValidation),
  _sourceArtifact(_checklistAuditPath, checklistAudit),
];

Map<String, Object?> _sourceArtifact(String path, Map<String, dynamic>? json) {
  final file = File(path);
  return {
    'path': path,
    'exists': file.existsSync(),
    'sizeBytes': file.existsSync() ? file.lengthSync() : 0,
    'fileModifiedAt': file.existsSync()
        ? file.lastModifiedSync().toUtc().toIso8601String()
        : null,
    'generatedAt': json?['generatedAt']?.toString(),
    'decision': json?['decision']?.toString(),
    'ready': json?['ready'],
    'entryCount': json?['entryCount'],
    'bucketCount': json?['bucketCount'],
    'passedCount': json?['passedCount'],
    'blockerCount': json?['blockerCount'],
    'checkCount': json?['checkCount'],
  };
}

List<_CompletionCheck> _buildChecks({
  required Map<String, dynamic> gate,
  required Map<String, dynamic>? blockerInputs,
  required Map<String, dynamic>? externalEvidence,
  required Map<String, dynamic>? staging,
  required Map<String, dynamic>? splitPlan,
  required Map<String, dynamic>? ownerMatrix,
  required Map<String, dynamic>? stagedBranchValidation,
  required Map<String, dynamic>? checklistAudit,
}) {
  final gateChecks = {
    for (final check in (gate['checks'] as List? ?? const []).whereType<Map>())
      check['id']?.toString() ?? 'unknown': check.cast<String, dynamic>(),
  };
  final blockers = {
    for (final blocker
        in (blockerInputs?['blockers'] as List? ?? const []).whereType<Map>())
      blocker['id']?.toString() ?? 'unknown': blocker.cast<String, dynamic>(),
  };

  final externalPassed =
      (externalEvidence?['passedCount'] as num?)?.toInt() ?? 0;
  final externalTotal = (externalEvidence?['checkCount'] as num?)?.toInt() ?? 0;

  return [
    _check(
      id: 'clean_release_branch_pr',
      requirement:
          'Create a clean release branch/PR from the dirty worktree so the final artifact is reviewable.',
      status: _gateStatus(gateChecks['release_staging']),
      evidence: [
        _gateEvidence(gateChecks['release_staging']),
        _pathIfExists(_stagingPath),
        _pathIfExists(_splitPlanPath),
        _pathIfExists(_ownerMatrixPath),
        _pathIfExists(_stagedBranchValidationPath),
        'docs/production-readiness/release-pr-pathspecs/*.txt',
      ],
      verification:
          'Gate check `release_staging` requires a non-main clean branch with no untracked release-critical entries.',
      requiredInput: _requiredInput(blockers, ['release_staging']),
      rerunCommands: _blockerStringList(blockers, [
        'release_staging',
      ], 'rerunCommands'),
      acceptanceCriteria: _blockerStringList(blockers, [
        'release_staging',
      ], 'acceptanceCriteria'),
      expectedEvidence: _blockerStringList(blockers, [
        'release_staging',
      ], 'expectedEvidence'),
      gap:
          'Current branch=${staging?['currentBranch']}; entryCount=${staging?['entryCount']}; untrackedReleaseCritical=${staging?['untrackedReleaseCriticalCount']}; stagedBranchValidationPassed=${stagedBranchValidation?['passed']}. ${_blockerInput(blockers, 'release_staging')}',
    ),
    _check(
      id: 'split_generated_binary_native',
      requirement:
          'Split generated/binary/native changes from Dart/UI changes where possible.',
      status: _splitPlanStatus(gateChecks['release_staging'], splitPlan),
      evidence: [
        _pathIfExists(_splitPlanPath),
        _pathIfExists(_ownerMatrixPath),
        _pathIfExists(_stagedBranchValidationPath),
        'docs/production-readiness/release-pr-pathspecs/*.txt',
      ],
      verification:
          'Split plan assigns dirty entries into generated, binary/evidence, native/bridge, core, UI, and other buckets with pathspec files; owner matrix separates must_ship, generated_only, binary_evidence, and defer_exclude; validator checks the staged index or branch diff against that matrix.',
      requiredInput: _requiredInput(blockers, ['release_staging']),
      rerunCommands: _blockerStringList(blockers, [
        'release_staging',
      ], 'rerunCommands'),
      acceptanceCriteria: _blockerStringList(blockers, [
        'release_staging',
      ], 'acceptanceCriteria'),
      expectedEvidence: _blockerStringList(blockers, [
        'release_staging',
      ], 'expectedEvidence'),
      gap:
          'Planning artifacts exist, but no final clean PR has staged or excluded those buckets yet. bucketCount=${splitPlan?['bucketCount']}; entryCount=${splitPlan?['entryCount']}; ownerMatrixPaths=${ownerMatrix?['entryCount']}; stagedBranchValidationPassed=${stagedBranchValidation?['passed']}.',
    ),
    _check(
      id: 'linux_release_build',
      requirement:
          'Do a Linux release build on an actual Linux environment, not inferred from Windows.',
      status: _gateStatus(gateChecks['linux_release_build']),
      evidence: [
        _gateEvidence(gateChecks['linux_release_build']),
        _pathIfExists(_externalEvidencePath),
        'docs/production-readiness/linux-release-build-evidence.json',
      ],
      verification:
          'Gate requires the external evidence validator to accept Linux build/package evidence.',
      requiredInput: _requiredInput(blockers, ['linux_release_build']),
      rerunCommands: _blockerStringList(blockers, [
        'linux_release_build',
      ], 'rerunCommands'),
      acceptanceCriteria: _blockerStringList(blockers, [
        'linux_release_build',
      ], 'acceptanceCriteria'),
      expectedEvidence: _blockerStringList(blockers, [
        'linux_release_build',
      ], 'expectedEvidence'),
      gap: _blockerInput(blockers, 'linux_release_build'),
    ),
    _check(
      id: 'full_hardware_smoke',
      requirement:
          'Run a full hardware smoke pass with real or simulator-backed camera, mount, focuser, filter wheel, rotator, guider, dome, weather, and safety devices.',
      status: _gateStatus(gateChecks['hardware_control_smoke']),
      evidence: [
        _gateEvidence(gateChecks['hardware_control_smoke']),
        _pathIfExists(_externalEvidencePath),
        'docs/production-readiness/full-hardware-control-smoke-evidence.json',
      ],
      verification:
          'Gate requires validated external full hardware/control smoke evidence covering all required device classes.',
      requiredInput: _requiredInput(blockers, ['hardware_control_smoke']),
      rerunCommands: _blockerStringList(blockers, [
        'hardware_control_smoke',
      ], 'rerunCommands'),
      acceptanceCriteria: _blockerStringList(blockers, [
        'hardware_control_smoke',
      ], 'acceptanceCriteria'),
      expectedEvidence: _blockerStringList(blockers, [
        'hardware_control_smoke',
      ], 'expectedEvidence'),
      gap: _blockerInput(blockers, 'hardware_control_smoke'),
    ),
    _check(
      id: 'older_profile_migration',
      requirement:
          'Verify upgrade/migration from an older Skotiq profile/database.',
      status: _gateStatus(gateChecks['manual_migration']),
      evidence: [
        _gateEvidence(gateChecks['manual_migration']),
        'packages/skotiq_core/test/fixtures/synthetic_old_profile_fixtures.dart',
        'packages/skotiq_core/test/services/database_migration_test.dart',
        _pathIfExists('docs/production-readiness/manual-migration-probe.json'),
      ],
      verification:
          'Manual migration probe must run against an older release-authentic database/profile and report migrationVerified=true. The checked-in v4.3.0 fixture must be generated by the tagged v4.3.0 database code, not hand-authored SQL.',
      requiredInput: _requiredInput(blockers, ['manual_migration']),
      rerunCommands: _blockerStringList(blockers, [
        'manual_migration',
      ], 'rerunCommands'),
      acceptanceCriteria: _blockerStringList(blockers, [
        'manual_migration',
      ], 'acceptanceCriteria'),
      expectedEvidence: _blockerStringList(blockers, [
        'manual_migration',
      ], 'expectedEvidence'),
      gap: _blockerInput(blockers, 'manual_migration'),
    ),
    _check(
      id: 'integrated_remote_headless',
      requirement:
          'Verify headless auth, LAN opt-in, dashboard, mobile remote client, and WebSocket reconnect behavior together.',
      status: _integratedRemoteStatus(gateChecks),
      evidence: [
        _gateEvidence(gateChecks['mobile_remote_smoke']),
        _gateEvidence(gateChecks['mobile_reconnect_smoke']),
        _gateEvidence(gateChecks['second_device_lan_firewall']),
        _gateEvidence(gateChecks['real_remote_control_actions']),
        _pathIfExists(_externalEvidencePath),
      ],
      verification:
          'Emulator/mobile and reconnect evidence pass, but second physical LAN/firewall and real remote-control action evidence are still required.',
      requiredInput: _requiredInput(blockers, [
        'second_device_lan_firewall',
        'real_remote_control_actions',
      ]),
      rerunCommands: _blockerStringList(blockers, [
        'second_device_lan_firewall',
        'real_remote_control_actions',
      ], 'rerunCommands'),
      acceptanceCriteria: _blockerStringList(blockers, [
        'second_device_lan_firewall',
        'real_remote_control_actions',
      ], 'acceptanceCriteria'),
      expectedEvidence: _blockerStringList(blockers, [
        'second_device_lan_firewall',
        'real_remote_control_actions',
      ], 'expectedEvidence'),
      gap:
          '${_blockerInput(blockers, 'second_device_lan_firewall')} ${_blockerInput(blockers, 'real_remote_control_actions')}',
    ),
    _check(
      id: 'release_checklist_known_unsupported',
      requirement:
          'Produce a release checklist with known unsupported-by-platform items clearly documented.',
      status: _gateStatus(gateChecks['final_checklist']),
      evidence: [
        _gateEvidence(gateChecks['final_checklist']),
        _pathIfExists(
          'docs/production-readiness/public-release-master-checklist.md',
        ),
        _pathIfExists(_checklistAuditPath),
        _pathIfExists('docs/known-limitations.md'),
        _pathIfExists('docs/supported-hardware-by-platform.md'),
        _pathIfExists(_externalEvidencePath),
      ],
      verification:
          'Final checklist gate requires checklist audit evidence with zero unchecked items, zero checked-without-evidence items, known limitations/support docs references, and validated final sign-off evidence.',
      requiredInput: _requiredInput(blockers, ['final_checklist']),
      rerunCommands: _blockerStringList(blockers, [
        'final_checklist',
      ], 'rerunCommands'),
      acceptanceCriteria: _blockerStringList(blockers, [
        'final_checklist',
      ], 'acceptanceCriteria'),
      expectedEvidence: _blockerStringList(blockers, [
        'final_checklist',
      ], 'expectedEvidence'),
      gap:
          '${_blockerInput(blockers, 'final_checklist')} Checklist audit unchecked=${checklistAudit?['uncheckedItemCount']}; checkedWithoutEvidence=${checklistAudit?['checkedWithoutEvidenceCount']}; knownLimitationsReferenced=${checklistAudit?['knownLimitationsReferenced']}; supportedHardwareByPlatformReferenced=${checklistAudit?['supportedHardwareByPlatformReferenced']}. External evidence checks passing=$externalPassed/$externalTotal.',
    ),
  ];
}

_CompletionCheck _check({
  required String id,
  required String requirement,
  required String status,
  required List<String> evidence,
  required String verification,
  required String requiredInput,
  required List<String> rerunCommands,
  required List<String> acceptanceCriteria,
  required List<String> expectedEvidence,
  required String gap,
}) {
  return _CompletionCheck(
    id: id,
    requirement: requirement,
    status: status,
    evidence: _normalizeEvidence(evidence),
    verification: verification,
    requiredInput: requiredInput.trim(),
    rerunCommands: _normalizeEvidence(rerunCommands),
    acceptanceCriteria: _normalizeEvidence(acceptanceCriteria),
    expectedEvidence: _normalizeEvidence(expectedEvidence),
    gap: gap.trim(),
  );
}

List<String> _normalizeEvidence(List<String> evidence) {
  final seen = <String>{};
  final normalized = <String>[];
  for (final item in evidence) {
    final parts = item.split(';');
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty || seen.contains(trimmed)) continue;
      seen.add(trimmed);
      normalized.add(trimmed);
    }
  }
  return normalized;
}

String _gateStatus(Map<String, dynamic>? gateCheck) {
  if (gateCheck == null) return 'blocked';
  return gateCheck['passed'] == true ? 'complete' : 'blocked';
}

String _integratedRemoteStatus(Map<String, Map<String, dynamic>> gateChecks) {
  final mobile = gateChecks['mobile_remote_smoke']?['passed'] == true;
  final reconnect = gateChecks['mobile_reconnect_smoke']?['passed'] == true;
  final secondDevice =
      gateChecks['second_device_lan_firewall']?['passed'] == true;
  final realControl =
      gateChecks['real_remote_control_actions']?['passed'] == true;
  return mobile && reconnect && secondDevice && realControl
      ? 'complete'
      : 'incomplete';
}

String _splitPlanStatus(
  Map<String, dynamic>? releaseStagingGateCheck,
  Map<String, dynamic>? splitPlan,
) {
  if (splitPlan == null) return 'blocked';
  if (releaseStagingGateCheck?['passed'] == true) return 'complete';
  return 'in_progress';
}

String _gateEvidence(Map<String, dynamic>? gateCheck) {
  if (gateCheck == null) return '';
  return gateCheck['evidence']?.toString() ?? '';
}

String _blockerInput(Map<String, Map<String, dynamic>> blockers, String id) {
  final blocker = blockers[id];
  if (blocker == null) return 'No blocker-input record found.';
  return 'Required input: ${blocker['requiredInput']}';
}

String _requiredInput(
  Map<String, Map<String, dynamic>> blockers,
  List<String> ids,
) {
  return ids
      .map((id) => blockers[id]?['requiredInput']?.toString() ?? '')
      .where((value) => value.trim().isNotEmpty)
      .join(' ');
}

List<String> _blockerStringList(
  Map<String, Map<String, dynamic>> blockers,
  List<String> ids,
  String field,
) {
  final values = <String>[];
  for (final id in ids) {
    final rawValues = blockers[id]?[field] as List? ?? const [];
    values.addAll(rawValues.map((value) => value.toString()));
  }
  return values;
}

String _pathIfExists(String path) => File(path).existsSync() ? path : '';

List<String> _extractGoalSections(String goalText) {
  return RegExp(r'^\*\*(.+?)\*\*', multiLine: true)
      .allMatches(goalText)
      .map((match) => match.group(1) ?? '')
      .where((section) => section.isNotEmpty)
      .toList();
}

Map<String, dynamic> _readRequiredJson(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing required artifact: $path');
    exit(1);
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic>? _readOptionalJson(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

String _renderMarkdown({
  required Map<String, Object?> report,
  required List<_CompletionCheck> checks,
}) {
  final buffer = StringBuffer()
    ..writeln('# Public Release Completion Audit')
    ..writeln()
    ..writeln('- Objective source: `$_goalPath`')
    ..writeln('- Objective summary: ${report['objectiveSummary']}')
    ..writeln('- Decision: `${report['decision']}`')
    ..writeln('- Gate decision: `${report['gateDecision']}`')
    ..writeln('- Completion detail: ${report['completionDetail']}')
    ..writeln('- Complete P0 checks: `${report['completeCount']}`')
    ..writeln(
      '- Blocked/incomplete P0 checks: `${report['blockedOrIncompleteCount']}`',
    )
    ..writeln()
    ..writeln(
      'This audit maps each P0 public-release requirement from `goal.txt` to concrete evidence. Proxy signals are not treated as completion when direct evidence is missing.',
    )
    ..writeln()
    ..writeln('## Source Artifacts')
    ..writeln()
    ..writeln('| Artifact | Generated | Decision | Count |')
    ..writeln('| --- | --- | --- | --- |');

  for (final artifact
      in (report['sourceArtifacts'] as List? ?? const []).whereType<Map>()) {
    final path = artifact['path']?.toString() ?? 'unknown';
    final generated =
        artifact['generatedAt']?.toString() ??
        artifact['fileModifiedAt']?.toString() ??
        'unknown';
    final decision =
        artifact['decision']?.toString() ??
        (artifact['ready'] == null ? '' : 'ready=${artifact['ready']}');
    final count =
        artifact['entryCount'] ??
        artifact['bucketCount'] ??
        artifact['passedCount'] ??
        artifact['checkCount'] ??
        '';
    buffer.writeln(
      '| `$path` | `${_escapeTable(generated)}` | `${_escapeTable(decision)}` | `$count` |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Prompt-To-Artifact Checklist')
    ..writeln()
    ..writeln('| Status | Requirement | Evidence | Gap |')
    ..writeln('| --- | --- | --- | --- |');

  for (final check in checks) {
    buffer.writeln(
      '| ${check.status} | ${_escapeTable(check.requirement)} | ${_escapeTable(check.evidence.join('; '))} | ${_escapeTable(check.gap)} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Details');

  for (final check in checks) {
    buffer
      ..writeln()
      ..writeln('### ${check.requirement}')
      ..writeln()
      ..writeln('- ID: `${check.id}`')
      ..writeln('- Status: `${check.status}`')
      ..writeln('- Verification rule: ${check.verification}')
      ..writeln('- Gap: ${check.gap}');

    if (check.requiredInput.isNotEmpty &&
        !check.gap.contains(check.requiredInput)) {
      buffer.writeln('- Required input: ${check.requiredInput}');
    }
    if (check.rerunCommands.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Rerun commands:');
      for (final command in check.rerunCommands) {
        buffer.writeln('- `$command`');
      }
    }
    if (check.acceptanceCriteria.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Acceptance criteria:');
      for (final criterion in check.acceptanceCriteria) {
        buffer.writeln('- $criterion');
      }
    }
    if (check.expectedEvidence.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Expected evidence:');
      for (final evidence in check.expectedEvidence) {
        buffer.writeln('- `$evidence`');
      }
    }

    buffer
      ..writeln()
      ..writeln('Evidence:');
    for (final evidence in check.evidence) {
      buffer.writeln('- `$evidence`');
    }
  }

  return buffer.toString();
}

String _escapeTable(String value) {
  return value.replaceAll('|', r'\|').replaceAll('\n', ' ');
}

class _CompletionCheck {
  final String id;
  final String requirement;
  final String status;
  final List<String> evidence;
  final String verification;
  final String requiredInput;
  final List<String> rerunCommands;
  final List<String> acceptanceCriteria;
  final List<String> expectedEvidence;
  final String gap;

  const _CompletionCheck({
    required this.id,
    required this.requirement,
    required this.status,
    required this.evidence,
    required this.verification,
    required this.requiredInput,
    required this.rerunCommands,
    required this.acceptanceCriteria,
    required this.expectedEvidence,
    required this.gap,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'requirement': requirement,
    'status': status,
    'evidence': evidence,
    'verification': verification,
    'requiredInput': requiredInput.isEmpty ? null : requiredInput,
    'rerunCommands': rerunCommands,
    'acceptanceCriteria': acceptanceCriteria,
    'expectedEvidence': expectedEvidence,
    'gap': gap,
  };
}
