import 'dart:convert';
import 'dart:io';

import '../../apps/desktop/lib/headless_api/route_metadata.dart'
    as route_metadata;

const _jsonOutputPath =
    'docs/production-readiness/headless-route-policy-audit.json';
const _markdownOutputPath =
    'docs/production-readiness/headless-route-policy-audit.md';
const _serverPath = 'apps/desktop/lib/headless_api_server.dart';

/// Directory of per-domain declarative route tables. Each file there
/// exposes a top-level `buildXxxRoutes(...)` whose `HeadlessRoute`
/// entries replaced the legacy inline `router.<verb>(...)` calls in
/// `start()`. The audit scans this directory in addition to
/// [_serverPath] so the body-limit inventory survives the refactor.
const _routesDirectory = 'apps/desktop/lib/headless_api/routes';

const _serverMiddlewareTestPath =
    'apps/desktop/test/headless_api/auth_middleware_test.dart';
const _sizeLimitTestPath =
    'apps/desktop/test/headless_api_server/http_request_size_limit_test.dart';

const _expectedHighRiskActions = {
  '/api/devices/connect': 'device_connect',
  '/api/devices/disconnect': 'device_disconnect',
  '/api/mount/slew': 'mount_slew',
  '/api/mount/slew-alt-az': 'mount_slew_alt_az',
  '/api/mount/park': 'mount_park',
  '/api/mount/unpark': 'mount_unpark',
  '/api/mount/home': 'mount_home',
  '/api/mount/find-home': 'mount_home',
  '/api/mount/set-park': 'mount_set_park',
  '/api/framing/slew-to-target': 'framing_slew_to_target',
  '/api/framing/center-on-target': 'framing_center_on_target',
  '/api/framing/park': 'framing_park',
  '/api/framing/unpark': 'framing_unpark',
  '/api/dome/open': 'dome_open',
  '/api/dome/close': 'dome_close',
  '/api/dome/slew': 'dome_slew',
  '/api/dome/park': 'dome_park',
  '/api/backup/restore': 'backup_restore',
  '/api/backup/upload-restore': 'backup_upload_restore',
  '/api/sequencer/start': 'sequence_start',
  '/api/sequencer/stop': 'sequence_stop',
  '/api/sequencer/resume': 'sequence_resume',
  '/api/sequencer/request-meridian-flip': 'sequence_request_meridian_flip',
};

const _defaultLimitedRoutes = {
  '/api/camera/cooling',
  '/api/focuser/move-to',
  '/api/filter-wheel/position',
  '/api/rotator/move-to',
  '/api/phd2/dither',
  '/api/guider/dither',
  '/api/safety/settings',
  '/api/switch/set',
  '/api/cover/open',
};

const _expectedBodyLimits = {
  '/api/mount/slew': route_metadata.oneMiB,
  '/api/imaging/stats': route_metadata.imageProcessingMaxRequestBodyBytes,
  '/api/imaging/stretch': route_metadata.imageProcessingMaxRequestBodyBytes,
  '/api/imaging/debayer': route_metadata.imageProcessingMaxRequestBodyBytes,
  '/api/imaging/save-fits': route_metadata.imageProcessingMaxRequestBodyBytes,
  '/api/backup/upload-restore': route_metadata.backupUploadMaxRequestBodyBytes,
};

