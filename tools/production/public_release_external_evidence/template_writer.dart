// Generates strict evidence templates without weakening verifier behavior.
part of '../public_release_external_evidence.dart';

Future<void> _writeTemplates() async {
  final directory = Directory(_templateDirectory);
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }

  final templates = {
    'linux-release-build-evidence.template.json': {
      'platform': 'linux',
      'metadataSchemaVersion': 2,
      'buildCommand': 'dart run melos run build:desktop:linux --no-select',
      'toolVersions': {
        'operatingSystem': 'linux',
        'dartVersion': 'replace with dart --version output',
        'flutterVersion': 'replace with flutter --version output',
        'rustcVersion': 'replace with rustc --version output',
      },
      'buildPassed': true,
      'packageArtifactPath': '/path/to/skotiq-linux-artifact',
      'packageSizeBytes': 1,
      'packageSha256':
          '0000000000000000000000000000000000000000000000000000000000000000',
      'packageSha256Path': '/path/to/skotiq-linux-artifact.sha256',
      'metadataPath':
          'docs/production-readiness/linux-release-package-metadata.json',
      'runtimeSmokePassed': true,
      'runtimeSmokeArtifact':
          'docs/production-readiness/linux-runtime-smoke.log',
      'runtimeSmokeChecks': [
        {
          'check': 'headless_process_started',
          'passed': true,
          'evidence': 'process PID and listening port recorded in smoke log',
        },
        {
          'check': 'api_info_ok',
          'passed': true,
          'evidence': '/api/info returned HTTP 200 with version metadata',
        },
        {
          'check': 'openapi_ok',
          'passed': true,
          'evidence': '/api/openapi.json returned HTTP 200',
        },
        {
          'check': 'dashboard_asset_ok',
          'passed': true,
          'evidence': 'dashboard HTML/JS/CSS assets returned HTTP 200',
        },
      ],
      'nativeLibraryNotes': [
        'replace with ldd/native shared library findings from the Linux artifact',
        'replace with runtime/user-installed vendor SDK library notes (official artifacts do not bundle vendor SDKs)',
      ],
      'linuxPermissionNotes': [
        'replace with udev rules and dialout/plugdev/video group checks from the smoke host',
        'replace with local or remote INDI server package/source and driver notes',
      ],
      'notes':
          'Replace placeholder values with actual Linux build evidence. The package artifact and runtime smoke log must exist when this verifier runs.',
    },
    'full-hardware-control-smoke-evidence.template.json': {
      'coveredDeviceTypes': _requiredDeviceTypes,
      'connectDisconnectPassed': true,
      'safeStatusReadsPassed': true,
      'safeControlActionsPassed': true,
      'smokeLogPath':
          'docs/production-readiness/full-hardware-control-smoke.log',
      'connectionResults': [
        {
          'deviceType': 'camera',
          'deviceId': 'example',
          'backingType': 'real',
          'connectPassed': true,
          'disconnectPassed': true,
          'statusReadback': 'recorded status after connect',
        },
      ],
      'commandResults': [
        {
          'deviceType': 'camera',
          'deviceId': 'example',
          'backingType': 'real',
          'command': 'short exposure',
          'stateReadback': 'recorded state after command',
          'passed': true,
        },
      ],
      'skippedUnsafeActions': [],
      'notes':
          'Use real or simulator-backed devices and record every command result. The smoke log path must exist when this verifier runs.',
    },
    'second-device-lan-firewall-smoke-evidence.template.json': {
      'usedPhysicalSecondDevice': true,
      'clientDevice': 'phone/tablet/laptop model',
      'clientIp': '192.168.1.50',
      'serverLanUrl': 'http://192.168.1.10:7624',
      'windowsFirewallRule': {
        'name': 'Skotiq Headless API',
        'profile': 'Private',
        'port': 7624,
        'action': 'Allow',
      },
      'networkPath': 'same trusted LAN; no guest Wi-Fi or VPN isolation',
      'dashboardLoaded': true,
      'authPositivePassed': true,
      'authNegativePassed': true,
      'websocketConnected': true,
      'websocketReconnectObserved': true,
      'evidenceArtifacts': [
        'docs/production-readiness/second-device-lan-screenshot.png',
      ],
      'notes':
          'Do not use localhost, 127.0.0.1, or Android emulator 10.0.2.2. Every evidence artifact path must exist when this verifier runs.',
    },
    'real-remote-control-actions-evidence.template.json': {
      'usedRealOrSimulatorBackedDevices': true,
      'remoteClientType': 'dashboard',
      'coveredDeviceTypes': ['mount'],
      'stateReadbackPassed': true,
      'auditLogPath': 'docs/production-readiness/real-control-audit.log',
      'commandResults': [
        {
          'deviceType': 'mount',
          'deviceId': 'example',
          'requestId': 'request id from the remote command/audit log',
          'command': 'safe status/control action',
          'passed': true,
          'stateReadback': 'recorded state after command',
        },
      ],
      'skippedUnsafeActions': [
        {
          'command': 'example unsafe command',
          'reason': 'skipped in real environment; simulator used instead',
        },
      ],
      'notes':
          'Record request IDs and post-command state readback. The audit log path must exist when this verifier runs.',
    },
    'final-release-signoff-evidence.template.json': {
      'reviewer': 'name',
      'date': DateTime.now().toUtc().toIso8601String().split('T').first,
      'commit': 'full git commit hash',
      'decision': 'ship',
      'checklistComplete': true,
      'noUnresolvedBlockers': true,
      'knownLimitationsReviewed': true,
      'releaseNotesReady': true,
      'releaseNotesPath': 'docs/release-notes.md',
      'notes':
          'Final sign-off is valid only after the master checklist audit is complete and release notes exist.',
    },
  };

  for (final entry in templates.entries) {
    await File(
      '$_templateDirectory/${entry.key}',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(entry.value));
  }
}

