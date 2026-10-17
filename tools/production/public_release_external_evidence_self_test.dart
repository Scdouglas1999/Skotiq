import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final verifier = File(
    '${repoRoot.path}/tools/production/public_release_external_evidence.dart',
  );
  if (!verifier.existsSync()) {
    throw StateError('Verifier not found: ${verifier.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_external_evidence_self_test_',
  );
  try {
    await _prepareWorkspace(temp);

    await _runVerifier(verifier, temp);
    final missingReport = _readReport(temp);
    _expectCheckIssue(
      missingReport,
      'linux_release_build',
      'Evidence file is missing or is not valid JSON.',
    );

    await _writeStaleLinuxEvidence(temp);
    await _runVerifier(verifier, temp);
    final staleLinuxReport = _readReport(temp);
    _expectCheckIssue(
      staleLinuxReport,
      'linux_release_build',
      'metadataSchemaVersion must be at least 2.',
    );
    _expectCheckIssue(
      staleLinuxReport,
      'linux_release_build',
      'toolVersions.operatingSystem is required.',
    );
    _expectCheckIssue(
      staleLinuxReport,
      'linux_release_build',
      'packageSha256Path does not contain packageSha256.',
    );
    _expectCheckIssue(
      staleLinuxReport,
      'linux_release_build',
      'metadataPath is required.',
    );
    _expectCheckIssue(
      staleLinuxReport,
      'linux_release_build',
      'runtimeSmokeChecks must be a non-empty list.',
    );
    _expectCheckIssue(
      staleLinuxReport,
      'linux_release_build',
      'nativeLibraryNotes must be a non-empty list.',
    );
    _expectCheckIssue(
      staleLinuxReport,
      'linux_release_build',
      'linuxPermissionNotes must be a non-empty list.',
    );

    await _writePassingLinuxEvidence(temp);
    await _runVerifier(verifier, temp);
    final linuxReport = _readReport(temp);
    _expectCheckPassed(linuxReport, 'linux_release_build');

    await _writeLocalhostSecondDeviceEvidence(temp);
    await _runVerifier(verifier, temp);
    final lanReport = _readReport(temp);
    _expectCheckIssue(
      lanReport,
      'second_device_lan_firewall',
      'serverLanUrl must not be localhost, 127.0.0.1, or 10.0.2.2.',
    );

    await _writeMissingFirewallSecondDeviceEvidence(temp);
    await _runVerifier(verifier, temp);
    final firewallReport = _readReport(temp);
    _expectCheckIssue(
      firewallReport,
      'second_device_lan_firewall',
      'windowsFirewallRule must record rule name, profile, port, and action.',
    );

    await _writeMissingReconnectSecondDeviceEvidence(temp);
    await _runVerifier(verifier, temp);
    final reconnectReport = _readReport(temp);
    _expectCheckIssue(
      reconnectReport,
      'second_device_lan_firewall',
      'websocketReconnectObserved must be true.',
    );

    await _writePassingSecondDeviceEvidence(temp);
    await _runVerifier(verifier, temp);
    final passingLanReport = _readReport(temp);
    _expectCheckPassed(passingLanReport, 'second_device_lan_firewall');

    await _writeIncompleteHardwareEvidence(temp);
    await _runVerifier(verifier, temp);
    final incompleteHardwareReport = _readReport(temp);
    _expectCheckIssue(
      incompleteHardwareReport,
      'hardware_control_smoke',
      'commandResults[0].stateReadback is required.',
    );
    _expectCheckIssue(
      incompleteHardwareReport,
      'hardware_control_smoke',
      'commandResults[0].backingType is required.',
    );
    _expectCheckIssue(
      incompleteHardwareReport,
      'hardware_control_smoke',
      'connectionResults[0].statusReadback is required.',
    );
    _expectCheckIssue(
      incompleteHardwareReport,
      'hardware_control_smoke',
      'connectionResults is missing device types: mount, focuser, filterWheel, rotator, guider, dome, weather, safetyMonitor.',
    );
    _expectCheckIssue(
      incompleteHardwareReport,
      'hardware_control_smoke',
      'commandResults is missing device types: mount, focuser, filterWheel, rotator, guider, dome, weather, safetyMonitor.',
    );

    await _writeInvalidHardwareEvidence(temp);
    await _runVerifier(verifier, temp);
    final invalidHardwareReport = _readReport(temp);
    _expectCheckIssue(
      invalidHardwareReport,
      'hardware_control_smoke',
      'commandResults[0].deviceType must be one of: camera, mount, focuser, filterWheel, rotator, guider, dome, weather, safetyMonitor.',
    );
    _expectCheckIssue(
      invalidHardwareReport,
      'hardware_control_smoke',
      'commandResults[0].backingType must be `real` or `simulator`.',
    );

    await _writePassingHardwareEvidence(temp);
    await _runVerifier(verifier, temp);
    final hardwareReport = _readReport(temp);
    _expectCheckPassed(hardwareReport, 'hardware_control_smoke');

    await _writeIncompleteRemoteControlEvidence(temp);
    await _runVerifier(verifier, temp);
    final incompleteRemoteReport = _readReport(temp);
    _expectCheckIssue(
      incompleteRemoteReport,
      'real_remote_control_actions',
      'commandResults[0].stateReadback is required.',
    );
    _expectCheckIssue(
      incompleteRemoteReport,
      'real_remote_control_actions',
      'commandResults[0].requestId is required.',
    );

    await _writeInvalidRemoteClientEvidence(temp);
    await _runVerifier(verifier, temp);
    final invalidRemoteClientReport = _readReport(temp);
    _expectCheckIssue(
      invalidRemoteClientReport,
      'real_remote_control_actions',
      'remoteClientType must be one of: dashboard, mobile, headless-api.',
    );

    await _writeRemoteControlEvidenceWithMissingCoveredDevice(temp);
    await _runVerifier(verifier, temp);
    final missingCoveredDeviceReport = _readReport(temp);
    _expectCheckIssue(
      missingCoveredDeviceReport,
      'real_remote_control_actions',
      'commandResults is missing coveredDeviceTypes: focuser.',
    );

    await _writeRemoteControlEvidenceWithMissingAuditRequestId(temp);
    await _runVerifier(verifier, temp);
    final missingRequestReport = _readReport(temp);
    _expectCheckIssue(
      missingRequestReport,
      'real_remote_control_actions',
      'auditLogPath does not contain commandResults[0].requestId req-remote-1.',
    );

    await _writePassingRemoteControlEvidence(temp);
    await _runVerifier(verifier, temp);
    final remoteReport = _readReport(temp);
    _expectCheckPassed(remoteReport, 'real_remote_control_actions');

    await _prepareGitRepo(temp);
    await _writeTemplateFinalSignoffEvidence(temp);
    await _runVerifier(verifier, temp);
    final templateSignoffReport = _readReport(temp);
    _expectCheckIssue(
      templateSignoffReport,
      'final_release_signoff',
      'Checklist audit has uncheckedItemCount=1.',
    );
    _expectCheckIssue(
      templateSignoffReport,
      'final_release_signoff',
      'Public release gate must be READY with blockerCount=0; decision=NOT_READY ready=false blockerCount=1.',
    );
    _expectCheckIssue(
      templateSignoffReport,
      'final_release_signoff',
      'releaseNotesPath must not point to the release notes template.',
    );

    await _writePassingFinalSignoffEvidence(temp);
    await _runVerifier(verifier, temp);
    final finalSignoffReport = _readReport(temp);
    _expectCheckPassed(finalSignoffReport, 'final_release_signoff');

    stdout.writeln('External evidence verifier self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _prepareWorkspace(Directory root) async {
  await Directory(
    '${root.path}/docs/production-readiness',
  ).create(recursive: true);
  await File(
    '${root.path}/docs/production-readiness/public-release-checklist-audit.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'uncheckedItemCount': 1,
      'checkedWithoutEvidenceCount': 0,
      'knownLimitationsReferenced': true,
      'supportedHardwareByPlatformReferenced': true,
    }),
  );
  await File('${root.path}/docs/known-limitations.md')
      .create(recursive: true)
      .then((file) => file.writeAsString('# Known Limitations\n'));
  await File(
    '${root.path}/docs/supported-hardware-by-platform.md',
  ).writeAsString('# Supported Hardware By Platform\n');
  await File(
    '${root.path}/docs/release-notes-template.md',
  ).writeAsString('# Skotiq Release Notes Template\n');
  await File(
    '${root.path}/docs/production-readiness/public-release-gate.json',
  ).writeAsString(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'decision': 'NOT_READY', 'ready': false, 'blockerCount': 1}),
  );
}

