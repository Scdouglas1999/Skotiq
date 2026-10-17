import 'dart:convert';
import 'dart:io';

const _serverPath = 'apps/desktop/lib/headless_api_server.dart';

/// Directory holding per-domain declarative route tables. Every file
/// under here exposes a top-level `List<HeadlessRoute> buildXxxRoutes
/// (...)` whose entries take the shape
/// `HeadlessRoute(HttpMethod.<verb>, '<path>', ...)`. The audit scans
/// this directory in addition to [_serverPath], so the registered-route
/// inventory covers the declarative tables as well as any inline
/// `router.<verb>(...)` calls in `start()`.
const _routesDirectory = 'apps/desktop/lib/headless_api/routes';

/// File the canonical `availableHeadlessEndpoints()` catalog lives in: a
/// dedicated `system_endpoint_catalog.dart`, re-exported from
/// `system_handlers.dart`. The audit reads this file's source to compare
/// the advertised list against the registered routes.
const _systemHandlersPath =
    'apps/desktop/lib/headless_api/handlers/system_endpoint_catalog.dart';

const _networkBackendPath =
    'packages/skotiq_core/lib/src/backend/network_backend.dart';
const _networkBackendPartsDirectory =
    'packages/skotiq_core/lib/src/backend/network_backend';
const _routeMetadataPath = 'apps/desktop/lib/headless_api/route_metadata.dart';
const _networkBackendWebSocketTestPath =
    'packages/skotiq_core/test/backend/network_backend_websocket_test.dart';
const _networkBackendContractTestPath =
    'apps/desktop/test/headless_api/network_backend_contract_test.dart';
const _remoteApiCompatibilityPath =
    'packages/skotiq_core/lib/src/models/backend/remote_api_compatibility.dart';
const _serverCompatibilityPath =
    'packages/skotiq_remote_protocol/lib/src/server_compatibility.dart';
const _remoteApiCompatibilityTestPath =
    'packages/skotiq_core/test/models/remote_api_compatibility_test.dart';
const _headlessAuthMiddlewareTestPath =
    'apps/desktop/test/headless_api/auth_middleware_test.dart';
const _dashboardApiPath = 'apps/desktop/web_dashboard/js/api.js';
const _apiDocsPath = 'docs/api/web-server-api.md';
const _jsonOutputPath =
    'docs/production-readiness/headless-api-contract-audit.json';
const _markdownOutputPath =
    'docs/production-readiness/headless-api-contract-audit.md';

