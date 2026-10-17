import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final gate = File(
    '${repoRoot.path}/tools/production/public_release_gate.dart',
  );
  if (!gate.existsSync()) {
    throw StateError('Public release gate not found: ${gate.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_public_release_gate_self_test_',
  );
  try {
    await _prepareWorkspace(temp);

    await _writeBasePassingArtifacts(temp);
    await _writeFailedSelfTestsFixture(temp);
    await _writeReadyFixture(temp);
    await _runGate(gate, temp);
    final failedSelfTestsReport = _readReport(temp);
    _expect(
      failedSelfTestsReport['decision'] == 'NOT_READY',
      'failed self-test aggregate fixture should not be ready',
    );
    final failedSelfTests = _checkById(
      failedSelfTestsReport,
      'public_release_self_tests',
    );
    _expect(
      failedSelfTests['passed'] == false,
      'failed public_release_self_tests check should fail',
    );
    _expect(
      failedSelfTests['detail'].toString().contains('failedCount=1'),
      'failed public_release_self_tests detail should include failed count',
    );

    await _writePassingSelfTestsFixture(temp);
    await _writeStaleSplitPlanFixture(temp);
    await _runGate(gate, temp);
    final staleReport = _readReport(temp);
    _expect(
      staleReport['decision'] == 'NOT_READY',
      'stale split-plan fixture should not be ready',
    );
    _expectCheckPassed(staleReport, 'public_release_self_tests');
    final staleStaging = _checkById(staleReport, 'release_staging');
    _expect(
      staleStaging['passed'] == false,
      'stale split-plan release_staging check should fail',
    );
    _expect(
      staleStaging['detail'].toString().contains(
        'source audit timestamp mismatch',
      ),
      'stale split-plan detail should report source timestamp mismatch',
    );
    _expect(
      staleStaging['detail'].toString().contains(
        'plan entryCount=1 but staging paths=2',
      ),
      'stale split-plan detail should report entry count mismatch',
    );

    await _writeReadyFixture(temp);
    await _runGate(gate, temp);
    final readyReport = _readReport(temp);
    _expect(
      readyReport['decision'] == 'READY',
      'ready fixture decision should be READY',
    );
    _expect(readyReport['ready'] == true, 'ready fixture ready should be true');
    _expect(
      readyReport['blockerCount'] == 0,
      'ready fixture should have no blockers',
    );
    _expectCheckPassed(readyReport, 'public_release_self_tests');
    _expectCheckPassed(readyReport, 'release_staging');
    final readyUiConsistency = _checkById(readyReport, 'ui_consistency');
    _expect(
      readyUiConsistency['detail'].toString().contains(
        'designSystemGalleryReady=true',
      ),
      'ready UI consistency detail should expose gallery readiness',
    );

    stdout.writeln('Public release gate self-test passed.');
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
  await File('${root.path}/.audit_highrisk.txt').writeAsString('');
  await File(
    '${root.path}/docs/production-readiness/highrisk-baseline.txt',
  ).writeAsString('');
  await File(
    '${root.path}/docs/production-readiness/public-release-master-checklist.md',
  ).writeAsString('# Public Release Master Checklist\n');
}

Future<void> _writeBasePassingArtifacts(Directory root) async {
  await _writeJson(root, 'docs/production-readiness/analyzer-rollup.json', {
    'summary': {
      'production': {'errors': 0, 'warnings': 0},
    },
  });
  await _writeJson(root, 'docs/production-readiness/fail-closed-audit.json', {
    'passed': true,
    'violationCount': 0,
  });
  await _writeJson(
    root,
    'docs/production-readiness/ui-consistency-audit.json',
    {
      'blockingFindingCount': 0,
      'findingCount': 0,
      'countsByRule': {},
      'rawColorClassifications': {},
      'designSystemGallery': {'ready': true, 'missing': []},
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/developer-quality-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'checks': [
        {
          'id': 'ui_consistency',
          'passed': true,
          'metrics': {'blockingFindingCount': 0},
        },
        {
          'id': 'headless_route_policy',
          'passed': true,
          'metrics': {'issueCount': 0},
        },
        {
          'id': 'headless_response_helpers',
          'passed': true,
          'metrics': {
            'issueCount': 0,
            'rawResponseCallCount': 2,
            'helperCallCount': 1,
          },
        },
        {
          'id': 'oversized_files',
          'passed': true,
          'metrics': {
            'scannedFileCount': 10,
            'criticalFileCount': 1,
            'releaseBlocking': false,
          },
        },
      ],
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/windows-bundle-audit.json',
    {
      'passed': true,
      'fileCount': 1,
      'missingRequiredFileCount': 0,
      'disallowedFileCount': 0,
      'bundlePath': 'fixture',
    },
  );
  await _writeJson(root, 'docs/production-readiness/dependency-hygiene.json', {
    'passed': true,
    'packageCount': 1,
    'violationCount': 0,
  });
  await _writeJson(
    root,
    'docs/production-readiness/headless-api-contract-audit.json',
    {
      'passed': true,
      'registeredRouteCount': 1,
      'advertisedRouteCount': 1,
      'advertisedHttpRouteCount': 1,
      'openApiPathCount': 1,
      'networkBackendRouteCount': 1,
      'registeredNotAdvertisedCount': 0,
      'advertisedNotRegisteredCount': 0,
      'networkBackendMissingOnServerCount': 0,
      'advertisedHttpMissingOpenApiCount': 0,
      'openApiMetadataCoverageCount': 9,
      'openApiMetadataCoverage': {
        'request_body_limit_extension': true,
        'rate_limit_extension': true,
        'audit_action_extension': true,
        'oversized_response': true,
        'rate_limited_response': true,
        'bearer_security_scheme': true,
        'required_scope_extension': true,
        'public_endpoint_extension': true,
        'api_version_mismatch_response': true,
      },
      'webSocketContractCoverageCount': 4,
      'webSocketContractCoverage': {
        'heartbeat_ping_pong': true,
        'compatibility_before_socket': true,
        'headless_event_wrapper_to_event_stream': true,
        'polar_alignment_event_stream': true,
      },
      'versionNegotiationCoverageCount': 10,
      'versionNegotiationCoverage': {
        'shared_compatibility_policy': true,
        'shared_compatibility_tests': true,
        'server_http_version_middleware_test': true,
        'server_websocket_version_middleware_test': true,
        'network_backend_preflight': true,
        'network_backend_version_headers': true,
        'network_backend_websocket_query_version': true,
        'dashboard_http_version_header': true,
        'dashboard_websocket_query_version': true,
        'docs_user_facing_compatibility': true,
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-route-policy-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'highRiskPolicyCount': 0,
      'defaultLimitedPolicyCount': 0,
      'ordinaryReadLimited': false,
      'fileBrowseAuditAction': 'file_browse',
      'bodyLimits': {'/api/mount/slew': 1048576},
      'bodyLimitedApiWriteRouteCount': 3,
      'serverMiddlewareTestCount': 2,
      'serverMiddlewareTests': {
        'oversized_control_request_before_auth': true,
        'high_risk_control_rate_limit': true,
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-response-helper-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'helper': {'exists': true, 'missingTextCount': 0},
      'tests': {'exists': true, 'missingTextCount': 0},
      'usage': {
        'rawResponseCallCount': 2,
        'jsonContentTypeCount': 2,
        'helperImportCount': 1,
        'helperCallCount': 1,
      },
    },
  );
  await _writeJson(root, 'docs/production-readiness/docs-link-audit.json', {
    'markdownFileCount': 1,
    'checkedLocalLinkCount': 0,
    'brokenLocalLinkCount': 0,
  });
  await _writeJson(root, 'docs/production-readiness/release-docs-audit.json', {
    'passed': true,
    'documentCount': 6,
    'issueCount': 0,
    'issues': [],
  });
  await _writeJson(
    root,
    'docs/production-readiness/platform-capability-audit.json',
    {'passed': true, 'fileCount': 10, 'issueCount': 0, 'issues': []},
  );
  await _writeJson(
    root,
    'docs/production-readiness/linux-release-workflow-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'workflow': {'exists': true, 'missingTextCount': 0},
      'metadataTool': {'exists': true, 'missingTextCount': 0},
      'ciRecipe': {'exists': true, 'missingTextCount': 0},
      'metadataRequirements': {
        'packageSha256': true,
        'perFileSha256': true,
        'sourceGitHead': true,
        'githubRunContext': true,
        'schemaVersion': true,
        'toolVersions': true,
        'sha256Sidecar': true,
      },
      'workflowRequirements': {
        'checkout': true,
        'timeoutMinutes': true,
        'failOnMissingArtifacts': true,
        'artifactRetention': true,
      },
      'recipeRequirements': {
        'workflowDispatch': true,
        'sha256Sidecar': true,
        'schemaVersion': true,
        'toolVersions': true,
        'evidencePath': true,
        'runtimeSmokeGate': true,
      },
    },
  );
  await _writePassingSelfTestsFixture(root);
  await _writeJson(
    root,
    'docs/production-readiness/linux-environment-probe.json',
    {'linuxBuildEnvironmentAvailable': true},
  );
  await _writeJson(
    root,
    'docs/production-readiness/hardware-availability-probe.json',
    {
      'fullRealOrSimulatorCoverage': true,
      'missingRealOrSimulatorDeviceTypes': [],
      'missingNonSimulatorDeviceTypes': [],
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/migration-regression-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'manualRealArtifactGatePreserved': true,
      'fixture': {'exists': true, 'missingTextCount': 0},
      'tests': {'exists': true, 'missingTextCount': 0},
      'manualProbe': {'exists': true, 'missingTextCount': 0},
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/manual-migration-probe.json',
    {
      'artifactProvided': true,
      'sourceExists': true,
      'sourceSizeBytes': 1,
      'sourceSha256':
          '0000000000000000000000000000000000000000000000000000000000000000',
      'copiedSourceSha256':
          '0000000000000000000000000000000000000000000000000000000000000000',
      'copiedSourceSha256Matches': true,
      'qualifiesAsOlderProfile': true,
      'migrationVerified': true,
      'expectedTableCount': 12,
      'migratedTableCount': 12,
      'defaultSettingCount': 7,
      'missingTables': [],
      'missingDefaultSettings': [],
    },
  );
  await File(
    '${root.path}/docs/production-readiness/android-emulator-remote-smoke-log.txt',
  ).writeAsString('remote smoke passed\n');
  await File(
    '${root.path}/docs/production-readiness/android-emulator-remote-smoke.png',
  ).writeAsBytes([1]);
  await File(
    '${root.path}/docs/production-readiness/mobile-remote-window-connected.xml',
  ).writeAsString('<window />');
  await File(
    '${root.path}/docs/production-readiness/android-emulator-remote-reconnect-smoke-log.txt',
  ).writeAsString(
    'Server-observed mobile WebSocket viewer:\n{"viewers": [{"viewerId": "mobile"}]}\n',
  );
  await _writeJson(
    root,
    'docs/production-readiness/public-release-checklist-audit.json',
    {
      'totalItemCount': 1,
      'checkedItemCount': 1,
      'uncheckedItemCount': 0,
      'checkedWithoutEvidenceCount': 0,
      'knownLimitationsReferenced': true,
      'supportedHardwareByPlatformReferenced': true,
    },
  );
  await _writeExternalEvidence(root);
}

Future<void> _writePassingSelfTestsFixture(Directory root) async {
  await _writeJson(
    root,
    'docs/production-readiness/public-release-self-tests.json',
    {
      'passed': true,
      'selfTestCount': 25,
      'expectedSelfTestCount': 25,
      'passedCount': 25,
      'failedCount': 0,
      'results': [
        for (final script in [
          'tools/production/analyzer_rollup_self_test.dart',
          'tools/production/public_release_gate_self_test.dart',
          'tools/production/public_release_blocker_inputs_self_test.dart',
          'tools/production/public_release_external_evidence_self_test.dart',
          'tools/production/public_release_completion_audit_self_test.dart',
          'tools/production/public_release_owner_checklist_self_test.dart',
          'tools/production/public_release_checklist_audit_self_test.dart',
          'tools/production/placeholder_audit_self_test.dart',
          'tools/production/fail_closed_check_self_test.dart',
          'tools/production/release_staging_pr_plan_self_test.dart',
          'tools/production/release_pr_owner_matrix_self_test.dart',
          'tools/production/linux_release_package_metadata_self_test.dart',
          'tools/production/linux_release_workflow_audit_self_test.dart',
          'tools/production/oversized_file_audit_self_test.dart',
          'tools/production/dependency_hygiene_self_test.dart',
          'tools/production/developer_quality_audit_self_test.dart',
          'tools/production/docs_link_audit_self_test.dart',
          'tools/production/headless_api_contract_audit_self_test.dart',
          'tools/production/headless_route_policy_audit_self_test.dart',
          'tools/production/headless_response_helper_audit_self_test.dart',
          'tools/production/migration_regression_audit_self_test.dart',
          'tools/production/release_docs_audit_self_test.dart',
          'tools/production/platform_capability_audit_self_test.dart',
          'tools/production/ui_consistency_audit_self_test.dart',
          'tools/production/windows_bundle_audit_self_test.dart',
        ])
          {
            'script': script,
            'exitCode': 0,
            'passed': true,
            'durationMillis': 1,
          },
      ],
    },
  );
}

Future<void> _writeFailedSelfTestsFixture(Directory root) async {
  await _writeJson(
    root,
    'docs/production-readiness/public-release-self-tests.json',
    {
      'passed': false,
      'selfTestCount': 25,
      'expectedSelfTestCount': 25,
      'passedCount': 24,
      'failedCount': 1,
      'results': [
        {
          'script': 'tools/production/analyzer_rollup_self_test.dart',
          'exitCode': 0,
          'passed': true,
          'durationMillis': 1,
        },
        {
          'script': 'tools/production/public_release_gate_self_test.dart',
          'exitCode': 0,
          'passed': true,
          'durationMillis': 1,
        },
        {
          'script':
              'tools/production/public_release_blocker_inputs_self_test.dart',
          'exitCode': 1,
          'passed': false,
          'durationMillis': 1,
        },
        for (final script in [
          'tools/production/public_release_external_evidence_self_test.dart',
          'tools/production/public_release_completion_audit_self_test.dart',
          'tools/production/public_release_owner_checklist_self_test.dart',
          'tools/production/public_release_checklist_audit_self_test.dart',
          'tools/production/placeholder_audit_self_test.dart',
          'tools/production/fail_closed_check_self_test.dart',
          'tools/production/release_staging_pr_plan_self_test.dart',
          'tools/production/release_pr_owner_matrix_self_test.dart',
          'tools/production/linux_release_package_metadata_self_test.dart',
          'tools/production/linux_release_workflow_audit_self_test.dart',
          'tools/production/oversized_file_audit_self_test.dart',
          'tools/production/dependency_hygiene_self_test.dart',
          'tools/production/developer_quality_audit_self_test.dart',
          'tools/production/docs_link_audit_self_test.dart',
          'tools/production/headless_api_contract_audit_self_test.dart',
          'tools/production/headless_route_policy_audit_self_test.dart',
          'tools/production/headless_response_helper_audit_self_test.dart',
          'tools/production/migration_regression_audit_self_test.dart',
          'tools/production/release_docs_audit_self_test.dart',
          'tools/production/platform_capability_audit_self_test.dart',
          'tools/production/ui_consistency_audit_self_test.dart',
          'tools/production/windows_bundle_audit_self_test.dart',
        ])
          {
            'script': script,
            'exitCode': 0,
            'passed': true,
            'durationMillis': 1,
          },
      ],
    },
  );
}

Future<void> _writeExternalEvidence(Directory root) async {
  await _writeJson(
    root,
    'docs/production-readiness/public-release-external-evidence.json',
    {
      'passedCount': 5,
      'checkCount': 5,
      'checks': [
        for (final id in [
          'linux_release_build',
          'hardware_control_smoke',
          'second_device_lan_firewall',
          'real_remote_control_actions',
          'final_release_signoff',
        ])
          {
            'id': id,
            'passed': true,
            'evidencePath': 'docs/production-readiness/$id.json',
            'templatePath': 'docs/production-readiness/$id.template.json',
            'issues': [],
          },
      ],
    },
  );
}

Future<void> _writeStaleSplitPlanFixture(Directory root) async {
  await _clearPathspecs(root);
  await _writeJson(
    root,
    'docs/production-readiness/release-staging-audit.json',
    {
      'generatedAt': '2026-05-05T00:00:02.000Z',
      'currentBranch': 'release/public-readiness',
      'entryCount': 2,
      'untrackedReleaseCriticalCount': 0,
      'categories': {
        'release-tooling': {
          'paths': [
            _statusEntry('tools/production/a.dart'),
            _statusEntry('tools/production/b.dart'),
          ],
        },
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-pr-split-plan.json',
    {
      'sourceGeneratedAt': '2026-05-05T00:00:01.000Z',
      'entryCount': 1,
      'bucketCount': 1,
      'buckets': [
        {
          'paths': [_statusEntry('tools/production/a.dart')],
        },
      ],
    },
  );
  await File(
    '${root.path}/docs/production-readiness/release-pr-pathspecs/01-release-infra-evidence.txt',
  ).writeAsString('tools/production/a.dart\n');
}

Future<void> _writeReadyFixture(Directory root) async {
  await _clearPathspecs(root);
  await _writeJson(
    root,
    'docs/production-readiness/release-staging-audit.json',
    {
      'generatedAt': '2026-05-05T00:00:03.000Z',
      'currentBranch': 'release/public-readiness',
      'entryCount': 0,
      'untrackedReleaseCriticalCount': 0,
      'categories': {},
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/release-pr-split-plan.json',
    {
      'sourceGeneratedAt': '2026-05-05T00:00:03.000Z',
      'entryCount': 0,
      'bucketCount': 0,
      'buckets': [],
    },
  );
}

Future<void> _clearPathspecs(Directory root) async {
  final directory = Directory(
    '${root.path}/docs/production-readiness/release-pr-pathspecs',
  );
  await directory.create(recursive: true);
  for (final file in directory.listSync().whereType<File>()) {
    await file.delete();
  }
}

Map<String, Object?> _statusEntry(String path) => {
  'status': ' M',
  'path': path,
  'untracked': false,
  'deleted': false,
  'generated': false,
  'binary': false,
  'releaseCritical': true,
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

Future<void> _runGate(File gate, Directory workingDirectory) async {
  final result = await Process.run('dart', [
    gate.path,
  ], workingDirectory: workingDirectory.path);
  if (result.exitCode != 0) {
    throw StateError(
      'Public release gate failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

Map<String, dynamic> _readReport(Directory root) {
  final report = File(
    '${root.path}/docs/production-readiness/public-release-gate.json',
  );
  return jsonDecode(report.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _checkById(Map<String, dynamic> report, String id) {
  final checks = (report['checks'] as List).cast<Map<String, dynamic>>();
  return checks.singleWhere((check) => check['id'] == id);
}

void _expectCheckPassed(Map<String, dynamic> report, String id) {
  final check = _checkById(report, id);
  _expect(check['passed'] == true, '$id should pass, got ${check['detail']}');
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