Future<void> _writeStaleLinuxEvidence(Directory root) async {
  final artifact = File('${root.path}/skotiq-linux.tar.gz');
  await artifact.writeAsString('linux artifact bytes\n');
  final sidecar = File('${artifact.path}.sha256');
  await sidecar.writeAsString('not-the-real-hash  skotiq-linux.tar.gz\n');
  final smoke = File(
    '${root.path}/docs/production-readiness/linux-runtime-smoke.log',
  );
  await smoke.writeAsString('runtime smoke passed\n');
  final sha = _sha256(artifact);
  if (sha == null) {
    throw StateError('Could not compute SHA256 for ${artifact.path}');
  }

  await File(
    '${root.path}/docs/production-readiness/linux-release-build-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'platform': 'linux',
      'metadataSchemaVersion': 1,
      'buildCommand': 'dart run melos run build:desktop:linux --no-select',
      'toolVersions': {'dartVersion': 'Dart VM fixture'},
      'buildPassed': true,
      'packageArtifactPath': 'skotiq-linux.tar.gz',
      'packageSizeBytes': 1,
      'packageSha256':
          '0000000000000000000000000000000000000000000000000000000000000000',
      'packageSha256Path': sidecar.path,
      'runtimeSmokePassed': true,
      'runtimeSmokeArtifact':
          'docs/production-readiness/linux-runtime-smoke.log',
    }),
  );
}

