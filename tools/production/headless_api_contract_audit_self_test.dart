import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/headless_api_contract_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('Headless API contract audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_headless_api_contract_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp);
    final passing = _readJson(
      temp,
      'docs/production-readiness/headless-api-contract-audit.json',
    );
    _expect(passing['passed'] == true, 'passing fixture should pass');
    _expect(
      passing['registeredRouteCount'] == 5,
      'passing fixture should count registered routes',
    );
    _expect(
      passing['networkBackendRouteCount'] == 3,
      'passing fixture should count NetworkBackend routes',
    );
    _expect(
      passing['registeredNotAdvertisedCount'] == 0,
      'passing fixture should have no registered-not-advertised drift',
    );
    _expect(
      passing['networkBackendMissingOnServerCount'] == 0,
      'passing fixture should have no NetworkBackend/server drift',
    );
    final metadataCoverage =
        passing['openApiMetadataCoverage'] as Map? ?? const {};
    _expect(
      metadataCoverage.values.every((present) => present == true),
      'passing fixture should include OpenAPI operational metadata coverage',
    );
    final webSocketCoverage =
        passing['webSocketContractCoverage'] as Map? ?? const {};
    _expect(
      webSocketCoverage.values.every((present) => present == true),
      'passing fixture should include NetworkBackend WebSocket coverage',
    );
    final networkBackendContractCoverage =
        passing['networkBackendContractCoverage'] as Map? ?? const {};
    _expect(
      networkBackendContractCoverage.values.every((present) => present == true),
      'passing fixture should include NetworkBackend contract test coverage',
    );
    final versionNegotiationCoverage =
        passing['versionNegotiationCoverage'] as Map? ?? const {};
    _expect(
      versionNegotiationCoverage.values.every((present) => present == true),
      'passing fixture should include version negotiation coverage',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(script, temp, allowFailure: true);
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/headless-api-contract-audit.json',
    );
    _expect(failing['passed'] == false, 'failing report should not pass');
    _expect(
      failing['registeredNotAdvertisedCount'] == 1,
      'failing fixture should catch registered-not-advertised drift',
    );
    _expect(
      failing['networkBackendMissingOnServerCount'] == 1,
      'failing fixture should catch NetworkBackend/server drift',
    );

    stdout.writeln('Headless API contract audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _writeFile(root, 'apps/desktop/lib/headless_api_server.dart', r'''
void start() {
  router.get('/api/info', _handleInfo);
  router.post('/api/devices/connect', _handleConnect);
  router.get('/api/targets/<id>', _handleTarget);
  router.get('/api/ws', webSocketHandler(_handleWebSocket));
  router.get('/events', webSocketHandler(_handleWebSocket));
}

List<String> _getAvailableEndpoints() {
  return [
    'GET /api/info',
    'POST /api/devices/connect',
    'GET /api/targets/{id}',
    'WS /api/ws',
    'WS /events',
  ];
}
''');
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/handlers/system_endpoint_catalog.dart',
    r'''
List<String> availableHeadlessEndpoints() {
  return const [
    'GET /api/info',
    'POST /api/devices/connect',
    'GET /api/targets/{id}',
    'WS /api/ws',
    'WS /events',
  ];
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/backend/network_backend.dart',
    r'''
void calls() {
  _get('info');
  _post('devices/connect');
  _get('targets/$id');
  Future<RemoteApiCompatibilityResult> _checkServerCompatibility() async {}
  RemoteApiCompatibility.check(
    info['apiVersion'] as String? ?? info['version'] as String?,
  );
  headers[RemoteApiCompatibility.apiVersionHeader] =
      RemoteApiCompatibility.clientApiVersion.format();
  queryParameters['apiVersion'] =
      RemoteApiCompatibility.clientApiVersion.format();
}
''',
  );
  await _writePassingRouteMetadataFixture(root);
  await _writePassingWebSocketTestFixture(root);
  await _writePassingNetworkBackendContractTestFixture(root);
  await _writePassingVersionNegotiationFixtures(root);
}

Future<void> _writeFailingFixture(Directory root) async {
  await _writeFile(root, 'apps/desktop/lib/headless_api_server.dart', r'''
void start() {
  router.get('/api/info', _handleInfo);
  router.get('/api/status', _handleStatus);
}

List<String> _getAvailableEndpoints() {
  return [
    'GET /api/info',
  ];
}
''');
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/handlers/system_endpoint_catalog.dart',
    r'''
List<String> availableHeadlessEndpoints() {
  return const [
    'GET /api/info',
  ];
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/backend/network_backend.dart',
    r'''
void calls() {
  _get('info');
  _post('devices/connect');
}
''',
  );
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/route_metadata.dart',
    r'''
void buildOpenApiSpec() {}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/test/backend/network_backend_websocket_test.dart',
    r'''
void main() {}
''',
  );
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/network_backend_contract_test.dart',
    r'''
void main() {}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/models/backend/remote_api_compatibility.dart',
    'class RemoteApiCompatibility {}',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/test/models/remote_api_compatibility_test.dart',
    'void main() {}',
  );
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/auth_middleware_test.dart',
    'void main() {}',
  );
  await _writeFile(
    root,
    'apps/desktop/web_dashboard/js/api.js',
    'class SkotiqApi {}',
  );
  await _writeFile(root, 'docs/api/web-server-api.md', '# API');
}

Future<void> _writePassingRouteMetadataFixture(Directory root) async {
  await _writeFile(
    root,
    'apps/desktop/lib/headless_api/route_metadata.dart',
    r'''
void buildOpenApiSpec() {
  final body = {
    'x-max-request-body-bytes': requestBodyLimitForPath('/api/mount/slew'),
  };
  final rate = endpointRateLimitFor(method: 'POST', path: '/api/mount/slew');
  final audit = highRiskAuditActionFor(method: 'POST', path: '/api/mount/slew');
  final responses = {
    '413': {'description': 'Request body too large'},
    '429': {'description': 'Rate limit exceeded'},
    '426': {'description': 'Upgrade required for API version mismatch'},
  };
  final metadata = {
    'x-rate-limit': rate,
    'x-audit-action': audit,
    'x-auth-required': true,
    'x-required-scope': requiredAuthScopeNameForEndpoint(
      method: 'POST',
      path: '/api/mount/slew',
    ),
  };
  final components = {
    'securitySchemes': {
      'bearerAuth': {'scheme': 'bearer'},
    },
  };
  final public = isPublicEndpoint(method: 'GET', path: '/api/info');
  [body, responses, metadata, components, public];
}
''',
  );
}

Future<void> _writePassingWebSocketTestFixture(Directory root) async {
  await _writeFile(
    root,
    'packages/skotiq_core/test/backend/network_backend_websocket_test.dart',
    r'''
void main() {
  'sends ping heartbeats and accepts pong replies';
  data['type'] == 'ping';
  {'type': 'pong'};
  'rejects incompatible servers before opening WebSocket';
  'routes headless event wrappers to event and polar alignment streams';
  {'type': 'event'};
  backend.eventStream;
  backend.polarAlignmentEvents;
  'PolarAlignmentProgress';
  'azimuthErrorArcmin';
  EventCategory.polarAlignment;
}
''',
  );
}

Future<void> _writePassingNetworkBackendContractTestFixture(
  Directory root,
) async {
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/network_backend_contract_test.dart',
    r'''
void main() {
  'advertised endpoints match registered API routes';
  advertised.difference(registered);
  registered.difference(advertised);
  'NetworkBackend call sites map to registered server routes';
  clientRoutes.difference(registered);
  _networkBackendRoutes;
  'OpenAPI spec advertises every HTTP route from the route table';
  buildOpenApiSpec;
  'WebSocket endpoints are advertised in /api/info';
  paths[path];
  contains(method);
  'OpenAPI must include advertised route';
}
''',
  );
}

Future<void> _writePassingVersionNegotiationFixtures(Directory root) async {
  await _writeFile(
    root,
    'packages/skotiq_core/lib/src/models/backend/remote_api_compatibility.dart',
    r'''
class RemoteApiCompatibility {
  static final minimumSupportedVersion =
      SkotiqServerCompatibility.minimumSupportedVersion;
  static void check(String version) {
    SkotiqServerCompatibility.check(version);
  }
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_remote_protocol/lib/src/server_compatibility.dart',
    r'''
class SkotiqServerCompatibility {
  static const minimumSupportedVersion = ServerSemanticVersion(2, 4, 0);
  static void check(String version) {
    print('server_too_old');
    print('server_too_new');
    print('client_too_old');
  }
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_core/test/models/remote_api_compatibility_test.dart',
    r'''
void main() {
  'rejects old servers with a clear code and message';
  'rejects newer major servers with a clear code and message';
  'rejects old clients with a clear code and message';
  'rejects clients that require a newer server major';
}
''',
  );
  await _writeFile(
    root,
    'apps/desktop/test/headless_api/auth_middleware_test.dart',
    r'''
void main() {
  'rejects explicit incompatible client API versions before auth';
  HttpStatus.upgradeRequired;
  expect(tooOld.body['error'], 'client_too_old');
  expect(tooNew.body['error'], 'server_too_old');
  'rejects incompatible WebSocket API versions before auth';
  'GET /events?apiVersion=1.9.9 HTTP/1.1';
  'GET /events?apiVersion=3.0.0 HTTP/1.1';
}
''',
  );
  await _writeFile(root, 'apps/desktop/web_dashboard/js/api.js', r'''
class SkotiqApi {
  constructor() { this._apiVersion = '2.5.0'; }
  _headers() {
    return {'X-Skotiq-API-Version': this._apiVersion};
  }
  _connectWebSocket() {
    query.push('apiVersion=' + encodeURIComponent(this._apiVersion));
  }
}
''');
  await _writeFile(root, 'docs/api/web-server-api.md', r'''
Remote clients use `/api/info.apiVersion` for API compatibility checks and
fall back to `version` for older servers. The current client accepts server API
versions `2.4.0` and newer within major version `2`. Incompatible versions show
server too old/new guidance.
''');
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