void main(List<String> args) {
  final failOnPolicyIssue = !args.contains('--no-fail-on-policy-issue');
  final issues = <String>[];
  final serverSource = _readSource(_serverPath);

  final bodyLimits = <String, int>{};
  for (final entry in _expectedBodyLimits.entries) {
    final actual = route_metadata.requestBodyLimitForPath(entry.key);
    bodyLimits[entry.key] = actual;
    if (actual != entry.value) {
      issues.add('${entry.key} must use body limit ${entry.value}.');
    }
  }
  final registeredBodyRoutes = _registeredBodyApiRoutes(serverSource);
  final bodyLimitedApiWriteRoutes = <Map<String, Object?>>[];
  for (final route in registeredBodyRoutes) {
    final limit = route_metadata.requestBodyLimitForPath(route.path);
    bodyLimitedApiWriteRoutes.add({
      'method': route.method,
      'path': route.path,
      'maxBytes': limit,
    });
    if (limit <= 0) {
      issues.add(
        '${route.method} ${route.path} must use a positive body limit.',
      );
    }
  }
  if (serverSource == null) {
    issues.add('Headless API server source is missing: $_serverPath.');
  } else if (registeredBodyRoutes.isEmpty) {
    issues.add('No registered body-capable API routes were found.');
  }

  final highRiskPolicies = <Map<String, Object?>>[];
  for (final entry in _expectedHighRiskActions.entries) {
    final rateLimit = route_metadata.endpointRateLimitFor(
      method: entry.key == '/api/files/browse' ? 'GET' : 'POST',
      path: entry.key,
    );
    final action = route_metadata.highRiskAuditActionFor(
      method: entry.key == '/api/files/browse' ? 'GET' : 'POST',
      path: entry.key,
    );
    final maxRequests = rateLimit?.maxRequests;
    highRiskPolicies.add({
      'path': entry.key,
      'expectedAction': entry.value,
      'actualAction': action,
      'maxRequests': maxRequests,
    });
    if (maxRequests != route_metadata.highRiskControlRateLimitMaxRequests) {
      issues.add('${entry.key} must use the high-risk control rate limit.');
    }
    if (action != entry.value) {
      issues.add('${entry.key} must audit as `${entry.value}`.');
    }
  }

  final defaultLimitedPolicies = <Map<String, Object?>>[];
  for (final path in _defaultLimitedRoutes) {
    final rateLimit = route_metadata.endpointRateLimitFor(
      method: 'POST',
      path: path,
    );
    defaultLimitedPolicies.add({
      'path': path,
      'maxRequests': rateLimit?.maxRequests,
    });
    if (rateLimit?.maxRequests !=
        route_metadata.defaultControlRateLimitMaxRequests) {
      issues.add('$path must use the default control rate limit.');
    }
  }

  final ordinaryReadLimited =
      route_metadata.endpointRateLimitFor(method: 'GET', path: '/api/info') !=
      null;
  if (ordinaryReadLimited) {
    issues.add('/api/info must not be rate limited.');
  }

  final fileBrowseAction = route_metadata.highRiskAuditActionFor(
    method: 'GET',
    path: '/api/files/browse',
  );
  if (fileBrowseAction != 'file_browse') {
    issues.add('/api/files/browse must audit as `file_browse`.');
  }

  final serverMiddlewareTests = _readServerMiddlewareTests();
  if (!serverMiddlewareTests.values.every((present) => present)) {
    final missing = serverMiddlewareTests.entries
        .where((entry) => !entry.value)
        .map((entry) => entry.key)
        .join(', ');
    issues.add(
      'Headless server middleware test coverage is missing: $missing.',
    );
  }

  final passed = issues.isEmpty;
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'issueCount': issues.length,
    'issues': issues,
    'bodyLimits': bodyLimits,
    'bodyLimitedApiWriteRouteCount': bodyLimitedApiWriteRoutes.length,
    'bodyLimitedApiWriteRoutes': bodyLimitedApiWriteRoutes,
    'ordinaryReadLimited': ordinaryReadLimited,
    'fileBrowseAuditAction': fileBrowseAction,
    'serverMiddlewareTestPath': _serverMiddlewareTestPath,
    'serverMiddlewareTests': serverMiddlewareTests,
    'serverMiddlewareTestCount': serverMiddlewareTests.values
        .where((present) => present)
        .length,
    'highRiskPolicyCount': highRiskPolicies.length,
    'defaultLimitedPolicyCount': defaultLimitedPolicies.length,
    'highRiskPolicies': highRiskPolicies,
    'defaultLimitedPolicies': defaultLimitedPolicies,
  };

  File(_jsonOutputPath).parent.createSync(recursive: true);
  File(
    _jsonOutputPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  File(_markdownOutputPath).parent.createSync(recursive: true);
  File(_markdownOutputPath).writeAsStringSync(
    _renderMarkdown(
      passed: passed,
      issues: issues,
      bodyLimits: bodyLimits,
      bodyLimitedApiWriteRoutes: bodyLimitedApiWriteRoutes,
      highRiskPolicies: highRiskPolicies,
      defaultLimitedPolicies: defaultLimitedPolicies,
      fileBrowseAction: fileBrowseAction,
      ordinaryReadLimited: ordinaryReadLimited,
      serverMiddlewareTests: serverMiddlewareTests,
    ),
  );

  stdout.writeln('Headless route policy audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Issues: ${issues.length}');
  stdout.writeln('High-risk policies: ${highRiskPolicies.length}');
  stdout.writeln('Default limited policies: ${defaultLimitedPolicies.length}');
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');

  if (failOnPolicyIssue && !passed) {
    exit(1);
  }
}