Future<void> _writePassingLinuxEvidence(Directory root) async {
  final artifact = File('${root.path}/skotiq-linux.tar.gz');
  await artifact.writeAsString('linux artifact bytes\n');
  final smoke = File(
    '${root.path}/docs/production-readiness/linux-runtime-smoke.log',
  );
  await smoke.writeAsString('runtime smoke passed\n');
  final sha = _sha256(artifact);
  if (sha == null) {
    throw StateError('Could not compute SHA256 for ${artifact.path}');
  }
  final sidecar = File('${artifact.path}.sha256');
  await sidecar.writeAsString('$sha  skotiq-linux.tar.gz\n');
  final metadata = File(
    '${root.path}/docs/production-readiness/linux-release-package-metadata.json',
  );
  await metadata.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'metadataSchemaVersion': 2,
      'platform': 'linux',
      'toolVersions': {
        'operatingSystem': 'linux',
        'dartVersion': 'Dart VM fixture',
      },
      'artifactPath': 'skotiq-linux.tar.gz',
      'artifactSizeBytes': 0,
      'artifactSha256': '',
      'fileCount': 1,
      'nativeLibraryNotes': ['ldd fixture note'],
      'linuxPermissionNotes': ['udev dialout fixture note'],
    }),
  );
  final metadataJson =
      jsonDecode(metadata.readAsStringSync()) as Map<String, dynamic>;
  metadataJson['artifactSizeBytes'] = artifact.lengthSync();
  metadataJson['artifactSha256'] = sha;
  await metadata.writeAsString(
    const JsonEncoder.withIndent('  ').convert(metadataJson),
  );

  await File(
    '${root.path}/docs/production-readiness/linux-release-build-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'platform': 'linux',
      'metadataSchemaVersion': 2,
      'buildCommand': 'dart run melos run build:desktop:linux --no-select',
      'toolVersions': {
        'operatingSystem': 'linux',
        'dartVersion': 'Dart VM fixture',
        'flutterVersion': 'Flutter fixture',
        'rustcVersion': 'rustc fixture',
      },
      'buildPassed': true,
      'packageArtifactPath': artifact.path,
      'packageSizeBytes': artifact.lengthSync(),
      'packageSha256': sha,
      'packageSha256Path': sidecar.path,
      'metadataPath': metadata.path,
      'runtimeSmokePassed': true,
      'runtimeSmokeArtifact': smoke.path,
      'runtimeSmokeChecks': _passingLinuxRuntimeSmokeChecks(),
      'nativeLibraryNotes': ['ldd fixture note'],
      'linuxPermissionNotes': ['udev dialout fixture note'],
    }),
  );
}