_EvidenceCheck _validateLinuxBuildEvidence() {
  const path = 'docs/production-readiness/linux-release-build-evidence.json';
  final data = _readEvidence(path);
  final issues = <String>[];
  if (data == null) {
    issues.add('Evidence file is missing or is not valid JSON.');
  } else {
    _requireStringEquals(data, issues, 'platform', 'linux');
    _requireIntAtLeast(data, issues, 'metadataSchemaVersion', 2);
    _requireStringContains(data, issues, 'buildCommand', 'build:desktop:linux');
    _requireToolVersions(data, issues, 'toolVersions');
    _requireBool(data, issues, 'buildPassed');
    _requireNonEmptyString(data, issues, 'packageArtifactPath');
    _requirePositiveInt(data, issues, 'packageSizeBytes');
    _requireSha256(data, issues, 'packageSha256');
    _requireNonEmptyString(data, issues, 'packageSha256Path');
    _requireNonEmptyString(data, issues, 'metadataPath');
    _requireBool(data, issues, 'runtimeSmokePassed');
    _requireNonEmptyString(data, issues, 'runtimeSmokeArtifact');
    _requireNonEmptyList(data, issues, 'runtimeSmokeChecks');
    _requireNonEmptyList(data, issues, 'nativeLibraryNotes');
    _requireNonEmptyList(data, issues, 'linuxPermissionNotes');
    _validateLinuxRuntimeSmokeChecks(data, issues);
    final packageArtifact = _requireExistingFile(
      data,
      issues,
      'packageArtifactPath',
      nonEmpty: true,
    );
    if (packageArtifact != null) {
      _requireFileSizeMatches(
        data,
        issues,
        'packageSizeBytes',
        packageArtifact,
      );
      _requireFileSha256Matches(data, issues, 'packageSha256', packageArtifact);
    }
    final packageSha256File = _requireExistingFile(
      data,
      issues,
      'packageSha256Path',
      nonEmpty: true,
    );
    if (packageSha256File != null) {
      _requireSha256SidecarMatches(
        data,
        issues,
        'packageSha256Path',
        packageSha256File,
      );
    }
    final metadataFile = _requireExistingFile(
      data,
      issues,
      'metadataPath',
      nonEmpty: true,
    );
    if (metadataFile != null) {
      _requireLinuxPackageMetadataMatches(data, issues, metadataFile);
    }
    _requireExistingFile(data, issues, 'runtimeSmokeArtifact', nonEmpty: true);
  }

  return _EvidenceCheck(
    id: 'linux_release_build',
    label: 'Linux release build/package evidence',
    evidencePath: path,
    templatePath:
        '$_templateDirectory/linux-release-build-evidence.template.json',
    passed: issues.isEmpty,
    issues: issues,
    requirements: [
      'Linux platform build command passed.',
      'Evidence uses metadata schema v2 or newer and records toolchain provenance.',
      'Package SHA256 sidecar exists and contains the package hash.',
      'Generated package metadata exists and matches the evidence hash/size.',
      'Package artifact path exists, size matches, and SHA256 matches.',
      'Runtime/headless smoke from the Linux artifact passed, covers required checks, and its log exists.',
      'Linux native shared library and permission notes are recorded.',
    ],
  );
}