void main(List<String> args) {
  final failOnDrift = !args.contains('--no-fail-on-drift');
  final server = File(_serverPath);
  final networkBackend = File(_networkBackendPath);
  final routeMetadata = File(_routeMetadataPath);
  final networkBackendWebSocketTest = File(_networkBackendWebSocketTestPath);
  final networkBackendContractTest = File(_networkBackendContractTestPath);
  if (!server.existsSync()) {
    stderr.writeln('Headless API server source not found: $_serverPath');
    exit(2);
  }
  if (!networkBackend.existsSync()) {
    stderr.writeln('NetworkBackend source not found: $_networkBackendPath');
    exit(2);
  }
  if (!routeMetadata.existsSync()) {
    stderr.writeln('Route metadata source not found: $_routeMetadataPath');
    exit(2);
  }
  if (!networkBackendWebSocketTest.existsSync()) {
    stderr.writeln(
      'NetworkBackend WebSocket test source not found: '
      '$_networkBackendWebSocketTestPath',
    );
    exit(2);
  }
  if (!networkBackendContractTest.existsSync()) {
    stderr.writeln(
      'NetworkBackend contract test source not found: '
      '$_networkBackendContractTestPath',
    );
    exit(2);
  }

  final serverSource = server.readAsStringSync();
  final networkBackendSource = _readNetworkBackendSource(networkBackend);
  final routeMetadataSource = _readRouteMetadataSource(routeMetadata);
  final networkBackendWebSocketTestSource = networkBackendWebSocketTest
      .readAsStringSync();
  final networkBackendContractTestSource = networkBackendContractTest
      .readAsStringSync();
  final versionNegotiationCoverage = _versionNegotiationCoverage(
    remoteApiCompatibilitySource: _readSource(_remoteApiCompatibilityPath),
    serverCompatibilitySource: _readSource(_serverCompatibilityPath),
    remoteApiCompatibilityTestSource: _readSource(
      _remoteApiCompatibilityTestPath,
    ),
    headlessAuthMiddlewareTestSource: _readSource(
      _headlessAuthMiddlewareTestPath,
    ),
    networkBackendSource: networkBackendSource,
    dashboardApiSource: _readSource(_dashboardApiPath),
    apiDocsSource: _readSource(_apiDocsPath),
  );
  final systemHandlersSource = _readSource(_systemHandlersPath);
  if (systemHandlersSource.isEmpty) {
    stderr.writeln(
      'Endpoint-catalog source not found at $_systemHandlersPath — '
      'the canonical endpoint catalog `availableHeadlessEndpoints()` '
      'is expected to live there.',
    );
    exit(2);
  }
  final registered = _registeredApiRoutes(serverSource);
  final advertised = _advertisedApiRoutes(systemHandlersSource);
  final networkBackendRoutes = _networkBackendRoutes(networkBackendSource);
  final openApiMetadata = _openApiMetadataCoverage(routeMetadataSource);
  final webSocketContractCoverage = _webSocketContractCoverage(
    networkBackendWebSocketTestSource,
  );
  final networkBackendContractCoverage = _networkBackendContractCoverage(
    networkBackendContractTestSource,
  );
  final advertisedHttp = advertised
      .where((route) => !route.startsWith('WS '))
      .toSet();
  final openApiPaths = advertisedHttp.map(_openApiPathForRoute).toSet();

  final registeredNotAdvertised = registered.difference(advertised).toList()
    ..sort();
  final advertisedNotRegistered = advertised.difference(registered).toList()
    ..sort();
  final networkBackendMissingOnServer =
      networkBackendRoutes.difference(registered).toList()..sort();
  final advertisedHttpMissingOpenApi =
      advertisedHttp
          .where((route) => !_openApiContainsRoute(openApiPaths, route))
          .toList()
        ..sort();

  final passed =
      registered.isNotEmpty &&
      advertised.isNotEmpty &&
      registeredNotAdvertised.isEmpty &&
      advertisedNotRegistered.isEmpty &&
      networkBackendMissingOnServer.isEmpty &&
      advertisedHttpMissingOpenApi.isEmpty &&
      openApiMetadata.values.every((present) => present) &&
      webSocketContractCoverage.values.every((present) => present) &&
      networkBackendContractCoverage.values.every((present) => present) &&
      versionNegotiationCoverage.values.every((present) => present);

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'serverSource': _serverPath,
    'networkBackendSource': _networkBackendPath,
    'routeMetadataSource': _routeMetadataPath,
    'networkBackendWebSocketTestSource': _networkBackendWebSocketTestPath,
    'networkBackendContractTestSource': _networkBackendContractTestPath,
    'remoteApiCompatibilitySource': _remoteApiCompatibilityPath,
    'remoteApiCompatibilityTestSource': _remoteApiCompatibilityTestPath,
    'headlessAuthMiddlewareTestSource': _headlessAuthMiddlewareTestPath,
    'dashboardApiSource': _dashboardApiPath,
    'apiDocsSource': _apiDocsPath,
    'passed': passed,
    'registeredRouteCount': registered.length,
    'advertisedRouteCount': advertised.length,
    'advertisedHttpRouteCount': advertisedHttp.length,
    'advertisedWebSocketRouteCount': advertised.length - advertisedHttp.length,
    'openApiPathCount': openApiPaths.length,
    'openApiOperationCount': advertisedHttp.length,
    'networkBackendRouteCount': networkBackendRoutes.length,
    'registeredNotAdvertisedCount': registeredNotAdvertised.length,
    'advertisedNotRegisteredCount': advertisedNotRegistered.length,
    'networkBackendMissingOnServerCount': networkBackendMissingOnServer.length,
    'advertisedHttpMissingOpenApiCount': advertisedHttpMissingOpenApi.length,
    'openApiMetadataCoverage': openApiMetadata,
    'openApiMetadataCoverageCount': openApiMetadata.values
        .where((present) => present)
        .length,
    'webSocketContractCoverage': webSocketContractCoverage,
    'webSocketContractCoverageCount': webSocketContractCoverage.values
        .where((present) => present)
        .length,
    'networkBackendContractCoverage': networkBackendContractCoverage,
    'networkBackendContractCoverageCount': networkBackendContractCoverage.values
        .where((present) => present)
        .length,
    'versionNegotiationCoverage': versionNegotiationCoverage,
    'versionNegotiationCoverageCount': versionNegotiationCoverage.values
        .where((present) => present)
        .length,
    'registeredNotAdvertised': registeredNotAdvertised,
    'advertisedNotRegistered': advertisedNotRegistered,
    'networkBackendMissingOnServer': networkBackendMissingOnServer,
    'advertisedHttpMissingOpenApi': advertisedHttpMissingOpenApi,
  };

  File(_jsonOutputPath).parent.createSync(recursive: true);
  File(
    _jsonOutputPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  File(_markdownOutputPath).parent.createSync(recursive: true);
  File(_markdownOutputPath).writeAsStringSync(
    _renderMarkdown(
      passed: passed,
      registered: registered,
      advertised: advertised,
      advertisedHttp: advertisedHttp,
      openApiPaths: openApiPaths,
      networkBackendRoutes: networkBackendRoutes,
      registeredNotAdvertised: registeredNotAdvertised,
      advertisedNotRegistered: advertisedNotRegistered,
      networkBackendMissingOnServer: networkBackendMissingOnServer,
      advertisedHttpMissingOpenApi: advertisedHttpMissingOpenApi,
      openApiMetadata: openApiMetadata,
      webSocketContractCoverage: webSocketContractCoverage,
      networkBackendContractCoverage: networkBackendContractCoverage,
      versionNegotiationCoverage: versionNegotiationCoverage,
    ),
  );

  stdout.writeln('Headless API contract audit complete.');
  stdout.writeln('Registered routes: ${registered.length}');
  stdout.writeln('Advertised routes: ${advertised.length}');
  stdout.writeln('Advertised HTTP routes: ${advertisedHttp.length}');
  stdout.writeln('OpenAPI paths: ${openApiPaths.length}');
  stdout.writeln('NetworkBackend routes: ${networkBackendRoutes.length}');
  stdout.writeln(
    'Registered not advertised: ${registeredNotAdvertised.length}',
  );
  stdout.writeln(
    'Advertised not registered: ${advertisedNotRegistered.length}',
  );
  stdout.writeln(
    'NetworkBackend missing on server: ${networkBackendMissingOnServer.length}',
  );
  stdout.writeln(
    'Advertised HTTP missing OpenAPI: ${advertisedHttpMissingOpenApi.length}',
  );
  stdout.writeln(
    'OpenAPI metadata coverage: ${openApiMetadata.values.where((present) => present).length}/${openApiMetadata.length}',
  );
  stdout.writeln(
    'WebSocket contract coverage: ${webSocketContractCoverage.values.where((present) => present).length}/${webSocketContractCoverage.length}',
  );
  stdout.writeln(
    'NetworkBackend contract coverage: ${networkBackendContractCoverage.values.where((present) => present).length}/${networkBackendContractCoverage.length}',
  );
  stdout.writeln(
    'Version negotiation coverage: ${versionNegotiationCoverage.values.where((present) => present).length}/${versionNegotiationCoverage.length}',
  );
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');

  if (failOnDrift && !passed) {
    exit(1);
  }
}

