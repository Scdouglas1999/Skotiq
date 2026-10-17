import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/developer_quality_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Developer quality audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_developer_quality_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/developer-quality-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['issueCount'] == 0,
      'passing fixture should have no issues',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/developer-quality-audit.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    final issues = (failing['issues'] as List? ?? const []).join('\n');
    _expect(
      issues.contains('UI consistency blocking findings=2'),
      'failing report should include UI blocking issue',
    );
    _expect(
      issues.contains('Design-system gallery evidence is incomplete'),
      'failing report should include missing gallery evidence issue',
    );
    _expect(
      issues.contains('Headless route policy issues=1'),
      'failing report should include route policy issue',
    );
    _expect(
      issues.contains('Headless API contract audit did not pass'),
      'failing report should include API contract issue',
    );
    _expect(
      issues.contains('is missing structured logging text'),
      'failing report should include structured logging issue',
    );

    stdout.writeln('Developer quality audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _writeJson(
    root,
    'docs/production-readiness/ui-consistency-audit.json',
    {
      'findingCount': 203,
      'blockingFindingCount': 0,
      'countsByRule': {'raw_material_color': 203},
      'rawColorClassifications': {'intentional_image_overlay': 203},
      'designSystemGallery': {'ready': true, 'missing': []},
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-api-contract-audit.json',
    {
      'passed': true,
      'registeredRouteCount': 295,
      'advertisedRouteCount': 295,
      'openApiOperationCount': 293,
      'networkBackendRouteCount': 255,
      'registeredNotAdvertisedCount': 0,
      'advertisedNotRegisteredCount': 0,
      'networkBackendMissingOnServerCount': 0,
      'advertisedHttpMissingOpenApiCount': 0,
      'openApiMetadataCoverage': {'request_body_limit_extension': true},
      'webSocketContractCoverage': {'heartbeat_ping_pong': true},
      'networkBackendContractCoverage': {
        'network_backend_calls_registered_routes': true,
      },
      'versionNegotiationCoverage': {'network_backend_preflight': true},
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-route-policy-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'highRiskPolicyCount': 19,
      'defaultLimitedPolicyCount': 9,
      'ordinaryReadLimited': false,
      'fileBrowseAuditAction': 'file_browse',
      'bodyLimits': {'/api/mount/slew': 1048576},
      'bodyLimitedApiWriteRouteCount': 3,
      'serverMiddlewareTestCount': 3,
      'serverMiddlewareTests': {
        'oversized_control_request_before_auth': true,
        'high_risk_control_rate_limit': true,
        'websocket_api_version_before_auth': true,
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-response-helper-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'usage': {
        'rawResponseCallCount': 12,
        'jsonContentTypeCount': 12,
        'helperImportCount': 2,
        'helperCallCount': 3,
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/oversized-file-audit.json',
    {
      'scannedFileCount': 10,
      'warningFileCount': 1,
      'criticalFileCount': 1,
      'prioritySplitCandidateCount': 1,
      'modularizedSourceFamilyCount': 1,
      'warningLineLimit': 1000,
      'criticalLineLimit': 2500,
    },
  );
  await _writeStructuredLoggingFixture(root);
}

Future<void> _writeFailingFixture(Directory root) async {
  await _writeJson(
    root,
    'docs/production-readiness/ui-consistency-audit.json',
    {
      'findingCount': 4,
      'blockingFindingCount': 2,
      'countsByRule': {
        'raw_button_style': 1,
        'empty_callback': 1,
        'fake_callback': 1,
        'stub_callback': 1,
        'raw_material_color': 2,
      },
      'rawColorClassifications': {
        'semantic_theme_color': 1,
        'intentional_image_overlay': 1,
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-api-contract-audit.json',
    {
      'passed': false,
      'registeredRouteCount': 2,
      'advertisedRouteCount': 1,
      'openApiOperationCount': 1,
      'networkBackendRouteCount': 2,
      'registeredNotAdvertisedCount': 1,
      'advertisedNotRegisteredCount': 0,
      'networkBackendMissingOnServerCount': 1,
      'advertisedHttpMissingOpenApiCount': 0,
      'openApiMetadataCoverage': {'request_body_limit_extension': false},
      'webSocketContractCoverage': {'heartbeat_ping_pong': false},
      'networkBackendContractCoverage': {
        'network_backend_calls_registered_routes': false,
      },
      'versionNegotiationCoverage': {'network_backend_preflight': false},
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-route-policy-audit.json',
    {
      'passed': false,
      'issueCount': 1,
      'highRiskPolicyCount': 18,
      'defaultLimitedPolicyCount': 9,
      'ordinaryReadLimited': false,
      'fileBrowseAuditAction': 'file_browse',
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/headless-response-helper-audit.json',
    {
      'passed': true,
      'issueCount': 0,
      'usage': {
        'rawResponseCallCount': 12,
        'jsonContentTypeCount': 12,
        'helperImportCount': 2,
        'helperCallCount': 3,
      },
    },
  );
  await _writeJson(
    root,
    'docs/production-readiness/oversized-file-audit.json',
    {
      'scannedFileCount': 10,
      'warningFileCount': 1,
      'criticalFileCount': 1,
      'prioritySplitCandidateCount': 1,
      'modularizedSourceFamilyCount': 1,
      'warningLineLimit': 1000,
      'criticalLineLimit': 2500,
    },
  );
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/services/logging_service.dart',
    'class LoggingService {}',
  );
}

Future<void> _writeStructuredLoggingFixture(Directory root) async {
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/services/logging_service.dart',
    '''
class LogEntry {
  final Map<String, Object?> fields;
  String toString() => jsonEncode(_jsonSafe(fields));
}
void log(String message, {Map<String, Object?>? fields}) {
  LogEntry(fields: fields);
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/test/services/logging_service_test.dart',
    '''
void main() {
  // records structured fields on log entries
  final fields = {'requestId': 'req-1'};
  print(entry.fields);
}
''',
  );
  await _writeFile(root, 'apps/desktop/lib/headless_api_server.dart', '''
void logRequest() {
  final fields = {
    'requestId': requestId,
    'elapsedMs': elapsedMs,
    'auditAction': auditAction,
    'phase': 'completed',
  };
}
''');
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/backend/network_backend.dart',
    '''
class _NetworkBackendTransport {
  static const _requestIdHeader = 'x-request-id';
  final compatHeaders = {
    _NetworkBackendTransport._requestIdHeader: _nextRequestId('compat'),
  };
  void headers(Map<String, String> headers, String endpoint) {
    headers[RemoteApiCompatibility.apiVersionHeader] = '2.5.0';
    headers[_NetworkBackendTransport._requestIdHeader] = _nextRequestId(endpoint);
  }
}
''',
  );
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'dart',
    [script.path, '--root', root.path],
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

Future<void> _writeJson(
  Directory root,
  String relativePath,
  Object? data,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
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