Future<void> _writeLocalhostSecondDeviceEvidence(Directory root) async {
  final screenshot = File(
    '${root.path}/docs/production-readiness/second-device-lan-screenshot.png',
  );
  await screenshot.writeAsBytes([1, 2, 3]);
  await File(
    '${root.path}/docs/production-readiness/second-device-lan-firewall-smoke-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedPhysicalSecondDevice': true,
      'clientDevice': 'test laptop',
      'clientIp': '192.168.1.55',
      'serverLanUrl': 'http://localhost:8080',
      'windowsFirewallRule': {
        'name': 'Skotiq Headless API',
        'profile': 'Private',
        'port': 7624,
        'action': 'Allow',
      },
      'networkPath': 'same trusted LAN',
      'dashboardLoaded': true,
      'authPositivePassed': true,
      'authNegativePassed': true,
      'websocketConnected': true,
      'websocketReconnectObserved': true,
      'evidenceArtifacts': [
        'docs/production-readiness/second-device-lan-screenshot.png',
      ],
    }),
  );
}

Future<void> _writeMissingFirewallSecondDeviceEvidence(Directory root) async {
  final screenshot = File(
    '${root.path}/docs/production-readiness/second-device-lan-screenshot.png',
  );
  await screenshot.writeAsBytes([1, 2, 3]);
  await File(
    '${root.path}/docs/production-readiness/second-device-lan-firewall-smoke-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedPhysicalSecondDevice': true,
      'clientDevice': 'test laptop',
      'clientIp': '192.168.1.55',
      'serverLanUrl': 'http://192.168.1.20:7624',
      'networkPath': 'same trusted LAN',
      'dashboardLoaded': true,
      'authPositivePassed': true,
      'authNegativePassed': true,
      'websocketConnected': true,
      'websocketReconnectObserved': true,
      'evidenceArtifacts': [
        'docs/production-readiness/second-device-lan-screenshot.png',
      ],
    }),
  );
}

Future<void> _writePassingSecondDeviceEvidence(Directory root) async {
  final screenshot = File(
    '${root.path}/docs/production-readiness/second-device-lan-screenshot.png',
  );
  await screenshot.writeAsBytes([1, 2, 3]);
  await File(
    '${root.path}/docs/production-readiness/second-device-lan-firewall-smoke-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedPhysicalSecondDevice': true,
      'clientDevice': 'test laptop',
      'clientIp': '192.168.1.55',
      'serverLanUrl': 'http://192.168.1.20:7624',
      'windowsFirewallRule': {
        'name': 'Skotiq Headless API',
        'profile': 'Private',
        'port': 7624,
        'action': 'Allow',
      },
      'networkPath': 'same trusted LAN',
      'dashboardLoaded': true,
      'authPositivePassed': true,
      'authNegativePassed': true,
      'websocketConnected': true,
      'websocketReconnectObserved': true,
      'evidenceArtifacts': [
        'docs/production-readiness/second-device-lan-screenshot.png',
      ],
    }),
  );
}

Future<void> _writeMissingReconnectSecondDeviceEvidence(Directory root) async {
  final screenshot = File(
    '${root.path}/docs/production-readiness/second-device-lan-screenshot.png',
  );
  await screenshot.writeAsBytes([1, 2, 3]);
  await File(
    '${root.path}/docs/production-readiness/second-device-lan-firewall-smoke-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedPhysicalSecondDevice': true,
      'clientDevice': 'test laptop',
      'clientIp': '192.168.1.55',
      'serverLanUrl': 'http://192.168.1.20:7624',
      'windowsFirewallRule': {
        'name': 'Skotiq Headless API',
        'profile': 'Private',
        'port': 7624,
        'action': 'Allow',
      },
      'networkPath': 'same trusted LAN',
      'dashboardLoaded': true,
      'authPositivePassed': true,
      'authNegativePassed': true,
      'websocketConnected': true,
      'evidenceArtifacts': [
        'docs/production-readiness/second-device-lan-screenshot.png',
      ],
    }),
  );
}

Future<void> _writeIncompleteHardwareEvidence(Directory root) async {
  final smokeLog = File(
    '${root.path}/docs/production-readiness/full-hardware-control-smoke.log',
  );
  await smokeLog.writeAsString('hardware smoke started\n');
  await File(
    '${root.path}/docs/production-readiness/full-hardware-control-smoke-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'coveredDeviceTypes': _requiredDeviceTypes,
      'connectDisconnectPassed': true,
      'safeStatusReadsPassed': true,
      'safeControlActionsPassed': true,
      'smokeLogPath':
          'docs/production-readiness/full-hardware-control-smoke.log',
      'connectionResults': [
        {
          'deviceType': 'camera',
          'deviceId': 'camera-sim',
          'connectPassed': true,
          'disconnectPassed': true,
        },
      ],
      'commandResults': [
        {
          'deviceType': 'camera',
          'deviceId': 'camera-sim',
          'command': 'short exposure',
          'passed': true,
        },
      ],
    }),
  );
}