String _readSource(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : '';
}

String _readNetworkBackendSource(File networkBackend) {
  final sources = <String>[networkBackend.readAsStringSync()];
  final partsDirectory = Directory(_networkBackendPartsDirectory);
  if (!partsDirectory.existsSync()) {
    return sources.single;
  }
  final partFiles =
      partsDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  sources.addAll(partFiles.map((file) => file.readAsStringSync()));
  return sources.join('\n');
}

/// Read the route-metadata barrel *and* every file it exports: the split into
/// `route_metadata/` left this audit reading 11 lines and reporting 0/9
/// coverage while the generator was intact.
String _readRouteMetadataSource(File barrel) {
  final buffer = StringBuffer(barrel.readAsStringSync());
  final dir = barrel.parent.path;
  final exportPattern = RegExp("export\\s+'([^']+)'");
  for (final match in exportPattern.allMatches(buffer.toString())) {
    final part = File('$dir/${match.group(1)}');
    if (part.existsSync()) {
      buffer.writeln(part.readAsStringSync());
    }
  }
  return buffer.toString();
}

Map<String, bool> _openApiMetadataCoverage(String source) {
  return {
    'request_body_limit_extension':
        source.contains('x-max-request-body-bytes') &&
        source.contains('requestBodyLimitForPath'),
    'rate_limit_extension':
        source.contains('x-rate-limit') &&
        source.contains('endpointRateLimitFor') &&
        source.contains('Rate limit exceeded'),
    'audit_action_extension':
        source.contains('x-audit-action') &&
        source.contains('highRiskAuditActionFor'),
    'oversized_response':
        source.contains("'413'") && source.contains('Request body too large'),
    'rate_limited_response':
        source.contains("'429'") && source.contains('Rate limit exceeded'),
    'bearer_security_scheme':
        source.contains('securitySchemes') &&
        source.contains('bearerAuth') &&
        source.contains("'scheme': 'bearer'"),
    'required_scope_extension':
        source.contains('x-required-scope') &&
        source.contains('requiredAuthScopeNameForEndpoint'),
    'public_endpoint_extension':
        source.contains('x-auth-required') &&
        source.contains('isPublicEndpoint'),
    'api_version_mismatch_response':
        source.contains("'426'") &&
        source.contains('Upgrade required for API version mismatch'),
  };
}