Map<String, bool> _readServerMiddlewareTests() {
  final file = File(_serverMiddlewareTestPath);
  final text = file.existsSync() ? file.readAsStringSync() : '';
  final sizeLimitFile = File(_sizeLimitTestPath);
  final sizeLimitText = sizeLimitFile.existsSync()
      ? sizeLimitFile.readAsStringSync()
      : '';
  return {
    'oversized_control_request_before_auth':
        text.contains('rejects oversized control requests before auth') &&
        text.contains('HttpStatus.requestEntityTooLarge') &&
        text.contains('Request body too large'),
    // An unauthenticated chunked body must be rejected at auth (401)
    // BEFORE it is buffered, while an authenticated oversized chunked body is
    // still capped at 413 with request-id propagation. Both halves of that
    // ordering contract must stay tested.
    'chunked_oversized_control_request_auth_ordering':
        sizeLimitText.contains(
          'unauthenticated chunked upload is rejected with 401 before the body',
        ) &&
        sizeLimitText.contains('HttpStatus.unauthorized') &&
        sizeLimitText.contains('Transfer-Encoding: chunked') &&
        text.contains(
          'rejects chunked oversized control requests for authenticated',
        ) &&
        text.contains("response.body['requestId']") &&
        text.contains("response.headers['x-request-id']") &&
        text.contains('HttpStatus.requestEntityTooLarge'),
    'high_risk_control_rate_limit':
        text.contains('rate limits repeated high-risk control requests') &&
        text.contains('HttpStatus.tooManyRequests') &&
        text.contains('Rate limit exceeded') &&
        text.contains("blocked.body['requestId']") &&
        text.contains("blocked.headers['x-request-id']"),
    'websocket_api_version_before_auth':
        text.contains(
          'rejects incompatible WebSocket API versions before auth',
        ) &&
        text.contains('GET /events?apiVersion=1.9.9 HTTP/1.1') &&
        text.contains('HttpStatus.upgradeRequired') &&
        text.contains('server_too_old'),
  };
}

String? _readSource(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return null;
  }
  return file.readAsStringSync();
}