_EvidenceCheck _validateHardwareControlEvidence() {
  const path =
      'docs/production-readiness/full-hardware-control-smoke-evidence.json';
  final data = _readEvidence(path);
  final issues = <String>[];
  if (data == null) {
    issues.add('Evidence file is missing or is not valid JSON.');
  } else {
    final covered = _stringList(data['coveredDeviceTypes']);
    final missing = _requiredDeviceTypes
        .where((deviceType) => !covered.contains(deviceType))
        .toList();
    if (missing.isNotEmpty) {
      issues.add('coveredDeviceTypes is missing: ${missing.join(', ')}.');
    }
    _requireBool(data, issues, 'connectDisconnectPassed');
    _requireBool(data, issues, 'safeStatusReadsPassed');
    _requireBool(data, issues, 'safeControlActionsPassed');
    _requireNonEmptyString(data, issues, 'smokeLogPath');
    _requireExistingFile(data, issues, 'smokeLogPath', nonEmpty: true);
    _requireNonEmptyList(data, issues, 'connectionResults');
    _validateConnectionResults(data, issues);
    _requireNonEmptyList(data, issues, 'commandResults');
    _validateCommandResults(
      data,
      issues,
      requireEveryDeviceType: true,
      requireStateReadback: true,
    );
  }

  return _EvidenceCheck(
    id: 'hardware_control_smoke',
    label: 'Full hardware/control smoke',
    evidencePath: path,
    templatePath:
        '$_templateDirectory/full-hardware-control-smoke-evidence.template.json',
    passed: issues.isEmpty,
    issues: issues,
    requirements: [
      'All required device classes are covered.',
      'Per-device connect/disconnect and status reads passed.',
      'Command results cover every required device type and the smoke log exists.',
    ],
  );
}

_EvidenceCheck _validateSecondDeviceEvidence() {
  const path =
      'docs/production-readiness/second-device-lan-firewall-smoke-evidence.json';
  final data = _readEvidence(path);
  final issues = <String>[];
  if (data == null) {
    issues.add('Evidence file is missing or is not valid JSON.');
  } else {
    _requireBool(data, issues, 'usedPhysicalSecondDevice');
    _requireNonEmptyString(data, issues, 'clientDevice');
    _requireNonEmptyString(data, issues, 'clientIp');
    _requireNonEmptyString(data, issues, 'serverLanUrl');
    final url = data['serverLanUrl']?.toString().toLowerCase() ?? '';
    if (url.contains('localhost') ||
        url.contains('127.0.0.1') ||
        url.contains('10.0.2.2')) {
      issues.add('serverLanUrl must not be localhost, 127.0.0.1, or 10.0.2.2.');
    }
    _requireWindowsFirewallRule(data, issues);
    _requireNonEmptyString(data, issues, 'networkPath');
    _requireBool(data, issues, 'dashboardLoaded');
    _requireBool(data, issues, 'authPositivePassed');
    _requireBool(data, issues, 'authNegativePassed');
    _requireBool(data, issues, 'websocketConnected');
    _requireBool(data, issues, 'websocketReconnectObserved');
    _requireNonEmptyList(data, issues, 'evidenceArtifacts');
    _requireExistingFilesInList(data, issues, 'evidenceArtifacts');
  }

  return _EvidenceCheck(
    id: 'second_device_lan_firewall',
    label: 'Second-device LAN/firewall smoke',
    evidencePath: path,
    templatePath:
        '$_templateDirectory/second-device-lan-firewall-smoke-evidence.template.json',
    passed: issues.isEmpty,
    issues: issues,
    requirements: [
      'A physical second device uses the real LAN URL.',
      'Evidence records client IP, Windows firewall rule/profile, and network path.',
      'Dashboard, auth success/failure, WebSocket connection, and reconnect are verified.',
      'Screenshot/log evidence artifact paths exist.',
    ],
  );
}