Map<String, bool> _webSocketContractCoverage(String source) {
  return {
    'heartbeat_ping_pong':
        source.contains('sends ping heartbeats and accepts pong replies') &&
        source.contains("data['type'] == 'ping'") &&
        source.contains("'type': 'pong'"),
    'compatibility_before_socket': source.contains(
      'rejects incompatible servers before opening WebSocket',
    ),
    'headless_event_wrapper_to_event_stream':
        source.contains(
          'routes headless event wrappers to event and polar alignment streams',
        ) &&
        source.contains("'type': 'event'") &&
        source.contains('backend.eventStream') &&
        source.contains('PolarAlignmentProgress'),
    'polar_alignment_event_stream':
        source.contains('backend.polarAlignmentEvents') &&
        source.contains('azimuthErrorArcmin') &&
        source.contains('EventCategory.polarAlignment'),
  };
}

Map<String, bool> _networkBackendContractCoverage(String source) {
  return {
    'advertised_endpoints_match_registered_routes':
        source.contains('advertised endpoints match registered API routes') &&
        source.contains('advertised.difference(registered)') &&
        source.contains('registered.difference(advertised)'),
    'network_backend_calls_registered_routes':
        source.contains(
          'NetworkBackend call sites map to registered server routes',
        ) &&
        source.contains('clientRoutes.difference(registered)') &&
        source.contains('_networkBackendRoutes'),
    'openapi_includes_every_http_route':
        source.contains(
          'OpenAPI spec advertises every HTTP route from the route table',
        ) &&
        source.contains('buildOpenApiSpec') &&
        source.contains('WebSocket endpoints are advertised in /api/info'),
    'openapi_generated_spec_path_method_assertions':
        source.contains('paths[path]') &&
        source.contains('contains(method)') &&
        source.contains('OpenAPI must include advertised route'),
  };
}