Future<void> _writeInvalidHardwareEvidence(Directory root) async {
  final smokeLog = File(
    '${root.path}/docs/production-readiness/full-hardware-control-smoke.log',
  );
  await smokeLog.writeAsString('hardware smoke invalid\n');
  await File(
    '${root.path}/docs/production-readiness/full-hardware-control-smoke-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'coveredDeviceTypes': _requiredDeviceTypes,
      'connectDisconnectPassed': true,
      'safeStatusReadsPassed': true,
      'safeControlActionsPassed': true,
      'smokeLogPath':
          'docs/production-readiness/full-hardware-control-smoke.log',
      'connectionResults': _passingConnectionResults(),
      'commandResults': [
        {
          'deviceType': 'placeholderDevice',
          'deviceId': 'placeholder',
          'backingType': 'real-or-simulator',
          'command': 'placeholder command',
          'stateReadback': 'placeholder state',
          'passed': true,
        },
      ],
    }),
  );
}

Future<void> _writePassingHardwareEvidence(Directory root) async {
  final smokeLog = File(
    '${root.path}/docs/production-readiness/full-hardware-control-smoke.log',
  );
  await smokeLog.writeAsString('hardware smoke passed\n');
  await File(
    '${root.path}/docs/production-readiness/full-hardware-control-smoke-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'coveredDeviceTypes': _requiredDeviceTypes,
      'connectDisconnectPassed': true,
      'safeStatusReadsPassed': true,
      'safeControlActionsPassed': true,
      'smokeLogPath':
          'docs/production-readiness/full-hardware-control-smoke.log',
      'connectionResults': _passingConnectionResults(),
      'commandResults': [
        for (final deviceType in _requiredDeviceTypes)
          {
            'deviceType': deviceType,
            'deviceId': '$deviceType-sim',
            'backingType': 'simulator',
            'command': 'safe $deviceType status/control smoke',
            'stateReadback': '$deviceType state verified',
            'passed': true,
          },
      ],
    }),
  );
}

Future<void> _writeIncompleteRemoteControlEvidence(Directory root) async {
  final auditLog = File(
    '${root.path}/docs/production-readiness/real-control-audit.log',
  );
  await auditLog.writeAsString('remote command accepted\n');
  await File(
    '${root.path}/docs/production-readiness/real-remote-control-actions-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedRealOrSimulatorBackedDevices': true,
      'remoteClientType': 'dashboard',
      'coveredDeviceTypes': ['mount'],
      'stateReadbackPassed': true,
      'auditLogPath': 'docs/production-readiness/real-control-audit.log',
      'commandResults': [
        {
          'deviceType': 'mount',
          'deviceId': 'mount-sim',
          'command': 'safe park status',
          'passed': true,
        },
      ],
    }),
  );
}

Future<void> _writeInvalidRemoteClientEvidence(Directory root) async {
  final auditLog = File(
    '${root.path}/docs/production-readiness/real-control-audit.log',
  );
  await auditLog.writeAsString(
    'requestId=req-remote-1 remote command and readback passed\n',
  );
  await File(
    '${root.path}/docs/production-readiness/real-remote-control-actions-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedRealOrSimulatorBackedDevices': true,
      'remoteClientType': 'browser-ish',
      'coveredDeviceTypes': ['mount'],
      'stateReadbackPassed': true,
      'auditLogPath': 'docs/production-readiness/real-control-audit.log',
      'commandResults': [
        {
          'deviceType': 'mount',
          'deviceId': 'mount-sim',
          'requestId': 'req-remote-1',
          'command': 'safe park status',
          'passed': true,
          'stateReadback': 'mount remained safe',
        },
      ],
    }),
  );
}

