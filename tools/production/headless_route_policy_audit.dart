// Checks the policy invariants of the declared remote API routes
// (packages/skotiq_remote_protocol/lib/wire.dart) and that the middleware
// enforcing them is tested.
//
//   dart run tools/production/headless_route_policy_audit.dart [--no-fail-on-policy-issue]
import 'dart:convert';
import 'dart:io';

// ignore: avoid_relative_lib_imports
import '../../packages/skotiq_remote_protocol/lib/wire.dart';

const _jsonOutputPath =
    'docs/production-readiness/headless-route-policy-audit.json';
const _markdownOutputPath =
    'docs/production-readiness/headless-route-policy-audit.md';

const _serverMiddlewareTestPath =
    'apps/desktop/test/headless_api/auth_middleware_test.dart';
const _sizeLimitTestPath =
    'apps/desktop/test/headless_api_server/http_request_size_limit_test.dart';

void main(List<String> args) {
  final failOnPolicyIssue = !args.contains('--no-fail-on-policy-issue');
  final routes = [for (final endpoint in apiEndpoints) endpoint.route];
  final issues = <String>[];

  for (final route in routes) {
    if (route.rate == ApiRateTier.highRisk && route.audit == null) {
      issues.add('$route is in the high-risk tier and must be audited.');
    }
    if (route.scope == ApiScope.public &&
        route.method != ApiMethod.get &&
        route.rate == ApiRateTier.none) {
      issues.add('$route takes writes without a token and must be limited.');
    }
    if (route.method.mayCarryBody && route.maxBodyBytes <= 0) {
      issues.add('$route must use a positive body limit.');
    }
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

  final highRisk = routes.where((r) => r.rate == ApiRateTier.highRisk).toList();
  final limited = routes.where((r) => r.rate == ApiRateTier.control).toList();
  final bodyRoutes = routes.where((r) => r.method.mayCarryBody).toList();
  final raisedBodyLimits = {
    for (final route in bodyRoutes)
      if (route.maxBodyBytes != ApiRoute.defaultMaxBodyBytes)
        route.path: route.maxBodyBytes,
  };
  final passed = issues.isEmpty;
  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'issueCount': issues.length,
    'issues': issues,
    'bodyLimits': raisedBodyLimits,
    'bodyLimitedApiWriteRouteCount': bodyRoutes.length,
    'serverMiddlewareTestPath': _serverMiddlewareTestPath,
    'serverMiddlewareTests': serverMiddlewareTests,
    'serverMiddlewareTestCount': serverMiddlewareTests.values
        .where((present) => present)
        .length,
    'highRiskPolicyCount': highRisk.length,
    'defaultLimitedPolicyCount': limited.length,
    'highRiskPolicies': [
      for (final route in highRisk)
        {'route': route.signature, 'auditAction': route.audit},
    ],
  };

  File(_jsonOutputPath).parent.createSync(recursive: true);
  File(
    _jsonOutputPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  File(_markdownOutputPath).writeAsStringSync(
    [
      '# Headless route policy audit',
      '',
      'Passed: $passed',
      '',
      '- High-risk routes (12/min, audited): ${highRisk.length}',
      '- Rate-limited routes (60/min): ${limited.length}',
      '- Routes with a raised body limit: ${raisedBodyLimits.length}',
      '',
      for (final issue in issues) '- $issue',
      '',
    ].join('\n'),
  );

  stdout.writeln('Headless route policy audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Issues: ${issues.length}');
  for (final issue in issues) {
    stdout.writeln('  $issue');
  }
  stdout.writeln('High-risk policies: ${highRisk.length}');
  stdout.writeln('Default limited policies: ${limited.length}');
  if (failOnPolicyIssue && !passed) exit(1);
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