Map<String, bool> _versionNegotiationCoverage({
  required String remoteApiCompatibilitySource,
  required String serverCompatibilitySource,
  required String remoteApiCompatibilityTestSource,
  required String headlessAuthMiddlewareTestSource,
  required String networkBackendSource,
  required String dashboardApiSource,
  required String apiDocsSource,
}) {
  final normalizedApiDocsSource = apiDocsSource.replaceAll(RegExp(r'\s+'), ' ');
  return {
    // The core compatibility model delegates to the single
    // SkotiqServerCompatibility policy so the two cannot diverge. Verify
    // the delegation here and pin the 2.4.0 floor + the three rejection codes
    // in that single source of truth.
    'shared_compatibility_policy':
        remoteApiCompatibilitySource.contains(
          'SkotiqServerCompatibility.minimumSupportedVersion',
        ) &&
        remoteApiCompatibilitySource.contains(
          'SkotiqServerCompatibility.check',
        ) &&
        serverCompatibilitySource.contains(
          'minimumSupportedVersion = ServerSemanticVersion(2, 4, 0)',
        ) &&
        serverCompatibilitySource.contains('server_too_old') &&
        serverCompatibilitySource.contains('server_too_new') &&
        serverCompatibilitySource.contains('client_too_old'),
    'shared_compatibility_tests':
        remoteApiCompatibilityTestSource.contains(
          'rejects old servers with a clear code and message',
        ) &&
        remoteApiCompatibilityTestSource.contains(
          'rejects newer major servers with a clear code and message',
        ) &&
        remoteApiCompatibilityTestSource.contains(
          'rejects old clients with a clear code and message',
        ) &&
        remoteApiCompatibilityTestSource.contains(
          'rejects clients that require a newer server major',
        ),
    'server_http_version_middleware_test':
        headlessAuthMiddlewareTestSource.contains(
          'rejects explicit incompatible client API versions before auth',
        ) &&
        headlessAuthMiddlewareTestSource.contains(
          'HttpStatus.upgradeRequired',
        ) &&
        headlessAuthMiddlewareTestSource.contains(
          "tooOld.body['error'], 'client_too_old'",
        ) &&
        headlessAuthMiddlewareTestSource.contains(
          "tooNew.body['error'], 'server_too_old'",
        ),
    'server_websocket_version_middleware_test':
        headlessAuthMiddlewareTestSource.contains(
          'rejects incompatible WebSocket API versions before auth',
        ) &&
        headlessAuthMiddlewareTestSource.contains(
          'GET /events?apiVersion=1.9.9 HTTP/1.1',
        ) &&
        headlessAuthMiddlewareTestSource.contains(
          'GET /events?apiVersion=3.0.0 HTTP/1.1',
        ),
    'network_backend_preflight':
        networkBackendSource.contains(
          'Future<RemoteApiCompatibilityResult> _checkServerCompatibility()',
        ) &&
        networkBackendSource.contains(
          "info['apiVersion'] as String? ?? info['version'] as String?",
        ),
    'network_backend_version_headers':
        networkBackendSource.contains(
          'RemoteApiCompatibility.apiVersionHeader',
        ) &&
        networkBackendSource.contains(
          'RemoteApiCompatibility.clientApiVersion.format()',
        ),
    'network_backend_websocket_query_version':
        networkBackendSource.contains("queryParameters['apiVersion']") &&
        networkBackendSource.contains(
          'RemoteApiCompatibility.clientApiVersion.format()',
        ),
    'dashboard_http_version_header': dashboardApiSource.contains(
      "'X-Skotiq-API-Version': this._apiVersion",
    ),
    'dashboard_websocket_query_version': dashboardApiSource.contains(
      "apiVersion=' + encodeURIComponent(this._apiVersion)",
    ),
    'docs_user_facing_compatibility':
        normalizedApiDocsSource.contains('/api/info.apiVersion') &&
        normalizedApiDocsSource.contains('fall back to `version`') &&
        normalizedApiDocsSource.contains('server too old/new') &&
        normalizedApiDocsSource.contains('`2.4.0`') &&
        normalizedApiDocsSource.contains('major version `2`'),
  };
}

