// Checks the callers of the remote API against its declared route table
// (packages/skotiq_remote_protocol/lib/wire.dart).
//
// The host serves, advertises and documents exactly the declared routes, so
// those cannot drift. What can is a caller that still writes its paths as
// text: NetworkBackend and the two browser clients. Each path they name must
// be a declared route, and NetworkBackend's method must match too.
//
//   dart run tools/production/headless_api_contract_audit.dart [--no-fail-on-drift]
import 'dart:convert';
import 'dart:io';

// ignore: avoid_relative_lib_imports
import '../../packages/skotiq_remote_protocol/lib/routes.dart';

const _networkBackendPath =
    'packages/skotiq_core/lib/src/backend/network_backend.dart';
const _networkBackendPartsDirectory =
    'packages/skotiq_core/lib/src/backend/network_backend';
const _browserClientPaths = [
  'apps/desktop/web_dashboard/js',
  'apps/desktop/web_run_watch/js',
];
const _jsonOutputPath =
    'docs/production-readiness/headless-api-contract-audit.json';
const _markdownOutputPath =
    'docs/production-readiness/headless-api-contract-audit.md';

void main(List<String> args) {
  final failOnDrift = !args.contains('--no-fail-on-drift');
  final networkBackendSource = _readDartSources();
  if (networkBackendSource.isEmpty) {
    stderr.writeln('NetworkBackend source not found: $_networkBackendPath');
    exit(2);
  }

  final networkBackendCalls = _networkBackendCalls(networkBackendSource);
  final networkBackendMissingOnServer = [
    for (final call in networkBackendCalls)
      if (!_isDeclared(call.method, call.path)) '${call.method} ${call.path}',
  ]..sort();

  final browserPaths = _browserClientApiPaths();
  final browserMissingOnServer = [
    for (final path in browserPaths)
      if (!_isDeclaredPath(path)) path,
  ]..sort();

  final httpRoutes = [
    for (final endpoint in apiEndpoints)
      if (endpoint.route.method != ApiMethod.ws) endpoint.route,
  ];
  final passed =
      networkBackendCalls.isNotEmpty &&
      networkBackendMissingOnServer.isEmpty &&
      browserMissingOnServer.isEmpty;

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'passed': passed,
    'registeredRouteCount': apiEndpoints.length,
    'advertisedRouteCount': advertisedApiEndpoints.length,
    'openApiOperationCount': httpRoutes
        .where((route) => route.path.startsWith('/api/'))
        .length,
    'networkBackendRouteCount': networkBackendCalls.length,
    'networkBackendMissingOnServerCount': networkBackendMissingOnServer.length,
    'networkBackendMissingOnServer': networkBackendMissingOnServer,
    'browserClientPathCount': browserPaths.length,
    'browserClientMissingOnServerCount': browserMissingOnServer.length,
    'browserClientMissingOnServer': browserMissingOnServer,
  };
  File(_jsonOutputPath).parent.createSync(recursive: true);
  File(
    _jsonOutputPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  File(_markdownOutputPath).writeAsStringSync(
    [
      '# Headless API contract audit',
      '',
      'Passed: $passed',
      '',
      '- Declared routes: ${apiEndpoints.length} '
          '(${advertisedApiEndpoints.length} advertised by `/api/info`)',
      '- NetworkBackend calls: ${networkBackendCalls.length}, '
          '${networkBackendMissingOnServer.length} not declared',
      '- Browser client paths: ${browserPaths.length}, '
          '${browserMissingOnServer.length} not declared',
      '',
      for (final route in networkBackendMissingOnServer)
        '- NetworkBackend calls `$route`, which the host does not serve.',
      for (final path in browserMissingOnServer)
        '- A browser client names `$path`, which the host does not serve.',
      '',
    ].join('\n'),
  );

  stdout.writeln('Headless API contract audit complete.');
  stdout.writeln('Passed: $passed');
  stdout.writeln('Declared routes: ${apiEndpoints.length}');
  stdout.writeln('NetworkBackend calls: ${networkBackendCalls.length}');
  stdout.writeln(
    'NetworkBackend missing on server: ${networkBackendMissingOnServer.length}',
  );
  stdout.writeln('Browser client paths: ${browserPaths.length}');
  stdout.writeln(
    'Browser client missing on server: ${browserMissingOnServer.length}',
  );
  for (final route in networkBackendMissingOnServer) {
    stdout.writeln('  NetworkBackend: $route');
  }
  for (final path in browserMissingOnServer) {
    stdout.writeln('  Browser client: $path');
  }
  if (failOnDrift && !passed) exit(1);
}

typedef _Call = ({String method, String path});

/// A value no real path segment has, standing for an interpolated one.
const _placeholder = '~param~';

bool _isDeclared(String method, String path) =>
    apiRouteIndex.resolve(method, path) is ApiRouteMatched;

/// A path ending in `/` is a prefix the caller appends to, so it only has to
/// begin some declared route.
bool _isDeclaredPath(String path) {
  if (path.endsWith('/')) {
    return apiEndpoints.any((endpoint) => endpoint.route.path.startsWith(path));
  }
  return const [
    'GET',
    'POST',
    'PUT',
    'DELETE',
  ].any((method) => _isDeclared(method, path));
}

String _readDartSources() {
  final root = File(_networkBackendPath);
  if (!root.existsSync()) return '';
  final sources = <String>[root.readAsStringSync()];
  final parts = Directory(_networkBackendPartsDirectory);
  if (parts.existsSync()) {
    final files =
        parts
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    sources.addAll(files.map((file) => file.readAsStringSync()));
  }
  return sources.join('\n');
}

Set<_Call> _networkBackendCalls(String source) {
  return RegExp(
    r"_(get|post|put|delete|downloadBytes|postRaw|postRawBytes)\(\s*'([^']+)'",
  ).allMatches(source).map((match) {
    final method = switch (match.group(1)!) {
      'get' || 'downloadBytes' => 'GET',
      'post' || 'postRaw' || 'postRawBytes' => 'POST',
      'put' => 'PUT',
      _ => 'DELETE',
    };
    final path = match
        .group(2)!
        .split('?')
        .first
        .replaceAll(RegExp(r'\$\{[^}]+\}'), _placeholder)
        .replaceAll(RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*'), _placeholder);
    return (method: method, path: '/api/$path');
  }).toSet();
}

/// Every `/api/...` path the browser clients write as a string or template
/// literal, with `${...}` pieces standing for one segment.
Set<String> _browserClientApiPaths() {
  final paths = <String>{};
  final literal = RegExp(r'''['"`](/api/[^'"`\s?]*)''');
  for (final directory in _browserClientPaths.map(Directory.new)) {
    if (!directory.existsSync()) continue;
    for (final file in directory.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.js')) continue;
      for (final match in literal.allMatches(file.readAsStringSync())) {
        paths.add(
          match.group(1)!.replaceAll(RegExp(r'\$\{[^}]*\}'), _placeholder),
        );
      }
    }
  }
  return paths;
}