Future<void> _writeRemoteControlEvidenceWithMissingCoveredDevice(
  Directory root,
) async {
  final auditLog = File(
    '${root.path}/docs/production-readiness/real-control-audit.log',
  );
  await auditLog.writeAsString(
    'requestId=req-remote-1 remote command and readback passed\n',
  );
  await File(
    '${root.path}/docs/production-readiness/real-remote-control-actions-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedRealOrSimulatorBackedDevices': true,
      'remoteClientType': 'dashboard',
      'coveredDeviceTypes': ['mount', 'focuser'],
      'stateReadbackPassed': true,
      'auditLogPath': 'docs/production-readiness/real-control-audit.log',
      'commandResults': [
        {
          'deviceType': 'mount',
          'deviceId': 'mount-sim',
          'requestId': 'req-remote-1',
          'command': 'safe park status',
          'passed': true,
          'stateReadback': 'mount remained safe',
        },
      ],
    }),
  );
}

Future<void> _writePassingRemoteControlEvidence(Directory root) async {
  final auditLog = File(
    '${root.path}/docs/production-readiness/real-control-audit.log',
  );
  await auditLog.writeAsString(
    'requestId=req-remote-1 remote command and readback passed\n',
  );
  await File(
    '${root.path}/docs/production-readiness/real-remote-control-actions-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedRealOrSimulatorBackedDevices': true,
      'remoteClientType': 'dashboard',
      'coveredDeviceTypes': ['mount'],
      'stateReadbackPassed': true,
      'auditLogPath': 'docs/production-readiness/real-control-audit.log',
      'commandResults': [
        {
          'deviceType': 'mount',
          'deviceId': 'mount-sim',
          'requestId': 'req-remote-1',
          'command': 'safe park status',
          'passed': true,
          'stateReadback': 'mount remained safe',
        },
      ],
    }),
  );
}

Future<void> _writeRemoteControlEvidenceWithMissingAuditRequestId(
  Directory root,
) async {
  final auditLog = File(
    '${root.path}/docs/production-readiness/real-control-audit.log',
  );
  await auditLog.writeAsString('remote command and readback passed\n');
  await File(
    '${root.path}/docs/production-readiness/real-remote-control-actions-evidence.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'usedRealOrSimulatorBackedDevices': true,
      'remoteClientType': 'dashboard',
      'coveredDeviceTypes': ['mount'],
      'stateReadbackPassed': true,
      'auditLogPath': 'docs/production-readiness/real-control-audit.log',
      'commandResults': [
        {
          'deviceType': 'mount',
          'deviceId': 'mount-sim',
          'requestId': 'req-remote-1',
          'command': 'safe park status',
          'passed': true,
          'stateReadback': 'mount remained safe',
        },
      ],
    }),
  );
}

Future<void> _prepareGitRepo(Directory root) async {
  await _runGit(root, ['init']);
  await _runGit(root, ['config', 'user.email', 'self-test@example.invalid']);
  await _runGit(root, ['config', 'user.name', 'Skotiq Self Test']);
  await _runGit(root, ['add', '.']);
  await _runGit(root, ['commit', '-m', 'self-test fixture']);
}

Future<void> _writeTemplateFinalSignoffEvidence(Directory root) async {
  final head = _gitHead(root);
  await File(
    '${root.path}/docs/production-readiness/final-release-signoff-evidence.json',
  ).writeAsString(
    JsonEncoder.withIndent('  ').convert({
      'reviewer': 'Release Owner',
      'date': '2026-05-05',
      'commit': head,
      'decision': 'ship',
      'checklistComplete': true,
      'noUnresolvedBlockers': true,
      'knownLimitationsReviewed': true,
      'releaseNotesReady': true,
      'releaseNotesPath': 'docs/release-notes-template.md',
    }),
  );
}