Set<String> _registeredApiRoutes(String source) {
  final result = <String>{};

  // Legacy inline-`router.<verb>(...)` registrations. The Pi
  // operator's `start()` method used to register hundreds of routes
  // this way; the refactor moved them into per-domain route files
  // under `apps/desktop/lib/headless_api/routes/` (scanned below).
  // The pattern is still scanned in the server source so any one-off
  // legacy registration that hasn't been migrated is still seen.
  final routerPattern = RegExp(
    r"router\.(get|post|put|delete|patch)\(\s*'([^']+)'",
  );
  for (final match in routerPattern.allMatches(source)) {
    final path = match.group(2)!;
    if (!path.startsWith('/api/') && path != '/events') {
      continue;
    }
    final callEnd = source.indexOf(';', match.end);
    final routeCall = source.substring(
      match.start,
      callEnd == -1 ? match.end : callEnd,
    );
    final method = routeCall.contains('webSocketHandler') || path == '/events'
        ? 'WS'
        : match.group(1)!.toUpperCase();
    result.add('$method ${_normalizeRoute(path)}');
  }

  // Per-domain `HeadlessRoute(HttpMethod.<verb>, '<path>', ...)`
  // entries. Pattern matches:
  //   HeadlessRoute(HttpMethod.get,  '/api/info', h.handleInfo)
  //   HeadlessRoute(HttpMethod.post, '/api/...', _foo.bar)
  // Trailing whitespace / line breaks between the comma and the path
  // string are tolerated so the audit doesn't care about formatter
  // line-wrapping inside the per-domain lists.
  final headlessRoutePattern = RegExp(
    r"HeadlessRoute\(\s*HttpMethod\.(get|post|put|delete|patch|head|options)\s*,\s*'([^']+)'",
  );
  // Routes registered via the WebSocket builder. The list takes
  // `Handler` closures (not method tear-offs), so we can't tag them as
  // WS from a textual scan of the routes file alone — there is no
  // verb prefix to disambiguate from a plain HTTP GET. The
  // `_wsRoutes` set hard-codes which paths the WebSocket builder
  // owns; everything else from a `routes/*.dart` file is HTTP.
  const wsRoutes = {'/api/ws', '/events', '/ws/live-view'};
  final routesDir = Directory(_routesDirectory);
  if (routesDir.existsSync()) {
    for (final entity in routesDir.listSync(recursive: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final fileSource = entity.readAsStringSync();
      for (final match in headlessRoutePattern.allMatches(fileSource)) {
        final path = match.group(2)!;
        final isWs = wsRoutes.contains(path);
        // Static-file SPA fallthroughs and the broadcast page are not
        // part of the API contract; the legacy regex would only match
        // them under `router.<verb>(...)` in the server source and
        // even then they were not surfaced (the legacy scanner only
        // accepted `/api/*` and `/events`). Reproduce that filter here.
        if (!path.startsWith('/api/') && !isWs) {
          continue;
        }
        final method = isWs ? 'WS' : match.group(1)!.toUpperCase();
        result.add('$method ${_normalizeRoute(path)}');
      }
    }
  }

  return result;
}

Set<String> _advertisedApiRoutes(String source) {
  // Accept the legacy in-server `List<String> _getAvailableEndpoints()`
  // method shape AND the post-extraction top-level
  // `List<String> availableHeadlessEndpoints()` helper. Either match is
  // valid — the audit just needs the canonical catalog body, wherever it
  // lives. Listed in priority order so a stale legacy stub in the server
  // file would still resolve, but the modern location wins when both
  // exist (which they don't in practice — see system_handlers.dart).
  final patterns = <RegExp>[
    RegExp(
      r'List<String>\s+availableHeadlessEndpoints\(\)\s*\{\s*return\s*const\s*\[(.*?)\];\s*\}',
      dotAll: true,
    ),
    RegExp(
      r'List<String>\s+availableHeadlessEndpoints\(\)\s*\{\s*return\s*\[(.*?)\];\s*\}',
      dotAll: true,
    ),
    RegExp(
      r'List<String>\s+_getAvailableEndpoints\(\)\s*\{\s*return\s*\[(.*?)\];\s*\}',
      dotAll: true,
    ),
  ];
  Match? match;
  for (final pattern in patterns) {
    match = pattern.firstMatch(source);
    if (match != null) break;
  }
  if (match == null) {
    return const <String>{};
  }

  return RegExp(r"'([^']+)'").allMatches(match.group(1)!).map((match) {
    final parts = match.group(1)!.split(' ');
    if (parts.length != 2) {
      return match.group(1)!;
    }
    return '${parts[0]} ${_normalizeRoute(parts[1])}';
  }).toSet();
}

Set<String> _networkBackendRoutes(String source) {
  return RegExp(
    r"_(get|post|put|delete|downloadBytes|postRaw|postRawBytes)\(\s*'([^']+)'",
  ).allMatches(source).map((match) {
    final method = switch (match.group(1)!) {
      'get' => 'GET',
      'post' => 'POST',
      'put' => 'PUT',
      'delete' => 'DELETE',
      'downloadBytes' => 'GET',
      'postRaw' => 'POST',
      'postRawBytes' => 'POST',
      _ => throw StateError('Unsupported NetworkBackend helper'),
    };
    return '$method /api/${_normalizeRoute(match.group(2)!)}';
  }).toSet();
}

String _normalizeRoute(String path) {
  final querylessPath = path.split('?').first;
  return querylessPath
      .replaceAllMapped(RegExp(r'<([^>|]+)(?:\|[^>]+)?>'), (_) => '{param}')
      .replaceAllMapped(RegExp(r'\$\{[^}]+\}'), (_) => '{param}')
      .replaceAllMapped(RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*'), (_) => '{param}')
      .replaceAllMapped(RegExp(r'\{[^}]+\}'), (_) => '{param}');
}

String _openApiPathForRoute(String route) {
  final parts = route.split(' ');
  final path = parts.length == 2 ? parts.last : route;
  return path.replaceAll('{param}', '{id}');
}

bool _openApiContainsRoute(Set<String> paths, String route) {
  return paths.contains(_openApiPathForRoute(route));
}

String _renderMarkdown({
  required bool passed,
  required Set<String> registered,
  required Set<String> advertised,
  required Set<String> advertisedHttp,
  required Set<String> openApiPaths,
  required Set<String> networkBackendRoutes,
  required List<String> registeredNotAdvertised,
  required List<String> advertisedNotRegistered,
  required List<String> networkBackendMissingOnServer,
  required List<String> advertisedHttpMissingOpenApi,
  required Map<String, bool> openApiMetadata,
  required Map<String, bool> webSocketContractCoverage,
  required Map<String, bool> networkBackendContractCoverage,
  required Map<String, bool> versionNegotiationCoverage,
}) {
  final buffer = StringBuffer()
    ..writeln('# Headless API Contract Audit')
    ..writeln()
    ..writeln('- Passed: `$passed`')
    ..writeln('- Registered routes: `${registered.length}`')
    ..writeln('- Advertised routes: `${advertised.length}`')
    ..writeln('- Advertised HTTP routes: `${advertisedHttp.length}`')
    ..writeln('- OpenAPI paths: `${openApiPaths.length}`')
    ..writeln('- NetworkBackend routes: `${networkBackendRoutes.length}`')
    ..writeln(
      '- Registered not advertised: `${registeredNotAdvertised.length}`',
    )
    ..writeln(
      '- Advertised not registered: `${advertisedNotRegistered.length}`',
    )
    ..writeln(
      '- NetworkBackend missing on server: `${networkBackendMissingOnServer.length}`',
    )
    ..writeln(
      '- Advertised HTTP missing OpenAPI: `${advertisedHttpMissingOpenApi.length}`',
    )
    ..writeln(
      '- OpenAPI metadata coverage: `${openApiMetadata.values.where((present) => present).length}/${openApiMetadata.length}`',
    )
    ..writeln(
      '- WebSocket contract coverage: `${webSocketContractCoverage.values.where((present) => present).length}/${webSocketContractCoverage.length}`',
    )
    ..writeln(
      '- NetworkBackend contract coverage: `${networkBackendContractCoverage.values.where((present) => present).length}/${networkBackendContractCoverage.length}`',
    )
    ..writeln(
      '- Version negotiation coverage: `${versionNegotiationCoverage.values.where((present) => present).length}/${versionNegotiationCoverage.length}`',
    )
    ..writeln()
    ..writeln(
      'This audit compares the `HeadlessApiServer` route registrations, '
      '`/api/info` advertised endpoint table, generated OpenAPI route surface, '
      'and `NetworkBackend` call sites. It is a source-level contract audit; '
      'runtime smoke tests still verify packaged server behavior.',
    );

  _writeDrift(buffer, 'Registered Not Advertised', registeredNotAdvertised);
  _writeDrift(buffer, 'Advertised Not Registered', advertisedNotRegistered);
  _writeDrift(
    buffer,
    'NetworkBackend Missing On Server',
    networkBackendMissingOnServer,
  );
  _writeDrift(
    buffer,
    'Advertised HTTP Missing OpenAPI',
    advertisedHttpMissingOpenApi,
  );

  buffer
    ..writeln()
    ..writeln('## OpenAPI Metadata Coverage')
    ..writeln()
    ..writeln('| Marker | Present |')
    ..writeln('| --- | --- |');
  for (final entry in openApiMetadata.entries) {
    buffer.writeln('| `${entry.key}` | `${entry.value}` |');
  }

  buffer
    ..writeln()
    ..writeln('## WebSocket Contract Coverage')
    ..writeln()
    ..writeln('| Marker | Present |')
    ..writeln('| --- | --- |');
  for (final entry in webSocketContractCoverage.entries) {
    buffer.writeln('| `${entry.key}` | `${entry.value}` |');
  }

  buffer
    ..writeln()
    ..writeln('## NetworkBackend Contract Coverage')
    ..writeln()
    ..writeln('| Marker | Present |')
    ..writeln('| --- | --- |');
  for (final entry in networkBackendContractCoverage.entries) {
    buffer.writeln('| `${entry.key}` | `${entry.value}` |');
  }

  buffer
    ..writeln()
    ..writeln('## Version Negotiation Coverage')
    ..writeln()
    ..writeln('| Marker | Present |')
    ..writeln('| --- | --- |');
  for (final entry in versionNegotiationCoverage.entries) {
    buffer.writeln('| `${entry.key}` | `${entry.value}` |');
  }

  return buffer.toString();
}

void _writeDrift(StringBuffer buffer, String title, List<String> values) {
  if (values.isEmpty) {
    return;
  }
  buffer
    ..writeln()
    ..writeln('## $title')
    ..writeln();
  for (final value in values) {
    buffer.writeln('- `$value`');
  }
}