_EvidenceCheck _validateRealRemoteControlEvidence() {
  const path =
      'docs/production-readiness/real-remote-control-actions-evidence.json';
  final data = _readEvidence(path);
  final issues = <String>[];
  if (data == null) {
    issues.add('Evidence file is missing or is not valid JSON.');
  } else {
    _requireBool(data, issues, 'usedRealOrSimulatorBackedDevices');
    _requireRemoteClientType(data, issues);
    _requireCoveredDeviceTypes(data, issues);
    _requireBool(data, issues, 'stateReadbackPassed');
    _requireNonEmptyString(data, issues, 'auditLogPath');
    _requireExistingFile(data, issues, 'auditLogPath', nonEmpty: true);
    _requireNonEmptyList(data, issues, 'commandResults');
    _validateCommandResults(
      data,
      issues,
      requireStateReadback: true,
      requireRequestId: true,
    );
    _validateCoveredCommandScope(data, issues);
    _requireAuditLogContainsCommandRequestIds(data, issues);
  }

  return _EvidenceCheck(
    id: 'real_remote_control_actions',
    label: 'Real remote-control actions',
    evidencePath: path,
    templatePath:
        '$_templateDirectory/real-remote-control-actions-evidence.template.json',
    passed: issues.isEmpty,
    issues: issues,
    requirements: [
      'Remote client sends actual safe commands.',
      'Evidence declares the applicable remote-control device types in scope.',
      'Command results all pass and include device IDs.',
      'Post-command state readback and request IDs are recorded in the server audit log.',
    ],
  );
}

_EvidenceCheck _validateFinalSignoffEvidence() {
  const path = 'docs/production-readiness/final-release-signoff-evidence.json';
  final data = _readEvidence(path);
  final issues = <String>[];
  if (data == null) {
    issues.add('Evidence file is missing or is not valid JSON.');
  } else {
    _requireNonEmptyString(data, issues, 'reviewer');
    _requireNonEmptyString(data, issues, 'date');
    _requireNonEmptyString(data, issues, 'commit');
    _requireIsoDate(data, issues, 'date');
    _requireCurrentGitHead(data, issues, 'commit');
    _requireStringEquals(data, issues, 'decision', 'ship');
    _requireBool(data, issues, 'checklistComplete');
    _requireBool(data, issues, 'noUnresolvedBlockers');
    _requireBool(data, issues, 'knownLimitationsReviewed');
    _requireBool(data, issues, 'releaseNotesReady');
    _requireNonEmptyString(data, issues, 'releaseNotesPath');
    final releaseNotes = _requireExistingFile(
      data,
      issues,
      'releaseNotesPath',
      nonEmpty: true,
    );
    if (releaseNotes != null) {
      _requireReleaseNotesComplete(data, issues, releaseNotes);
    }
    _requireStaticFileExists(issues, _knownLimitationsPath, nonEmpty: true);
    _requireStaticFileExists(issues, _supportedHardwarePath, nonEmpty: true);
    _requireChecklistAuditComplete(issues);
    _requirePublicReleaseGateReady(issues);
  }

  return _EvidenceCheck(
    id: 'final_release_signoff',
    label: 'Final release checklist/sign-off',
    evidencePath: path,
    templatePath:
        '$_templateDirectory/final-release-signoff-evidence.template.json',
    passed: issues.isEmpty,
    issues: issues,
    requirements: [
      'Reviewer, date, and commit are recorded.',
      'Decision is ship.',
      'Commit is a full hash matching current git HEAD.',
      'Checklist audit has zero unchecked and zero checked-without-evidence items.',
      'Public release gate decision is READY with no blockers.',
      'Known limitations, supported hardware, and completed release notes artifacts exist.',
    ],
  );
}