Future<void> _writePassingFinalSignoffEvidence(Directory root) async {
  await File(
    '${root.path}/docs/production-readiness/public-release-checklist-audit.json',
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'uncheckedItemCount': 0,
      'checkedWithoutEvidenceCount': 0,
      'knownLimitationsReferenced': true,
      'supportedHardwareByPlatformReferenced': true,
    }),
  );
  await File('${root.path}/docs/release-notes.md').writeAsString('''
# Skotiq Release Notes

## Release
2026-05-05 test release.

## Release Summary
Self-test release notes fixture.

## Supported Platforms
See docs/supported-hardware-by-platform.md.

## Supported Hardware And Drivers
See docs/supported-hardware-by-platform.md.

## Security And Remote Access
See docs/production-readiness/public-release-gate.json.

## Migration And Compatibility
Verified by fixture evidence.

## Known Limitations
See docs/known-limitations.md.

## Verification Summary
See docs/production-readiness/public-release-gate.json.

## Upgrade Notes
Back up profiles before upgrade.

## Rollback Plan
Restore the previous build and profile backup.
''');
  await File(
    '${root.path}/docs/production-readiness/public-release-gate.json',
  ).writeAsString(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'decision': 'READY', 'ready': true, 'blockerCount': 0}),
  );
  final head = _gitHead(root);
  await File(
    '${root.path}/docs/production-readiness/final-release-signoff-evidence.json',
  ).writeAsString(
    JsonEncoder.withIndent('  ').convert({
      'reviewer': 'Release Owner',
      'date': '2026-05-05',
      'commit': head,
      'decision': 'ship',
      'checklistComplete': true,
      'noUnresolvedBlockers': true,
      'knownLimitationsReviewed': true,
      'releaseNotesReady': true,
      'releaseNotesPath': 'docs/release-notes.md',
    }),
  );
}

Future<void> _runVerifier(File verifier, Directory workingDirectory) async {
  final result = await Process.run('dart', [
    verifier.path,
  ], workingDirectory: workingDirectory.path);
  if (result.exitCode != 0) {
    throw StateError(
      'Verifier failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

Future<void> _runGit(Directory workingDirectory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: workingDirectory.path,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'git ${arguments.join(' ')} failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

String _gitHead(Directory workingDirectory) {
  final result = Process.runSync('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: workingDirectory.path);
  if (result.exitCode != 0) {
    throw StateError(
      'git rev-parse HEAD failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return result.stdout.toString().trim();
}

Map<String, dynamic> _readReport(Directory root) {
  final report = File(
    '${root.path}/docs/production-readiness/public-release-external-evidence.json',
  );
  return jsonDecode(report.readAsStringSync()) as Map<String, dynamic>;
}

void _expectCheckPassed(Map<String, dynamic> report, String id) {
  final check = _checkById(report, id);
  if (check['passed'] != true) {
    throw StateError('Expected $id to pass, got ${check['issues']}');
  }
}

void _expectCheckIssue(
  Map<String, dynamic> report,
  String id,
  String expectedIssue,
) {
  final check = _checkById(report, id);
  final issues = (check['issues'] as List).map((issue) => '$issue').toList();
  if (!issues.contains(expectedIssue)) {
    throw StateError(
      'Expected $id issue `$expectedIssue`, got ${issues.join('; ')}',
    );
  }
}

Map<String, dynamic> _checkById(Map<String, dynamic> report, String id) {
  final checks = (report['checks'] as List).cast<Map<String, dynamic>>();
  return checks.singleWhere((check) => check['id'] == id);
}

String? _sha256(File file) {
  final result = Platform.isWindows
      ? Process.runSync('certutil', ['-hashfile', file.path, 'SHA256'])
      : Process.runSync('sha256sum', [file.path]);
  if (result.exitCode != 0) {
    return null;
  }
  return RegExp(
    r'\b[0-9a-fA-F]{64}\b',
  ).firstMatch(result.stdout.toString())?.group(0)?.toLowerCase();
}

const _requiredDeviceTypes = [
  'camera',
  'mount',
  'focuser',
  'filterWheel',
  'rotator',
  'guider',
  'dome',
  'weather',
  'safetyMonitor',
];

List<Map<String, Object?>> _passingConnectionResults() {
  return [
    for (final deviceType in _requiredDeviceTypes)
      {
        'deviceType': deviceType,
        'deviceId': '$deviceType-sim',
        'backingType': 'simulator',
        'connectPassed': true,
        'disconnectPassed': true,
        'statusReadback': '$deviceType status verified',
      },
  ];
}

List<Map<String, Object?>> _passingLinuxRuntimeSmokeChecks() {
  return const [
    {
      'check': 'headless_process_started',
      'passed': true,
      'evidence': 'process PID and listening port recorded',
    },
    {
      'check': 'api_info_ok',
      'passed': true,
      'evidence': '/api/info returned HTTP 200',
    },
    {
      'check': 'openapi_ok',
      'passed': true,
      'evidence': '/api/openapi.json returned HTTP 200',
    },
    {
      'check': 'dashboard_asset_ok',
      'passed': true,
      'evidence': 'dashboard assets returned HTTP 200',
    },
  ];
}