List<_ApiRoute> _registeredBodyApiRoutes(String? source) {
  if (source == null) {
    return const [];
  }
  final routes = <_ApiRoute>{};

  // Legacy inline `router.<verb>(...)` registrations in the server.
  // The active codebase moved these into per-domain `routes/*.dart`
  // files (scanned below), but the pattern is kept so a one-off
  // inline registration that hasn't been migrated is still seen.
  final inlinePattern = RegExp(r"router\.(post|put|patch)\(\s*'([^']+)'");
  for (final match in inlinePattern.allMatches(source)) {
    final path = match.group(2)!;
    if (!path.startsWith('/api/')) {
      continue;
    }
    routes.add(_ApiRoute(match.group(1)!.toUpperCase(), path));
  }

  // Per-domain `HeadlessRoute(HttpMethod.<verb>, '<path>', ...)`
  // entries. Only `post`/`put`/`patch` carry a body so those are the
  // only verbs we collect; `get`/`delete` writes are not contemplated
  // here because the legacy audit also ignored them.
  final headlessRoutePattern = RegExp(
    r"HeadlessRoute\(\s*HttpMethod\.(post|put|patch)\s*,\s*'([^']+)'",
  );
  final routesDir = Directory(_routesDirectory);
  if (routesDir.existsSync()) {
    for (final entity in routesDir.listSync(recursive: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final fileSource = entity.readAsStringSync();
      for (final match in headlessRoutePattern.allMatches(fileSource)) {
        final path = match.group(2)!;
        if (!path.startsWith('/api/')) {
          continue;
        }
        routes.add(_ApiRoute(match.group(1)!.toUpperCase(), path));
      }
    }
  }

  return routes.toList()..sort((a, b) {
    final pathCompare = a.path.compareTo(b.path);
    if (pathCompare != 0) return pathCompare;
    return a.method.compareTo(b.method);
  });
}

String _renderMarkdown({
  required bool passed,
  required List<String> issues,
  required Map<String, int> bodyLimits,
  required List<Map<String, Object?>> bodyLimitedApiWriteRoutes,
  required List<Map<String, Object?>> highRiskPolicies,
  required List<Map<String, Object?>> defaultLimitedPolicies,
  required String? fileBrowseAction,
  required bool ordinaryReadLimited,
  required Map<String, bool> serverMiddlewareTests,
}) {
  final buffer = StringBuffer()
    ..writeln('# Headless Route Policy Audit')
    ..writeln()
    ..writeln('- Passed: `$passed`')
    ..writeln('- Issues: `${issues.length}`')
    ..writeln('- High-risk policies: `${highRiskPolicies.length}`')
    ..writeln('- Default limited policies: `${defaultLimitedPolicies.length}`')
    ..writeln(
      '- Body-limited API write routes: `${bodyLimitedApiWriteRoutes.length}`',
    )
    ..writeln('- `/api/files/browse` audit action: `$fileBrowseAction`')
    ..writeln('- `/api/info` rate limited: `$ordinaryReadLimited`')
    ..writeln(
      '- Server middleware tests: `${serverMiddlewareTests.values.where((present) => present).length}/${serverMiddlewareTests.length}`',
    )
    ..writeln()
    ..writeln(
      'This audit verifies request body limits, per-endpoint rate-limit '
      'metadata, and high-risk audit action metadata for release-gated '
      'headless control routes.',
    )
    ..writeln()
    ..writeln('## Body Limits')
    ..writeln()
    ..writeln('| Route | Max bytes |')
    ..writeln('| --- | ---: |');

  for (final entry in bodyLimits.entries) {
    buffer.writeln('| `${entry.key}` | ${entry.value} |');
  }

  buffer
    ..writeln()
    ..writeln('## Body-Limited API Write Routes')
    ..writeln()
    ..writeln('| Method | Route | Max bytes |')
    ..writeln('| --- | --- | ---: |');
  for (final route in bodyLimitedApiWriteRoutes) {
    buffer.writeln(
      '| `${route['method']}` | `${route['path']}` | ${route['maxBytes']} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## Server Middleware Tests')
    ..writeln()
    ..writeln('| Coverage | Present |')
    ..writeln('| --- | --- |');
  for (final entry in serverMiddlewareTests.entries) {
    buffer.writeln('| `${entry.key}` | `${entry.value}` |');
  }

  if (issues.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Issues')
      ..writeln();
    for (final issue in issues) {
      buffer.writeln('- $issue');
    }
  }

  buffer
    ..writeln()
    ..writeln('## High-Risk Policies')
    ..writeln()
    ..writeln('| Route | Audit action | Max requests |')
    ..writeln('| --- | --- | ---: |');
  for (final policy in highRiskPolicies) {
    buffer.writeln(
      '| `${policy['path']}` | `${policy['actualAction']}` | '
      '${policy['maxRequests']} |',
    );
  }

  return buffer.toString();
}

class _ApiRoute {
  final String method;
  final String path;

  const _ApiRoute(this.method, this.path);

  @override
  bool operator ==(Object other) =>
      other is _ApiRoute && method == other.method && path == other.path;

  @override
  int get hashCode => Object.hash(method, path);
}
